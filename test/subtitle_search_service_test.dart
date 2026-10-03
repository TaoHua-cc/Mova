import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/player/subtitle_search_service.dart';

void main() {
  test('classifies current episode, packs, mismatches and unknown titles', () {
    const query = SubtitleSearchQuery(title: 'Demo', season: 1, episode: 2);
    expect(SubtitleSearchService.episodeMatchRank('Demo S01E02', query), 0);
    expect(SubtitleSearchService.episodeMatchRank('Demo S02E02', query), 3);
    expect(SubtitleSearchService.episodeMatchRank('Demo S01E03', query), 3);
    expect(SubtitleSearchService.episodeMatchRank('Demo 第1季 第2集', query), 0);
    expect(
      SubtitleSearchService.episodeMatchRank('Demo S01 Complete', query),
      1,
    );
    expect(SubtitleSearchService.episodeMatchRank('Demo S01E01-E10', query), 1);
    expect(SubtitleSearchService.episodeMatchRank('Demo', query), 2);
  });
  test('prefers release filename over duplicate generic series link', () {
    final results = SubtitleSearchService.parseSubHdSearchPage(
      "<a href='/a/demo'>Demo</a><a href='/a/demo'>Demo S01E02 WEB-DL</a>",
      baseUri: Uri.https('www.subhd.me', '/search/Demo'),
    );
    expect(results.single.title, 'Demo S01E02 WEB-DL');
  });
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

  test(
    'SubHD searches current season and episode without episode title',
    () async {
      final paths = <String>[];
      final service = SubtitleSearchService(
        client: MockClient((request) async {
          if (request.url.path == '/api/sub/prepare-download') {
            final sid = jsonDecode(request.body)['sid'];
            return http.Response(
              jsonEncode({'success': true, 'url': '/down/$sid'}),
              200,
            );
          }
          expect(request.url.host, 'www.subhd.me');
          paths.add(request.url.path);
          return http.Response("<a href='/a/abc123'>Demo S01E02</a>", 200);
        }),
      );
      addTearDown(service.dispose);
      final response = await service.search(
        const SubtitleSearchQuery(
          title: 'Demo',
          season: 1,
          episode: 2,
          episodeTitle: 'Different episode name',
        ),
      );
      expect(paths, ['/search/Demo%20S01E02']);
      expect(response.results.single.providerId, 'abc123');
      expect(response.status.keys, ['SubHD']);
    },
  );

  test('empty SubHD search does not follow sidebar recommendations', () async {
    final service = SubtitleSearchService(
      client: MockClient((request) async {
        expect(request.url.path, '/search/Demo');
        return http.Response('<h4>共 0 条</h4><a href="/d/123">热门电影</a>', 200);
      }),
    );
    addTearDown(service.dispose);
    final response = await service.search(
      const SubtitleSearchQuery(title: 'Demo'),
    );
    expect(response.results, isEmpty);
  });

  test('falls back to title, labels packs and hides other episodes', () async {
    final paths = <String>[];
    final service = SubtitleSearchService(
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          request.url.path == '/search/Demo'
              ? "<a href='/a/other'>Demo S01E03</a><a href='/a/pack'>Demo S01 Complete</a><a href='/a/unknown'>Demo</a><a href='/a/current'>Demo S01E02</a>"
              : '<h4>No results</h4>',
          200,
        );
      }),
    );
    addTearDown(service.dispose);
    final response = await service.search(
      const SubtitleSearchQuery(title: 'Demo', season: 1, episode: 2),
    );
    expect(paths, ['/search/Demo%20S01E02', '/search/Demo']);
    expect(response.results.map((r) => r.providerId), [
      'current',
      'pack',
      'unknown',
    ]);
    expect(response.results.map((r) => r.matchLabel), [
      '本集 · 文件名匹配',
      '整季包 · 下载时核对本集',
      '集数未确认',
    ]);
  });

  test('downloads a zip and selects an applicable subtitle into temp storage', () async {
    final temp = await Directory.systemTemp.createTemp('mova-subtitle-test-');
    addTearDown(() => temp.delete(recursive: true));
    final archive = Archive()
      ..addFile(ArchiveFile('Demo.S01E01.chs.ass', 5, utf8.encode('wrong')))
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
        if (request.url.path == '/api/sub/prepare-download') {
          final sid = jsonDecode(request.body)['sid'];
          return http.Response(
            jsonEncode({'success': true, 'url': '/down/$sid'}),
            200,
          );
        }
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
      query: const SubtitleSearchQuery(title: 'Demo', season: 1, episode: 2),
    );

    expect(downloaded.fileName, 'Demo.S01E02.en.srt');
    expect(downloaded.persistent, isTrue);
    final reopened = SubtitleSearchService(temporaryDirectory: temp);
    addTearDown(reopened.dispose);
    const savedQuery = SubtitleSearchQuery(
      title: 'Demo',
      season: 1,
      episode: 2,
    );
    final saved = await reopened.savedDownloads(savedQuery);
    expect(saved.single.$2.path, downloaded.path);
    await File(
      '${File(downloaded.path).parent.path}${Platform.pathSeparator}broken.json',
    ).writeAsString('{broken');
    expect(await reopened.savedDownloads(savedQuery), hasLength(1));
    expect(
      await reopened.savedDownloads(
        const SubtitleSearchQuery(title: 'Demo', season: 1, episode: 3),
      ),
      isEmpty,
    );
    await expectLater(
      service.download(
        SubtitleSearchResult(
          provider: 'SubHD',
          providerId: 'pQULiK',
          title: 'Demo',
          fileName: 'subtitle.zip',
          language: 'English',
          downloadUri: Uri.https('www.subhd.me', '/search/Demo'),
          referrer: Uri.https('www.subhd.me', '/a/pQULiK'),
        ),
        query: const SubtitleSearchQuery(title: 'Demo', season: 1, episode: 9),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(File(downloaded.path).existsSync(), isTrue);
    expect(
      await File(downloaded.path).readAsString(),
      contains('00:00:01,000 --> 00:00:02,000'),
    );
    await SubtitleSearchService.clearDownloads(savedQuery, root: temp);
    expect(await reopened.savedDownloads(savedQuery), isEmpty);
    expect(await File(downloaded.path).exists(), isFalse);
    final pending = service.download(saved.single.$1, query: savedQuery);
    final expectation = expectLater(pending, throwsA(isA<FormatException>()));
    await SubtitleSearchService.clearDownloads(savedQuery, root: temp);
    await expectation;
    expect(await reopened.savedDownloads(savedQuery), isEmpty);
  });

  test('rejects a web challenge returned as a subtitle download', () async {
    final temp = await Directory.systemTemp.createTemp('mova-subtitle-test-');
    addTearDown(() => temp.delete(recursive: true));
    final service = SubtitleSearchService(
      temporaryDirectory: temp,
      client: MockClient((request) async {
        if (request.url.path == '/api/sub/prepare-download') {
          final sid = jsonDecode(request.body)['sid'];
          return http.Response(
            jsonEncode({'success': true, 'url': '/down/$sid'}),
            200,
          );
        }
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
        if (request.url.path == '/api/sub/prepare-download') {
          final sid = jsonDecode(request.body)['sid'];
          return http.Response(
            jsonEncode({'success': true, 'url': '/down/$sid'}),
            200,
          );
        }
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
        if (request.url.path == '/api/sub/prepare-download') {
          final sid = jsonDecode(request.body)['sid'];
          return http.Response(
            jsonEncode({'success': true, 'url': '/down/$sid'}),
            200,
          );
        }
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
