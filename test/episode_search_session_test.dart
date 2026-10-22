import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/src/metadata/metadata_detail_page.dart')
      .readAsStringSync();
  test(
    'episode tasks are scoped to detail state and explicit retry forces search',
    () {
      expect(
        source,
        contains('final _episodeSearchTasks = <String, Future<void>>{}'),
      );
      expect(source, contains('force ? null : _episodeSearchTasks[key]'));
      expect(source, contains('_searchSelectedEpisode(force: true)'));
      expect(source, contains('await task;'));
      expect(
        source,
        contains('_episodeSearchRevisions[_episodeKey(season, episode)] =='),
      );
      expect(source, contains('generation == _searchGeneration'));
    },
  );
  test('number rail uses aired dates and selects instead of playing', () {
    final numbers = source
        .split('class _PublishedEpisodeNumbers')
        .last
        .split('class _CatalogEpisodeRail')
        .first;
    expect(numbers, contains('episode.airDate!.isBefore(tomorrow)'));
    expect(numbers, contains('MovaHorizontalDrag'));
    expect(numbers, contains('SizedBox(width: 4)'));
    expect(numbers, contains('circle: true'));
    expect(numbers, contains('YingjiGlassSurface'));
    expect(numbers, isNot(contains('ChoiceChip')));
    expect(numbers, contains('onSelect(episode)'));
    expect(numbers, isNot(contains('onPlay')));
    expect(
      source.indexOf('_PublishedEpisodeNumbers(\n'),
      lessThan(
        source.indexOf("key: const ValueKey('catalog-episode-previews')"),
      ),
    );
  });

  test('episode previews prefer aired episode art then title artwork', () {
    final normalized = source.replaceAll(RegExp(r'\s+'), ' ');
    expect(normalized, contains('required this.serverArtwork'));
    expect(normalized, contains('episodeUrl: episode.stillUrl'));
    expect(normalized, contains('episodeAirDate: episode.airDate'));
    expect(normalized, contains('serverArtwork['));
    expect(normalized, contains('backdropUrl: widget.backdropUrl'));
    expect(normalized, contains('posterUrl: widget.posterUrl'));
    expect(
      normalized,
      contains(
        'episodeAirDate == null || !episodeAirDate!.isAfter(DateTime.now())',
      ),
    );
    expect(normalized, contains('if (episodeHasAired) ?episodeUrl'));
    expect(normalized, contains('if (episodeHasAired) ?serverEpisodeUrl'));
    expect(normalized, contains('?backdropUrl'));
    expect(normalized, contains('?posterUrl'));
    expect(
      normalized,
      contains('errorWidget: (_, _, _) => imageAt(index + 1)'),
    );
    expect(
      normalized,
      contains('_loadServerEpisodeArtwork(session, seriesId, season)'),
    );
  });
}
