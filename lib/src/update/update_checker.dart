import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../network/network_http_client.dart';
import '../version.dart';

/// 一个可下载的发行资产。
///
/// `size` 为 0 表示这个数字没拿到（走「靠跳转地址猜版本」那条退路时拿不到
/// 资产清单），此时下载进度条按「未知总长」处理。
class UpdateAsset {
  const UpdateAsset({required this.name, required this.url, this.size = 0});

  final String name;
  final Uri url;
  final int size;

  factory UpdateAsset.fromJson(Map<String, dynamic> json) => UpdateAsset(
    name: '${json['name'] ?? ''}',
    url: Uri.parse('${json['browser_download_url'] ?? ''}'),
    size: (json['size'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url.toString(),
    'size': size,
  };
}

/// 一次「最新版本」查询的结果。
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.body,
    required this.pageUrl,
    required this.assets,
    this.publishedAt,
  });

  /// 纯版本号，如 `3.1.93`（tag 去掉 v）。
  final String version;

  /// 原始 tag，如 `v3.1.93`。拼下载地址要用它。
  final String tag;

  /// Release 说明（可能为空——退路拿不到正文）。
  final String body;

  final Uri pageUrl;
  final List<UpdateAsset> assets;
  final DateTime? publishedAt;

  factory UpdateRelease.fromJson(Map<String, dynamic> json) {
    final tag = '${json['tag'] ?? ''}';
    return UpdateRelease(
      version: '${json['version'] ?? _versionFromTag(tag)}',
      tag: tag.isEmpty ? 'v${json['version'] ?? ''}' : tag,
      body: '${json['body'] ?? ''}',
      pageUrl: Uri.parse('${json['pageUrl'] ?? ''}'),
      assets: (json['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(UpdateAsset.fromJson)
          .where((asset) => asset.name.isNotEmpty)
          .toList(growable: false),
      publishedAt: json['publishedAt'] == null
          ? null
          : DateTime.tryParse('${json['publishedAt']}'),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'tag': tag,
    'body': body,
    'pageUrl': pageUrl.toString(),
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
    'publishedAt': publishedAt?.toIso8601String(),
  };

  /// 取某个资产名对应的下载地址。
  ///
  /// 资产清单里没有时**按命名规则直接拼**：发版流水线（`.github/workflows/
  /// release.yml`）给资产起的名字是固定的 `Mova-<版本>-<平台><架构>.<后缀>`，
  /// tag 也必然是 `v<版本>`，所以 `releases/download/<tag>/<名字>` 一定成立。
  /// 这条兜底让「只有版本号、没有资产清单」的退路也能直接下载。
  UpdateAsset asset(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return UpdateAsset(
      name: name,
      url: Uri.parse(
        'https://github.com/${UpdateChecker.repository}/releases/download/'
        '$tag/$name',
      ),
    );
  }

  static String _versionFromTag(String tag) =>
      tag.replaceAll(RegExp(r'^[^0-9]*'), '');
}

/// 拿到新版本之后「具体怎么更新」。
enum UpdateKind {
  /// Windows 安装版：下载 Setup 并静默安装。
  windowsSetup,

  /// Windows 免安装版：下载 zip，让用户解压覆盖。
  windowsPortable,

  /// 安卓：下载 APK 交给系统安装器。
  androidApk,

  /// 认不出的平台：只能打开发布页。
  pageOnly,
}

/// 一次更新动作的计划：下哪个文件、下载后怎么装。
class UpdatePlan {
  const UpdatePlan({
    required this.kind,
    required this.name,
    required this.url,
    this.size = 0,
  });

  final UpdateKind kind;
  final String name;
  final Uri url;
  final int size;

  bool get canDownload => kind != UpdateKind.pageOnly;

  /// 粗略的下载体积描述，用在取消下载前的确认提示里。
  String get sizeLabel =>
      size <= 0 ? '' : '${(size / 1048576).toStringAsFixed(1)} MB';
}

/// 版本检查：查 GitHub Releases，比版本号，记住「跳过此版本」。
///
/// 三件事必须分开看，否则会写出「每次打开都卡在网络上」或者「一天打八百遍
/// GitHub」两种毛病：
///
/// 1. **网络查询**按 [checkInterval] 节流，只有真的到了间隔才会发请求；
/// 2. 查询结果**写进本地**，所以断网 / 被墙时仍然能拿上一次的结果提示；
/// 3. **提示**不受节流影响 —— 只要本地知道有更新的版本，每次打开都会问一次。
abstract final class UpdateChecker {
  UpdateChecker._();

  /// 仓库坐标。发版与检查更新共用，别在别处再写一遍。
  static const String repository = 'TaoHua-cc/Mova';

  static final Uri _apiLatest = Uri.parse(
    'https://api.github.com/repos/$repository/releases/latest',
  );
  static final Uri _pageLatest = Uri.parse(
    'https://github.com/$repository/releases/latest',
  );

  static const String _cacheKey = 'yingji.update.latest';
  static const String _checkedAtKey = 'yingji.update.checked-at';
  static const String _skipKey = 'yingji.update.skip-version';

  /// 两次**网络**查询之间至少要隔这么久。提示不受它限制。
  static const Duration checkInterval = Duration(hours: 3);

  static const Duration _networkTimeout = Duration(seconds: 12);

  /// 查最新版本。
  ///
  /// [force] 为 true 时无视节流（用户手动点「检查更新」走这条路）。
  /// 返回 null 表示**什么都不知道**（既没查到、本地也没有旧结果）。
  static Future<UpdateRelease?> fetch({bool force = false}) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
    final cached = _readCache(prefs);
    if (!force && _withinInterval(prefs)) return cached;
    final fetched = await _fetchRemote();
    if (fetched == null) return cached;
    try {
      await prefs.setString(_cacheKey, jsonEncode(fetched.toJson()));
      await prefs.setInt(_checkedAtKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // 写不进去只是下次还得再查一遍。
    }
    return fetched;
  }

  /// 本地记着的最新版本（不发网络请求）。启动时先拿它立刻提示。
  static Future<UpdateRelease?> cached() async {
    try {
      return _readCache(await SharedPreferences.getInstance());
    } catch (_) {
      return null;
    }
  }

  /// [release] 是否比当前运行版本新。
  static bool isNewer(UpdateRelease release) =>
      compareVersions(release.version, movaVersion) > 0;

  /// 用户是否已经对 [release] 点过「跳过此版本」。
  static Future<bool> isSkipped(UpdateRelease release) async {
    final skipped = await skippedVersion();
    return skipped != null && skipped == release.version;
  }

  static Future<String?> skippedVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_skipKey);
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> skip(UpdateRelease release) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_skipKey, release.version);
    } catch (_) {
      // 记不住就下次再问一遍，不是什么大事。
    }
  }

  /// 语义化比较版本号，返回负数 / 0 / 正数。
  ///
  /// 只比数字段：`3.1.92+99`、`v3.1.93`、`3.1.93` 都能正确解析，
  /// 缺的段按 0 处理（`3.2` 等于 `3.2.0`）。
  static int compareVersions(String left, String right) {
    final a = _numbers(left);
    final b = _numbers(right);
    for (var index = 0; index < math.max(a.length, b.length); index++) {
      final x = index < a.length ? a[index] : 0;
      final y = index < b.length ? b[index] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// 当前平台该下什么、下完怎么装。
  static UpdatePlan planFor(UpdateRelease release) {
    if (Platform.isAndroid) {
      final name = 'Mova-${release.version}-android-${_androidAbi()}.apk';
      final asset = release.asset(name);
      return UpdatePlan(
        kind: UpdateKind.androidApk,
        name: name,
        url: asset.url,
        size: asset.size,
      );
    }
    if (Platform.isWindows) {
      final setup = release.asset(
        'Mova-${release.version}-Windows-x64-Setup.exe',
      );
      if (isInstalledBuild) {
        return UpdatePlan(
          kind: UpdateKind.windowsSetup,
          name: setup.name,
          url: setup.url,
          size: setup.size,
        );
      }
      final portable = release.asset(
        'Mova-${release.version}-Windows-x64-Portable.zip',
      );
      return UpdatePlan(
        kind: UpdateKind.windowsPortable,
        name: portable.name,
        url: portable.url,
        size: portable.size,
      );
    }
    return UpdatePlan(
      kind: UpdateKind.pageOnly,
      name: '',
      url: release.pageUrl,
    );
  }

  /// 是不是「安装版」（由 Setup.exe 装出来的）。
  ///
  /// Inno Setup 一定会在安装目录里留下卸载器 `unins000.exe`。免安装版
  /// （`Portable.zip` 解压）没有它 —— 这种情况绝不能拿 Setup.exe 去静默安装，
  /// 否则会在默认目录里多装出一份，用户手上那份依旧是旧的。
  static bool get isInstalledBuild {
    if (!Platform.isWindows) return false;
    try {
      final directory = File(Platform.resolvedExecutable).parent;
      return File('${directory.path}${Platform.pathSeparator}unins000.exe')
          .existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 当前设备该拿哪个 ABI 的 APK。
  ///
  /// 直接从 `dart:ffi` 问，比解析 `Build.SUPPORTED_ABIS` 少一趟平台通道。
  static String _androidAbi() {
    try {
      final abi = Abi.current();
      if (abi == Abi.androidArm64) return 'arm64-v8a';
      if (abi == Abi.androidArm) return 'armeabi-v7a';
      if (abi == Abi.androidX64) return 'x86_64';
      if (abi == Abi.androidIA32) return 'x86';
    } catch (_) {
      // 取不到就按绝大多数设备走。
    }
    return 'arm64-v8a';
  }

  static List<int> _numbers(String value) {
    final cleaned = value.replaceAll(RegExp(r'^[^0-9]*'), '');
    if (cleaned.isEmpty) return const [0];
    return cleaned
        .split('.')
        .map((part) {
          final digits = RegExp(r'^[0-9]+').stringMatch(part);
          return digits == null ? 0 : int.tryParse(digits) ?? 0;
        })
        .toList(growable: false);
  }

  static bool _withinInterval(SharedPreferences prefs) {
    final stamp = prefs.getInt(_checkedAtKey);
    if (stamp == null) return false;
    return DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(stamp),
        ) <
        checkInterval;
  }

  static UpdateRelease? _readCache(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return UpdateRelease.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<UpdateRelease?> _fetchRemote() async {
    final fromApi = await _fetchFromApi();
    if (fromApi != null) return fromApi;
    return _fetchFromRedirect();
  }

  /// 首选：GitHub 的 Releases API。
  static Future<UpdateRelease?> _fetchFromApi() async {
    final client = createNetworkHttpClient();
    try {
      final response = await client
          .get(
            _apiLatest,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Mova/$movaVersion ($movaPlatform; Flutter)',
            },
          )
          .timeout(_networkTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final tag = '${data['tag_name'] ?? ''}';
      if (tag.isEmpty) return null;
      return UpdateRelease(
        version: UpdateRelease._versionFromTag(tag),
        tag: tag,
        body: '${data['body'] ?? ''}',
        pageUrl: Uri.parse(
          '${data['html_url'] ?? 'https://github.com/$repository/releases/tag/$tag'}',
        ),
        assets: (data['assets'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(UpdateAsset.fromJson)
            .where((asset) => asset.name.isNotEmpty)
            .toList(growable: false),
        publishedAt: data['published_at'] == null
            ? null
            : DateTime.tryParse('${data['published_at']}'),
      );
    } catch (_) {
      // api.github.com 在部分网络下不可达，交给退路。
      return null;
    } finally {
      client.close();
    }
  }

  /// 退路：不带 API，直接请求 `/releases/latest` 并只读它的 302 目标。
  ///
  /// GitHub 会把它重定向到 `/releases/tag/vX.Y.Z`，版本号就在 Location 里。
  /// 拿不到资产清单也不要紧：[UpdateRelease.asset] 会按命名规则把地址拼出来。
  static Future<UpdateRelease?> _fetchFromRedirect() async {
    final raw = HttpClient()..findProxy = findNetworkProxy;
    try {
      final request = await raw.getUrl(_pageLatest).timeout(_networkTimeout);
      // 不跟随重定向：版本号就在 302 的 Location 里。这个开关在
      // `HttpClientRequest` 上，`HttpClient` 本身没有（那边只有 `findProxy`）。
      request.followRedirects = false;
      final response = await request.close().timeout(_networkTimeout);
      final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
      await response.drain<void>();
      if (location.isEmpty) return null;
      final target = Uri.parse(location);
      final resolved = target.hasScheme
          ? target
          : _pageLatest.resolve(location);
      final match = RegExp(r'/tag/v?([0-9][0-9.]*)').firstMatch(resolved.path);
      if (match == null) return null;
      final version = match.group(1)!;
      return UpdateRelease(
        version: version,
        tag: 'v$version',
        body: '',
        pageUrl: Uri.parse(
          'https://github.com/$repository/releases/tag/v$version',
        ),
        assets: const [],
      );
    } catch (_) {
      return null;
    } finally {
      raw.close(force: true);
    }
  }
}
