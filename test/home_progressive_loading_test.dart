import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'home keeps discover geometry stable and loads nearby data after settle',
    () {
      final source = File('lib/src/media_center.dart').readAsStringSync();
      expect(source, contains('bool _showDiscover = true'));
      expect(source, contains('int _discoverSectionLimit = 0'));
      expect(source, contains('position.viewportDimension * .55'));
      expect(source, contains('current.viewportDimension * .55'));
      expect(source, contains('/ 396).ceil()'));
      expect(
        source,
        contains('setState(() => _discoverSectionLimit = nextLimit)'),
      );
      expect(source, contains('_discoverGrowthDebounce ??= Timer('));
      expect(source, contains('sectionLimit: _discoverSectionLimit'));
      final initialize = source.substring(
        source.indexOf(
          'Future<Map<String, List<TmdbItem>>> _initializeSections',
        ),
        source.indexOf('bool _extendingSections'),
      );
      expect(initialize, contains('await _restoreLayout();'));
      expect(initialize, contains('if (mounted) {'));
      expect(initialize, contains('setState(() {});'));
      expect(initialize, contains('widget.onLayoutRestored?.call()'));
      expect(
        source,
        contains('snapshot.data ?? const <String, List<TmdbItem>>{}'),
      );
      expect(source, isNot(contains('_discoverMountTimer')));
      expect(source, isNot(contains('_loadRemainingSections')));
    },
  );

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

  test('carousel loads title logos for the active and upcoming items', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(
      source,
      contains('_selectHero((_hero + 1) % items.length.clamp(1, 8))'),
    );
    expect(source, contains('onChanged: _selectHero'));
    expect(source, contains('_loadHeroDetail(_trendingValue[index])'));
    expect(source, contains('_loadHeroDetail(_trendingValue[nextIndex])'));
    expect(source, contains('YingjiImageWarmup.items([detail], logo: true'));
  });

  test('shared preferences metadata cache is bounded for fast startup', () {
    final source = File('lib/src/metadata/tmdb_client.dart').readAsStringSync();
    expect(source, contains('static const int _tmdbCacheCapacity = 160'));
    expect(source, contains('_rememberWrites++ == 0'));
  });

  test('discovery keeps cached rows while background refresh completes', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    expect(
      source,
      contains('snapshot.data ?? const <String, List<TmdbItem>>{}'),
    );
    expect(source, contains('_refreshVisibleSections()'));
    expect(source, contains('_visibleItems = {..._visibleItems, ...updates}'));
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
