import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/player/subtitle_search_dialog.dart';
import 'package:yingji/src/player/subtitle_search_service.dart';

void main() {
  testWidgets('shows results inline and marks an applied download', (
    tester,
  ) async {
    final service = _DialogTestSubtitleSearchService();
    var appliedCount = 0;
    String? appliedPath;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              height: 520,
              child: SubtitleSearchPanel(
                query: const SubtitleSearchQuery(title: 'Demo'),
                serviceFactory: () => service,
                onApply: (subtitle) async {
                  appliedCount++;
                  appliedPath = subtitle.path;
                },
              ),
            ),
          ),
        ),
      ),
    );

    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Demo 字幕'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.text('下载应用'));
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.textContaining('已下载 · 已应用'), findsOneWidget);
    expect(appliedCount, 1);
    expect(appliedPath, 'memory://subtitle.srt');

    await tester.tap(find.text('重新应用'));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(appliedCount, 2);
  });
}

class _DialogTestSubtitleSearchService extends SubtitleSearchService {
  _DialogTestSubtitleSearchService()
    : super(
        client: MockClient((request) async {
          if (request.url.path == '/search/Demo') {
            return http.Response.bytes(
              utf8.encode('<li><a href="/a/pQULiK">Demo 字幕</a></li>'),
              200,
            );
          }
          return http.Response('', 404);
        }),
      );

  @override
  Future<SubtitleSearchResponse> search(
    SubtitleSearchQuery query, {
    void Function(
      String provider,
      List<SubtitleSearchResult> results,
      String status,
    )?
    onSourceResults,
  }) async {
    await Future<void>.delayed(Duration.zero);
    final result = SubtitleSearchResult(
      provider: 'SubHD',
      providerId: 'pQULiK',
      title: 'Demo 字幕',
      fileName: 'Demo.srt',
      language: '中文',
      downloadUri: Uri(
        scheme: 'https',
        host: 'www.subhd.me',
        path: '/search/Demo',
      ),
      referrer: Uri(scheme: 'https', host: 'www.subhd.me', path: '/a/pQULiK'),
    );
    final results = [result];
    onSourceResults?.call('SubHD', results, '找到 1 条');
    onSourceResults?.call('Gestdown', const [], '需要剧集季数和集数');
    return SubtitleSearchResponse(
      results: results,
      status: {'SubHD': '找到 1 条', 'Gestdown': '需要剧集季数和集数'},
    );
  }

  @override
  Future<DownloadedSubtitle> download(SubtitleSearchResult result) async =>
      const DownloadedSubtitle(
        path: 'memory://subtitle.srt',
        fileName: 'Demo.srt',
        language: '中文',
      );
}
