import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/player/subtitle_search_service.dart';

void main() {
  group('subtitle result parsing', () {
    test('parses numeric and alphanumeric SubHD ids, then deduplicates', () {
      final results = SubtitleSearchService.parseSubHdSearchPage('''
        <ul>
          <li><a href="/a/123" data-lang="简体中文">剧名 S01E02</a>
          <span>格式：ASS</span></li>
          <li><a href="/a/123">重复结果</a></li>
          <li><a href="/a/456/">剧名 S01E02</a><span>格式：SRT</span></li>
          <li><a href="/a/pQULiK">鼠惑 S01E01</a><span>格式：SRT</span></li>
          <li><a href="/a/not/valid">无效</a></li>
        </ul>
        ''', baseUri: Uri.https('www.subhd.me', '/search/剧名'));

      expect(results, hasLength(3));
      expect(results.first.providerId, '123');
      expect(results.first.language, '简体中文');
      expect(results.first.fileName, '剧名 S01E02.ass');
      expect(results[1].providerId, '456');
      expect(results[1].fileName, '剧名 S01E02.srt');
      expect(results.last.providerId, 'pQULiK');
      expect(results.last.referrer.path, '/a/pQULiK');
    });

    test('parses nested Gestdown response and subtitle metadata', () {
      final results = SubtitleSearchService.parseGestdownResults(
        {
          'data': {
            'subtitles': [
              {
                'subtitleId': 'gd-123',
                'fileName': 'Example.S01E02.en.srt',
                'language': 'English',
              },
            ],
          },
        },
        referrer: Uri.https('api.gestdown.info', '/subtitles/get/show/1/2/en'),
        queryLanguage: 'en',
      );

      expect(results, hasLength(1));
      expect(results.single.providerId, 'gd-123');
      expect(results.single.fileName, 'Example.S01E02.en.srt');
      expect(results.single.language, 'English');
      expect(results.single.downloadUri.path, '/subtitles/download/gd-123');
    });

    test('identifies a SubHD verification page without bypassing it', () {
      expect(
        () => SubtitleSearchService.parseSubHdSearchPage(
          '<html><title>Captcha</title><body>verify you are human</body></html>',
          baseUri: Uri.https('www.subhd.me', '/search/example'),
        ),
        throwsA(isA<SubtitleSourceException>()),
      );
    });
  });

  test('searches the requested episode and emits source results as they arrive', () async {
    final requestedPaths = <String>[];
    final gestdownResponse = Completer<http.Response>();
    final firstSubHdResult = Completer<void>();
    var earlySubHdIds = <String>[];
    var searchCompleted = false;
    final service = SubtitleSearchService(
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.host == 'www.subhd.me') {
          return http.Response.bytes(
            utf8.encode(
              '<li><a href="/a/pQULiK">Demo S01E02</a><span>格式：SRT</span></li>',
            ),
            200,
          );
        }
        if (request.url.path == '/shows/search/Demo') {
          return gestdownResponse.future;
        }
        if (request.url.path == '/subtitles/get/demo-id/1/2/en') {
          return http.Response(
            jsonEncode({
              'subtitles': [
                {
                  'subtitleId': 'episode-123',
                  'fileName': 'Demo.S01E02.en.srt',
                  'language': 'English',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );
    addTearDown(service.dispose);

    final search = service.search(
      const SubtitleSearchQuery(
        title: 'Demo',
        season: 1,
        episode: 2,
        language: 'en',
      ),
      onSourceResults: (provider, results, _) {
        if (provider == 'SubHD' && results.isNotEmpty) {
          earlySubHdIds = results.map((result) => result.providerId).toList();
          firstSubHdResult.complete();
        }
      },
    );
    search.then((_) => searchCompleted = true);
    await firstSubHdResult.future.timeout(const Duration(seconds: 2));
    expect(searchCompleted, isFalse);
    expect(earlySubHdIds, ['pQULiK']);
    gestdownResponse.complete(
      http.Response(
        jsonEncode([
          {'showUniqueId': 'demo-id', 'name': 'Demo'},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final response = await search;

    expect(requestedPaths, contains('/subtitles/get/demo-id/1/2/en'));
    expect(response.results.map((result) => result.provider).toSet(), {
      'SubHD',
      'Gestdown',
    }, reason: response.status.toString());
    expect(response.status.keys, {'SubHD', 'Gestdown'});
  });

  test(
    'downloads a zip and selects an applicable subtitle into temp storage',
    () async {
      final temp = await Directory.systemTemp.createTemp('mova-subtitle-test-');
      addTearDown(() => temp.delete(recursive: true));
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'Demo.S01E02.en.srt',
            utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n').length,
            utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n'),
          ),
        );
      final zipBytes = ZipEncoder().encode(archive);
      final service = SubtitleSearchService(
        temporaryDirectory: temp,
        client: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/api/sub/down') {
            expect(jsonDecode(request.body)['sid'], 'pQULiK');
            expect(
              request.headers['referer'],
              'https://www.subhd.me/down/pQULiK',
            );
            return http.Response(
              jsonEncode({
                'success': true,
                'url': 'https://cdn.subhd.tv/subtitle.zip',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.host == 'cdn.subhd.tv') {
            return http.Response.bytes(
              zipBytes,
              200,
              headers: {
                'content-type': 'application/zip',
                'content-disposition': 'attachment; filename="subtitle.zip"',
              },
            );
          }
          if (request.url.path == '/a/pQULiK' ||
              request.url.path == '/down/pQULiK') {
            return http.Response(
              'ok',
              200,
              headers: {'set-cookie': 'session=abc; Path=/'},
            );
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(service.dispose);

      final downloaded = await service.download(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: 'pQULiK',
          title: 'Demo',
          fileName: 'subtitle.zip',
          language: 'English',
          downloadUri: Uri.https('www.subhd.me', '/search/Demo'),
          referrer: Uri.https('www.subhd.me', '/a/pQULiK'),
        ),
      );

      expect(downloaded.fileName, 'Demo.S01E02.en.srt');
      expect(File(downloaded.path).existsSync(), isTrue);
      expect(
        await File(downloaded.path).readAsString(),
        contains('00:00:01,000 --> 00:00:02,000'),
      );
    },
  );

  test('rejects a web challenge returned as a subtitle download', () async {
    final temp = await Directory.systemTemp.createTemp('mova-subtitle-test-');
    addTearDown(() => temp.delete(recursive: true));
    final service = SubtitleSearchService(
      temporaryDirectory: temp,
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response('{"url":"https://cdn.subhd.tv/cap.srt"}', 200);
        }
        if (request.url.path.startsWith('/a/') ||
            request.url.path.startsWith('/down/')) {
          return http.Response('ok', 200);
        }
        return http.Response(
          '<!doctype html><html><body>verification required</body></html>',
          200,
        );
      }),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.download(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: '123',
          title: 'Demo',
          fileName: 'cap.srt',
          language: '中文',
          downloadUri: Uri.https('www.subhd.me', '/search/Demo'),
          referrer: Uri.https('www.subhd.me', '/a/123'),
        ),
      ),
      throwsA(isA<SubtitleSourceException>()),
    );
  });

  test('reports a missing SubHD download record as a download error', () async {
    final service = SubtitleSearchService(
      client: MockClient((request) async {
        expect(request.url.host, 'www.subhd.me');
        if (request.url.path.startsWith('/a/') ||
            request.url.path.startsWith('/down/')) {
          return http.Response('ok', 200);
        }
        expect(request.url.path, '/api/sub/down');
        expect(request.headers['origin'], 'https://www.subhd.me');
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.download(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: 'pQULiK',
          title: '鼠惑',
          fileName: '鼠惑.srt',
          language: '中文',
          downloadUri: Uri.https('www.subhd.me', '/search/鼠惑'),
          referrer: Uri.https('www.subhd.me', '/a/pQULiK'),
        ),
      ),
      throwsA(
        isA<SubtitleSourceException>().having(
          (error) => error.message,
          'message',
          contains('下载接口未找到该字幕记录'),
        ),
      ),
    );
  });

  test('reports an expired SubHD file link separately from the API', () async {
    final service = SubtitleSearchService(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'success': true,
              'url': 'https://cdn.subhd.me/expired.zip',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.startsWith('/a/') ||
            request.url.path.startsWith('/down/')) {
          return http.Response('ok', 200);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.download(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: 'pQULiK',
          title: '鼠惑',
          fileName: '鼠惑.srt',
          language: '中文',
          downloadUri: Uri.https('www.subhd.me', '/search/鼠惑'),
          referrer: Uri.https('www.subhd.me', '/a/pQULiK'),
        ),
      ),
      throwsA(
        isA<SubtitleSourceException>().having(
          (error) => error.message,
          'message',
          contains('字幕文件链接已失效或文件已被移除'),
        ),
      ),
    );
  });
}
