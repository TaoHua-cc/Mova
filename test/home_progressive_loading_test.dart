import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home grows discovery only after scrolling settles', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(source, contains('position.pixels > 4'));
    expect(source, contains('_discoverSectionLimit += 2'));
    expect(source, contains('_discoverGrowthDebounce = Timer'));
    expect(source, contains('sectionLimit: _discoverSectionLimit'));
    expect(source, isNot(contains('_discoverMountTimer')));
    expect(source, isNot(contains('_loadRemainingSections')));
  });

  test('hero loading no longer replaces the whole home canvas with a spinner', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(
      source,
      isNot(
        contains(
          'snapshot.connectionState == ConnectionState.waiting) {\n'
          '          return const Center(child: CircularProgressIndicator());',
        ),
      ),
    );
  });

  test('shared preferences metadata cache is bounded for fast startup', () {
    final source = File('lib/src/metadata/tmdb_client.dart').readAsStringSync();
    expect(source, contains('static const int _tmdbCacheCapacity = 160'));
    expect(source, contains('_rememberWrites++ == 0'));
  });

  test('discovery keeps cached rows while background refresh completes', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(source, contains('snapshot.data ?? _visibleItems'));
    expect(source, contains('_refreshVisibleSections()'));
    expect(source, contains('YingjiImageWarmup.items(rows, maxItems: 6)'));
    expect(
      source,
      isNot(contains('setState(() => _items = _loadSections());')),
    );
  });

  test('discover editor and full list use stable desktop interactions', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(source, contains('proxyDecorator: (child, _, _) => child'));
    final fullList = source.substring(
      source.indexOf('class _DiscoverListPageState'),
      source.indexOf('class _RankingPosterCard'),
    );
    expect(fullList, contains('child: YingjiSmoothWheel('));
    expect(fullList, contains('physics: yingjiWheelPhysics'));
  });
}
