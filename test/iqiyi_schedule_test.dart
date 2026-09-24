import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingji/src/metadata/iqiyi_schedule.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';

void main() {
  test('resolves exact results and rejects fuzzy iQIYI search titles', () {
    final response = {
      'data': {
        'templates': [
          {
            'albumInfo': {
              'title': '择日飞升',
              'qipuId': 123,
              'updateTime': {'value': '每周六9:00更新1集'},
            },
          },
          {
            'albumInfo': {'title': '择日飞升 全集解说', 'qipuId': 124},
          },
        ],
      },
    };
    expect(exactIqiyiAlbumInfo(response, '择日飞升')?['qipuId'], 123);
  });

  test('ambiguous exact search results are rejected', () {
    final response = {
      'data': {
        'templates': [
          {
            'albumInfo': {'title': '择日飞升', 'qipuId': 123},
          },
          {
            'albumInfo': {'title': '择日飞升', 'qipuId': 124},
          },
        ],
      },
    };
    expect(exactIqiyiAlbumInfo(response, '择日飞升'), isNull);
  });

  test(
    'parses announced update cadence and computes the next China-local slot',
    () {
      final schedule = parseIqiyiReleaseSchedule(
        '更新至12集 / 共30集 每周六9:00更新1集，会员抢先看',
      )!;
      expect(schedule.weekday, DateTime.saturday);
      expect(schedule.hour, 9);
      expect(schedule.minute, 0);
      expect(schedule.releasedEpisodes, 12);
      expect(schedule.totalEpisodes, 30);
      expect(
        schedule.nextReleaseAfter(DateTime(2026, 9, 24, 12)),
        DateTime(2026, 9, 26, 9),
      );
    },
  );

  test('does not invent a time when only a weekly day is shown', () {
    expect(parseIqiyiReleaseSchedule('每周六更新1集'), isNull);
  });

  test(
    'TMDB China title resolves the official iQIYI next episode schedule',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final client = TmdbClient(
        client: MockClient((request) async {
          if (request.url.host == Uri.parse(TmdbClient.managedEndpoint).host &&
              request.url.path == '/tmdb/tv/42') {
            return http.Response(
              jsonEncode({
                'id': 42,
                'name': '择日飞升',
                'original_name': '择日飞升',
                'origin_country': ['CN'],
                'number_of_episodes': 30,
                'seasons': [],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.host == 'api.tvmaze.com') {
            return http.Response('[]', 200);
          }
          if (request.url.host == 'mesh.if.iqiyi.com') {
            expect(request.url.path, '/portal/lw/search/homePageV3');
            expect(request.url.queryParameters['key'], '择日飞升');
            expect(request.headers['referer'], 'https://so.iqiyi.com/');
            return http.Response(
              jsonEncode({
                'data': {
                  'templates': [
                    {
                      'albumInfo': {
                        'title': '择日飞升',
                        'qipuId': 7909856612089201,
                        'subscriptContent': '更新至12集',
                        'totalNumber': 30,
                        'updateTime': {'value': '每周六9:00更新1集，会员抢先看'},
                      },
                    },
                    {
                      'albumInfo': {
                        'title': '择日飞升 全集解说',
                        'qipuId': 2528125939877501,
                      },
                    },
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final episodes = await client.upcomingEpisodes(
        const TmdbItem(id: 42, title: '择日飞升', kind: '剧集'),
      );
      expect(episodes, hasLength(1));
      expect(episodes.single.episodeNumber, 13);
      expect(episodes.single.totalEpisodes, 30);
      expect(episodes.single.network, 'iQIYI');
      expect(episodes.single.timeKnown, isTrue);
      expect(episodes.single.airDate.weekday, DateTime.saturday);
      expect(episodes.single.airDate.hour, 9);
      client.dispose();
    },
  );
}
