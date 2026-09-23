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
