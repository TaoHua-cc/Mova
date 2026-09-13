import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../metadata/tmdb_client.dart';

/// 图片预热（把海报、剧照、头像提前写进磁盘缓存）。
///
/// `CachedNetworkImage` 只在图片真正进入视口时才去下载，所以第一次打开榜单
/// 时满屏都是占位块，滚一屏卡一下。这里在**数据刚到手**时就把这批 URL 写进
/// 同一份磁盘缓存（`DefaultCacheManager` 正是 `CachedNetworkImage` 默认用的
/// 那一个），于是之后每次打开都能直接从磁盘命中，界面立即成型。
///
/// 全部是「尽力而为」：失败只吞掉异常，不影响任何渲染路径；同一张图只入队
/// 一次；`downloadFile` 对仍然有效（未过期）的缓存是直接命中，不产生网络请求，
/// 所以重复调用它很便宜。
abstract final class YingjiImageWarmup {
  /// 同时下载的张数。太小预热慢，太大在手机上会和视频流抢带宽。
  static const int _maxConcurrent = 3;

  static final Set<String> _queued = <String>{};
  static final List<String> _queue = <String>[];
  static bool _draining = false;

  /// 把一组图片地址排进预热队列。
  static void urls(Iterable<Uri?> values, {int maxUrls = 120}) {
    var added = 0;
    for (final value in values) {
      if (value == null) continue;
      final key = value.toString();
      if (!_queued.add(key)) continue;
      _queue.add(key);
      if (++added >= maxUrls) break;
    }
    if (added > 0) unawaited(_drain());
  }

  /// 榜单/列表卡片。默认只预热海报；横向大卡片再带上清晰剧照与标题 logo。
  ///
  /// 数量按 [maxItems] 卡住：栏目多的时候一次预热全部海报已经不少，
  /// 首屏那几张再额外带上大图，避免第一次打开就下几十兆。
  static void items(
    Iterable<TmdbItem> values, {
    bool backdrop = false,
    bool logo = false,
    int maxItems = 24,
  }) => urls(
    [
      for (final item in values.take(maxItems)) ...[
        item.posterUrl,
        if (backdrop) item.backdropUrl,
        if (logo) item.logoUrl,
      ],
    ],
  );

  /// 演员头像。
  static void people(
    Iterable<TmdbPerson> values, {
    int maxItems = 40,
  }) => urls(
    [
      for (final person in values.take(maxItems)) person.profileUrl,
    ],
  );

  /// 剧集剧照。
  static void episodes(
    Iterable<TmdbEpisode> values, {
    int maxItems = 40,
  }) => urls(
    [
      for (final episode in values.take(maxItems)) episode.stillUrl,
    ],
  );

  /// 季海报。
  static void seasons(
    Iterable<TmdbSeason> values, {
    int maxItems = 24,
  }) => urls(
    [
      for (final season in values.take(maxItems)) season.posterUrl,
    ],
  );

  static Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(_maxConcurrent).toList(growable: false);
        _queue.removeRange(0, batch.length);
        await Future.wait(batch.map(_fetch));
      }
    } finally {
      _draining = false;
    }
  }

  static Future<void> _fetch(String url) async {
    try {
      await DefaultCacheManager().downloadFile(url);
    } catch (_) {
      // 预热失败不需要处理：真正渲染这张图时还会再试一次。
      // 这里放开去重标记，好让下一次预热有机会补上。
      _queued.remove(url);
    }
  }
}
