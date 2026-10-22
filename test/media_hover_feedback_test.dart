import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/src/media_center.dart').readAsStringSync();
  test(
    'rank preview anchor is inside the floating poster, without old offset',
    () {
      final rank = source
          .split('class _RankTileState ')
          .last
          .split('class _RankHoverPreview ')
          .first;
      expect(
        rank.indexOf('CompositedTransformTarget('),
        greaterThan(rank.indexOf('child: _MediaHover(')),
      );
      expect(rank, contains('offset: Offset.zero'));
      expect(rank, isNot(contains('Offset(showOnRight ? 36')));
    },
  );
  testWidgets('preview top edge follows poster transform in both directions', (
    tester,
  ) async {
    for (final right in [true, false]) {
      final link = LayerLink();
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Positioned(
                left: 250,
                top: 100,
                child: Transform.translate(
                  offset: const Offset(0, -3.54),
                  child: Transform.scale(
                    scale: 1.018,
                    child: CompositedTransformTarget(
                      link: link,
                      child: const SizedBox(
                        key: Key('poster'),
                        width: 130,
                        height: 236,
                      ),
                    ),
                  ),
                ),
              ),
              CompositedTransformFollower(
                link: link,
                targetAnchor: right ? Alignment.topLeft : Alignment.topRight,
                followerAnchor: right ? Alignment.topLeft : Alignment.topRight,
                child: const SizedBox(
                  key: Key('preview'),
                  width: 500,
                  height: 236,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      final poster = tester.renderObject<RenderBox>(
        find.byKey(const Key('poster')),
      );
      final preview = tester.renderObject<RenderBox>(
        find.byKey(const Key('preview')),
      );
      final p = poster.localToGlobal(Offset(right ? 0 : 130, 0));
      final f = preview.localToGlobal(Offset(right ? 0 : 500, 0));
      expect(f.dx, closeTo(p.dx, .01));
      expect(f.dy, closeTo(p.dy, .01));
      expect(
        preview.localToGlobal(const Offset(0, 236)).dy,
        closeTo(poster.localToGlobal(const Offset(0, 236)).dy, .01),
      );
    }
  });
  test('discover, all-list and continue artwork share hover feedback', () {
    for (final type in [
      '_PosterTile',
      '_LandscapeTile',
      '_RankingPosterCard',
      '_ContinueTile',
      '_RankTileState',
    ]) {
      final body = source.split('class $type ').last.split('\nclass ').first;
      expect(body, contains('_MediaHover('), reason: type);
    }
  });
  test(
    'hover lifts by transform and draws its edge without resizing content',
    () {
      final hover = source
          .split('class _MediaHoverState ')
          .last
          .split('String _duration')
          .first;
      expect(hover, contains('_hovered ? 1.018 : 1'));
      expect(hover, contains('Offset(0, -.015)'));
      expect(hover, contains('foregroundDecoration: BoxDecoration('));
      expect(hover, contains('width: _hovered ? 1.4 : 1'));
      final background = hover
          .split('decoration: BoxDecoration(')
          .last
          .split('foregroundDecoration:')
          .first;
      expect(background, isNot(contains('Border.all')));
      expect(hover, contains('_hovered = _pointerInside'));
      expect(hover, contains('_clearHoverWhileScrolling'));
    },
  );
}
