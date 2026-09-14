import 'package:shared_preferences/shared_preferences.dart';

/// 服务器级代理路由：决定某个媒体服务器（Emby / Jellyfin / WebDAV）的
/// 请求是否走系统代理。
///
/// 语义（与「软件自身流量」区分开）：
/// - **软件自身流量**（TMDB 元数据与海报、应用更新、弹幕）**始终跟随系统代理**：
///   系统开了代理就走，没开走正常网络。这部分由 [createNetworkHttpClient]
///   的 `_findProxy` 统一处理，与本模块无关。
/// - **服务器流量**（某个 Emby/Jellyfin 的浏览、聚合、元数据、图片）：默认**直连**，
///   只有用户在「设置 → 代理」里勾选了该服务器，才跟随系统代理。
/// 播放内核不经过 Dart HttpClient；本设置控制软件对服务器发起的 API、媒体库、
/// 聚合、元数据与图片请求。
///
/// 开关集合持久化在 `yingji.proxy.servers`，存逗号分隔的服务器 id。
abstract final class ProxyRouting {
  static const String _key = 'yingji.proxy.servers';

  /// 内存态集合，避免每次请求都去读 prefs。启动时由 [load] 灌入。
  static final Set<String> _proxyServerIds = <String>{};

  /// 启动时从 prefs 读入开关集合。main() 里 SharedPreferences 就绪后调用。
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key) ?? '';
    _proxyServerIds
      ..clear()
      ..addAll(
        raw.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty),
      );
  }

  /// 该服务器是否勾选了「跟随系统代理」。
  static bool serverUsesProxy(String sourceId) =>
      _proxyServerIds.contains(sourceId);

  /// 当前勾选了「跟随系统代理」的服务器 id 集合（只读快照）。
  static Set<String> get proxyServerIds => Set.unmodifiable(_proxyServerIds);

  /// 设置/取消某服务器的代理开关，并写盘。
  static Future<void> setServerProxy(String sourceId, bool enabled) async {
    if (enabled) {
      _proxyServerIds.add(sourceId);
    } else {
      _proxyServerIds.remove(sourceId);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _proxyServerIds.join(','));
  }
}
