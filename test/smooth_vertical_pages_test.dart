import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flowing backdrop pauses while a page is scrolling', () {
    final source = File('lib/src/brand.dart').readAsStringSync();

    expect(source, contains('yingjiScrollInProgress.value = true;'));
    expect(source, contains('_flow.stop(canceled: false);'));
    expect(source, contains('_flow.repeat(reverse: true);'));
  });

  String classBody(String source, String className) {
    final start = source.indexOf('class $className');
    expect(start, isNonNegative, reason: 'missing $className');
    final open = source.indexOf('{', start);
    var depth = 0;
    for (var index = open; index < source.length; index++) {
      if (source[index] == '{') depth++;
      if (source[index] == '}' && --depth == 0) {
        return source.substring(open, index + 1);
      }
    }
    throw StateError('unbalanced $className');
  }

  test('every primary vertical media page uses the shared smooth wheel', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    for (final name in [
      '_HomeFeedPageState',
      '_RankingPageState',
      '_DiscoverListPageState',
      '_SearchPageState',
      '_SourceHubState',
      '_PlaylistsPageState',
      '_CalendarPageState',
      '_SettingsPageState',
      '_ContinueWatchingPageState',
    ]) {
      final body = classBody(source, name);
      expect(body, contains('YingjiSmoothWheel('), reason: name);
      expect(body, contains('stableGlass: true'), reason: name);
    }
  });

  test('Android home hero supports horizontal swipe carousel navigation', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final home = classBody(source, '_CinematicHomeState');
    expect(home, contains('onHorizontalDragStart: Platform.isAndroid'));
    expect(home, contains('onHorizontalDragUpdate: Platform.isAndroid'));
    expect(home, contains('onHorizontalDragEnd: Platform.isAndroid'));
    expect(home, contains('distance.abs() >= threshold'));
    expect(home, contains('direction < 0 ? 1 : -1'));
  });

  test('Android restores persisted discovery section poster snapshots', () {
    final media = File('lib/src/media_center.dart').readAsStringSync();
    final cache = File('lib/src/cache/discover_snapshot_cache.dart')
        .readAsStringSync();
    final discover = classBody(media, '_DiscoverPageState');
    expect(discover, contains('DiscoverSnapshotCache.read('));
    expect(discover, contains('DiscoverSnapshotCache.write('));
    expect(discover, contains('refreshed[section] = rows'));
    expect(discover, contains('Platform.isAndroid && refreshed.isNotEmpty'));
    expect(
      discover,
      contains(
        'if (!Platform.isWindows && !Platform.isAndroid) return const {}',
      ),
    );
    expect(cache, contains('Platform.isAndroid'));
    expect(cache, contains('await _readAndroid(key)'));
    expect(cache, contains('await _writeAndroid(key, value)'));
    expect(cache, contains('const _capacity = 96'));
  });

  test('standalone detail and library pages use the same wheel', () {
    final files = {
      'PlaylistDetailPage': 'lib/src/playlists/playlist_detail_page.dart',
      'EmbyLibraryPage': 'lib/src/sources/source_library_page.dart',
      '_PersonPage': 'lib/src/metadata/metadata_detail_page.dart',
    };
    for (final entry in files.entries) {
      final source = File(entry.value).readAsStringSync();
      expect(source, contains('YingjiSmoothWheel('), reason: entry.key);
      expect(source, contains('stableGlass: true'), reason: entry.key);
      expect(
        source,
        contains('physics: yingjiWheelPhysics'),
        reason: entry.key,
      );
    }
  });

  test('detail shelves and overflow lists use shared smooth scrolling', () {
    final source = File('lib/src/metadata/metadata_detail_page.dart')
        .readAsStringSync();
    for (final name in [
      '_SeasonRailState',
      '_EpisodePreviewRailState',
      '_ResourceSectionState',
      '_DetailExtrasSectionState',
      '_TrackPickerPaneState',
      '_PersonPageState',
    ]) {
      expect(
        classBody(source, name),
        contains('YingjiSmoothWheel('),
        reason: name,
      );
    }
    final collections = source.substring(
      source.indexOf('Future<void> _showDetailCollection('),
      source.indexOf('class _FilterablePersonGrid'),
    );
    expect(collections, contains('YingjiSmoothWheel('));
    for (final name in [
      '_FilterablePersonGridState',
      '_FilterableRecommendationGridState',
    ]) {
      expect(
        classBody(source, name),
        contains('controller: widget.controller'),
      );
    }
    final wheel = classBody(
      File('lib/src/brand.dart').readAsStringSync(),
      '_YingjiSmoothWheelState',
    );
    expect(wheel, contains('position.axisDirection'));
    expect(
      wheel,
      contains('horizontal ? event.scrollDelta.dx : event.scrollDelta.dy'),
    );
    expect(wheel, isNot(contains('event.scrollDelta.dx == 0')));
    expect(wheel, contains('pointerSignalResolver.register(event, (_)'));
  });

  test(
    'Windows detail scroll pauses glass while episode dialog keeps blur',
    () {
      final source = File('lib/src/metadata/metadata_detail_page.dart')
          .readAsStringSync();
      final detail = classBody(source, '_MetadataDetailPageState');
      expect(detail, contains('stableGlass: !WindowHost.isDesktop'));
      expect(detail, contains('ValueListenableBuilder<double>'));
      expect(
        detail,
        contains('(WindowHost.isDesktop && yingjiScrollInProgress.value)'),
      );

      final episodeRail = classBody(source, '_CatalogEpisodeRailState');
      final dialogStart = episodeRail.indexOf('Future<void> _showAll()');
      expect(dialogStart, isNonNegative);
      expect(
        episodeRail.substring(dialogStart),
        contains('YingjiStableScrollGlass('),
      );
    },
  );

  test('discover data updates only the changed shelf', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final body = classBody(source, '_DiscoverPageState');
    expect(body, contains('ValueListenableBuilder<List<TmdbItem>>'));
    expect(body, contains('_publishSections(updates)'));
    expect(
      body,
      isNot(contains('setState(() {\n        _visibleItems = next;')),
    );
  });

  test('server source card grows to keep primary-line latency visible', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final card = classBody(source, '_SourceCardState');
    expect(card, contains('constraints: const BoxConstraints(minHeight: 144)'));
    expect(card, isNot(contains('height: 128')));
  });

  test('settings scroll uses cached section offsets while scrolling', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final settings = classBody(source, '_SettingsPageState');
    final syncStart = settings.indexOf('void _syncActiveSetting()');
    final jumpStart = settings.indexOf(
      'Future<void> _jumpToSetting(',
      syncStart,
    );
    expect(syncStart, isNonNegative);
    expect(jumpStart, greaterThan(syncStart));
    final sync = settings.substring(syncStart, jumpStart);
    expect(settings, contains('_settingSectionOffsets = offsets;'));
    expect(sync, contains('final offsets = _settingSectionOffsets;'));
    expect(sync, contains('while (low < high)'));
    expect(sync, isNot(contains('getOffsetToReveal')));
  });

  test('discover reorder dialog shares smooth wheel and mouse drag', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final body = classBody(source, '_DiscoverPageState');
    final start = body.indexOf('Future<void> _showCardSettings()');
    expect(start, isNonNegative);
    final dialog = body.substring(start);
    expect(dialog, contains('YingjiSmoothWheel('));
    expect(dialog, contains('controller: orderScrollController'));
    expect(dialog, contains('physics: yingjiWheelPhysics'));
    expect(dialog, contains('ReorderableDragStartListener('));
  });

  test('home maximize action reflects the actual window state', () {
    final brand = File('lib/src/brand.dart').readAsStringSync();
    final controls = classBody(brand, '_YingjiWindowControlsState');
    expect(controls, contains('bool _syncPending = false;'));
    expect(controls, contains('_syncPending = true;'));
    expect(controls, contains("active ? '还原' : '最大化'"));

    final mediaCenter = File('lib/src/media_center.dart').readAsStringSync();
    final homeBar = classBody(mediaCenter, '_FloatingHomeTopBar');
    expect(homeBar, contains('YingjiWindowControls(size: 46)'));
    expect(homeBar, isNot(contains("tooltip: '最大化'")));
  });
}
