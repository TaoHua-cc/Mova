import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedded discover feed stays virtualized while scrolling', () {
    final source = File('lib/src/media_center.dart').readAsStringSync();
    final embedded = source.substring(
      source.indexOf('if (widget.embedded) {'),
      source.indexOf(
        'return ListView.builder(',
        source.indexOf('if (widget.embedded) {'),
      ),
    );

    expect(embedded, contains('SliverFixedExtentList.builder('));
    expect(embedded, contains('itemExtent: 396'));
    expect(embedded, isNot(contains('sliver: SliverVariedExtentList')));
    expect(embedded, isNot(contains('Column(')));
    expect(source, contains('child: CustomScrollView('));
    expect(source, contains('with AutomaticKeepAliveClientMixin'));
  });

  test('media shell groups shared glass backdrop reads', () {
    final mediaCenter = File('lib/src/media_center.dart').readAsStringSync();
    final brand = File('lib/src/brand.dart').readAsStringSync();

    expect(mediaCenter, contains('final shellBody = BackdropGroup('));
    expect(brand, contains('BackdropFilter.grouped('));
    expect(brand, contains('enabled: !scrolling'));
    expect(mediaCenter, contains('enabled: !scrolling'));
    expect(brand, contains('yingjiScrollInProgress.value = true'));
    expect(brand, contains('yingjiScrollInProgress.value = false'));
    expect(brand, contains('final strokeWidth = 1.5 / devicePixelRatio'));
    expect(brand, contains('YingjiGlass.accent.withValues('));
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
