import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded discover feed stays virtualized while scrolling', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final embedded = source.substring(
      source.indexOf('if (widget.embedded) {'),
      source.indexOf(
        'return YingjiSmoothWheel(',
        source.indexOf('if (widget.embedded) {'),
      ),
    );

    expect(embedded, contains('SliverFixedExtentList.builder('));
    expect(embedded, contains('itemExtent: 396'));
    expect(embedded, isNot(contains('sliver: SliverVariedExtentList')));
    expect(embedded, isNot(contains('Column(')));
    expect(source, contains('child: CustomScrollView('));
    expect(source, contains('with AutomaticKeepAliveClientMixin'));
    expect(source, contains('_discoverGrowthDebounce ??= Timer('));
  });

  test('recycled posters do not fade in again', () {
    final mediaCenter = File('lib/src/media_center.dart').readAsStringSync();
    final brand = File('lib/src/brand.dart').readAsStringSync();

    expect(brand, contains('BackdropFilter.grouped('));
    expect(brand, contains('enabled: !scrolling'));
    expect(brand, contains('YingjiStableScrollGlass.enabled(context)'));
    expect(
      brand,
      contains(RegExp(r'stableFilter\s*\? BackdropFilter\.grouped\(')),
    );
    expect(mediaCenter, contains('final shellBody = YingjiStableScrollGlass('));
    final embeddedHome = mediaCenter.substring(
      mediaCenter.indexOf('class _HomeFeedPageState'),
      mediaCenter.indexOf('enum _CenterSection'),
    );
    final fullList = mediaCenter.substring(
      mediaCenter.indexOf('class _DiscoverListPageState'),
      mediaCenter.indexOf('class _RankingPosterCard'),
    );
    expect(embeddedHome, contains('stableGlass: true'));
    expect(fullList, contains('stableGlass: true'));
    final shellBackdrop = mediaCenter.substring(
      mediaCenter.indexOf('class _ContinuousShellBackdrop'),
      mediaCenter.indexOf('class _HomeHeroBackdrop'),
    );
    final heroBackdrop = mediaCenter.substring(
      mediaCenter.indexOf('class _HomeHeroBackdrop'),
      mediaCenter.indexOf('class _FloatingHomeRail'),
    );
    expect(shellBackdrop, contains('YingjiBackdrop()'));
    expect(shellBackdrop, isNot(contains('CachedNetworkImage')));
    expect(heroBackdrop, contains('CachedNetworkImage'));
    expect(heroBackdrop, contains('stops: [0, .58, .985]'));
    expect(heroBackdrop, isNot(contains("skipGlass('shell')")));
    expect(
      mediaCenter,
      contains('children: [_HomeHeroBackdrop(), _CinematicHome()]'),
    );
    final posterImage = mediaCenter.substring(
      mediaCenter.indexOf('class _PosterImage'),
      mediaCenter.indexOf('class _MediaHover'),
    );
    expect(posterImage, contains('fadeInDuration: Duration.zero'));
    expect(posterImage, isNot(contains('Transform.scale')));
    final posterStrip = mediaCenter.substring(
      mediaCenter.indexOf('class _PosterStripState'),
      mediaCenter.indexOf('class _LandscapeStrip'),
    );
    final landscapeStrip = mediaCenter.substring(
      mediaCenter.indexOf('class _LandscapeStripState'),
      mediaCenter.indexOf('class _PlatformEntryStrip'),
    );
    final rankStrip = mediaCenter.substring(
      mediaCenter.indexOf('class _RankStripState'),
      mediaCenter.indexOf('class _PosterTile'),
    );
    final historyStrip = mediaCenter.substring(
      mediaCenter.indexOf('class _HistoryStrip'),
      mediaCenter.indexOf('class _ContinueTile'),
    );
    for (final strip in [
      posterStrip,
      landscapeStrip,
      rankStrip,
      historyStrip,
    ]) {
      expect(strip, contains('_withoutScrollbars('));
    }
    // 环宽必须以**物理像素**为单位给出（÷ devicePixelRatio）。具体数值是可调的
    // 外观参数（3.1.112 由 1 提到 1.5，随后圆形玻璃又引入了候选画法），所以这里
    // 断言「口径」而不是数字 —— 否则每次调观感都得回来改测试。
    expect(brand, contains(RegExp(r'strokeWidth = [^;\n]*/ devicePixelRatio')));
    expect(brand, isNot(contains('color: YingjiGlass.accent.withValues(')));
  });

  test('discover hover effects are suspended during scrolling', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final posterHover = source.substring(
      source.indexOf('class _MediaHoverState'),
      source.indexOf('String _duration'),
    );
    final rankTile = source.substring(
      source.indexOf('class _RankTileState'),
      source.indexOf('class _ContinueWatchingPage'),
    );

    expect(posterHover, contains('final hovered = _hovered && !scrolling;'));
    expect(posterHover, contains('if (!yingjiScrollInProgress.value)'));
    expect(posterHover, contains(RegExp(r'scrolling\s*\?\s*Duration.zero')));
    expect(posterHover, contains('_clearHoverWhileScrolling'));
    expect(posterHover, isNot(contains('AnimatedScale')));
    expect(posterHover, isNot(contains('Matrix4.translationValues')));
    expect(posterHover, contains('Colors.transparent'));
    expect(rankTile, contains('_dismissPreviewWhileScrolling'));
    expect(rankTile, contains('if (yingjiScrollInProgress.value) return;'));
  });

  test('discover dialogs keep their glass filters active while scrolling', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final sectionSettings = source.substring(
      source.indexOf('Future<void> _showSectionSettings('),
      source.indexOf('Future<void> _showCardSettings('),
    );
    final sectionOrder = source.substring(
      source.indexOf('Future<void> _showCardSettings('),
      source.indexOf('Future<Map<String, List<TmdbItem>>> _loadSections('),
    );

    expect(sectionSettings, contains('YingjiStableScrollGlass('));
    expect(sectionOrder, contains('YingjiStableScrollGlass('));
  });

  test('discover and player reorder labels stay outside dragged proxies', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final sectionOrder = source.substring(
      source.indexOf('Future<void> _showCardSettings('),
      source.indexOf('Future<Map<String, List<TmdbItem>>> _loadSections('),
    );
    final playerOrder = source.substring(
      source.indexOf('Widget _playerToolOrderList()'),
      source.indexOf('Widget _playerToolTile('),
    );

    expect(sectionOrder, contains("'显示的列表'"));
    expect(sectionOrder, contains(RegExp(r'header:\s*_sections\.any\(')));
    expect(sectionOrder, isNot(contains('firstVisible')));
    expect(playerOrder, contains('proxyDecorator: (child, _, _) => child'));
    expect(playerOrder, contains('onReorderItem: _reorderPlayerTool'));
  });

  test('rank hover preview starts from the complete poster geometry', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final preview = source.substring(
      source.indexOf('class _RankTile extends StatefulWidget'),
      source.indexOf('class _ContinueWatchingPage extends StatefulWidget'),
    );
    expect(preview, contains('widthFactor: .26 + reveal.value * .74'));
    expect(preview, contains('width: 130'));
    expect(preview, contains('height: 236'));
  });
}
