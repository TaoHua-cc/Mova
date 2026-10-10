import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/cache/video_cache.dart';
import 'package:yingji/src/network/proxy_routing.dart';
import 'package:yingji/src/player/windows_native_player.dart';

void main() {
  test('Windows next preparation uses a paused native session, not a prefix download', () {
    final dart = File('lib/src/player/windows_native_player.dart')
        .readAsStringSync();
    final preparation = dart.substring(
      dart.indexOf('Future<void> prepareNextEpisode('),
      dart.indexOf(
        'unawaited(',
        dart.indexOf('Future<void> prepareNextEpisode('),
      ),
    );
    expect(preparation, isNot(contains('.download(')));
    expect(preparation, contains('MOVA_EPISODE_PREPARED='));
    expect(preparation, contains('nextPreparationAllowed'));
    final native = File('windows/native_player/main.cpp').readAsStringSync();
    final promotion = native.substring(
      native.indexOf('bool PromotePreparedSession('),
      native.indexOf('bool LoadPlaylistEntry('),
    );
    expect(promotion, isNot(contains('{"loadfile"')));
      expect(promotion, contains('g_handle = g_prepared_handle;'));
      expect(promotion, contains('MpvString("current-ao")'));
      expect(promotion, isNot(contains('? "auto"')));
    expect(native, contains('option("pause", "yes")'));
    expect(native, contains('option("start", "0")'));
    expect(native, contains('case kCancelPreparedSession:'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('HTTP and HTTPS default to native without a cache store', () async {
    await ProxyRouting.load();
    for (final url in ['http://media.invalid/a', 'https://media.invalid/b']) {
      expect(await windowsPlaybackUrl(url, cache: null), url);
      expect(windowsNativeNetworkInput(url, url), isTrue);
    }
    expect(await windowsPlaybackUrl('', cache: null), '');
    expect(
      windowsNativeNetworkInput(r'C:\movie.mkv', r'C:\movie.mkv'),
      isFalse,
    );
  });

  test('enabled server proxy keeps authenticated loopback routing', () async {
    await ProxyRouting.load();
    await ProxyRouting.setServerProxy('proxy-server', true);
    final root = await Directory.systemTemp.createTemp('mova-native-route-');
    final cache = VideoCacheStore.forDirectory(root);
    const url = 'https://media.invalid/authenticated';
    try {
      final playback = await windowsPlaybackUrl(
        url,
        cache: cache,
        sourceId: 'proxy-server',
        headers: const {'Authorization': 'test-only'},
      );
      expect(playback, startsWith('http://127.0.0.1:'));
      expect(windowsNativeNetworkInput(url, playback), isFalse);
      expect(
        await windowsRecoveryUrl(url, cache: cache, sourceId: 'proxy-server'),
        startsWith('http://127.0.0.1:'),
      );
      expect(
        await windowsRecoveryUrl(url, cache: cache, sourceId: 'direct'),
        url,
      );
      expect(
        await windowsPlaybackUrl(url, cache: cache, sourceId: 'direct'),
        url,
      );
      await expectLater(
        windowsPlaybackUrl(url, cache: null, sourceId: 'proxy-server'),
        throwsStateError,
      );
    } finally {
      await cache.closePlaybackProxy();
      await root.delete(recursive: true);
    }
  });

  test('native child cannot inherit environment proxy settings', () {
    expect(
      windowsPlaybackEnvironment({
        'HTTP_PROXY': 'http://proxy.invalid',
        'https_proxy': 'http://proxy.invalid',
        'All_Proxy': 'socks5://proxy.invalid',
        'NO_PROXY': '*',
        'PATH': 'test-path',
      }),
      {'PATH': 'test-path'},
    );
  });

  test(
    'completed legacy cache plays locally without another origin request',
    () async {
      await ProxyRouting.load();
      final root = await Directory.systemTemp.createTemp(
        'mova-complete-native-',
      );
      final cache = VideoCacheStore.forDirectory(root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        final bytes = List<int>.generate(512, (index) => index % 256);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/cached';
      try {
        final job = cache.download(url: url, limitBytes: 1024);
        await job.done;
        expect(job.state.status, VideoCacheStatus.complete);
        final before = requests;
        final playback = await windowsPlaybackUrl(url, cache: cache);
        expect(await File(playback).length(), 512);
        expect(windowsNativeNetworkInput(url, playback), isFalse);
        expect(requests, before);
        expect(await windowsRecoveryUrl(url, cache: cache), url);
        expect(requests, before);
      } finally {
        await cache.closePlaybackProxy();
        await server.close(force: true);
        await subscription.cancel();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'native first load and episode switch apply the exact entry headers',
    () {
      final native = File('windows/native_player/main.cpp').readAsStringSync();
      final dart = File('lib/src/player/windows_native_player.dart')
          .readAsStringSync();
      expect(native, contains('ApplyPlaylistHeaders(start_index);'));
      expect(native, contains('ApplyPlaylistHeaders(index);'));
      expect(native, contains('g_stream_recovered_index != recovery_index'));
      expect(native, contains('g_stream_recovered_index = recovery_index;'));
      expect(
        native,
        contains(
          'g_playlist_resumes[item] = std::max(0.0, update->resume_seconds);',
        ),
      );
      expect(dart, contains('final url = await windowsRecoveryUrl('));
      expect(native, contains('update->native_network'));
      expect(native, contains('frame_now - last_network_sample_ms >= 1000.0'));
      expect(native, contains('MpvString("cache-speed")'));
      expect(dart, contains('includeParentEnvironment: false'));
      expect(dart, contains("'--tls-verify=yes'"));
      expect(dart, contains('if (!usesRelay(activeCacheIndex)) return;'));
      expect(dart, contains('preparedIndices.contains(index)'));
      expect(dart, contains('shouldPreloadNextEpisode('));
    },
  );
}
