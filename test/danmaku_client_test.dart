import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:yingji/src/player/danmaku_client.dart';

void main() {
  test('expands placeholders and parses common response envelopes', () async {
    Uri? requested;
    final client = DanmakuClient(
      client: MockClient((request) async {
        requested = request.url;
        expect(request.headers['authorization'], 'Bearer secret');
        final body = jsonEncode({
          'data': [
            {'time': 12.5, 'content': '你好'},
            {'timestamp': 15000, 'text': '世界', 'color': '#ffcc00'},
          ],
        });
        return http.Response.bytes(utf8.encode(body), 200);
      }),
    );

    final comments = await client.fetch(
      template: 'https://example.com/api?tmdb={tmdbId}&title={title}',
      tmdbId: '550',
      title: '测试片',
      token: 'secret',
    );
    expect(requested?.queryParameters['tmdb'], '550');
    expect(requested?.queryParameters['title'], '测试片');
    expect(comments.map((item) => item.content), ['你好', '世界']);
    expect(comments[1].time, const Duration(seconds: 15));
    client.dispose();
  });

  test('translates TLS handshake failures to Chinese', () async {
    final client = DanmakuClient(
      client: MockClient((_) async {
        throw const HandshakeException(
          'Connection terminated during handshake',
        );
      }),
    );

    await expectLater(
      client.fetch(template: 'https://example.com/api?title={title}'),
      throwsA(predicate((error) => error.toString().contains('TLS 安全连接失败'))),
    );
    client.dispose();
  });

  test('explains when a configured address is a web page', () async {
    final client = DanmakuClient(
      client: MockClient(
        (_) async => http.Response(
          '<html></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      client.fetch(template: 'https://example.com/api/v2/test'),
      throwsA(predicate((error) => error.toString().contains('不是 JSON API'))),
    );
    client.dispose();
  });

  test('supports TaoHua match and DandanPlay comment responses', () async {
    var requestCount = 0;
    final client = DanmakuClient(
      client: MockClient((request) async {
        requestCount++;
        if (request.url.path.endsWith('/api/v2/match')) {
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {'fileName': '生万物 S01E02'});
          return http.Response(
            jsonEncode({
              'success': true,
              'matches': [
                {'episodeId': 'episode-2'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.method, 'GET');
        expect(request.url.path, '/87654321/api/v2/comment/episode-2');
        expect(request.url.queryParameters['format'], 'json');
        return http.Response(
          jsonEncode({
            'comments': [
              {'p': '12.5,1,16711680,user', 'm': '你好'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final comments = await client.fetch(
      template: 'https://example.com/87654321',
      title: '生万物',
      season: 1,
      episode: 2,
    );
    expect(requestCount, 2);
    expect(comments.single.content, '你好');
    expect(comments.single.time, const Duration(milliseconds: 12500));
    expect(comments.single.color, 16711680);
    client.dispose();
  });
}
