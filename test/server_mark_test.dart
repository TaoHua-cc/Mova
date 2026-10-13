import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/sources/media_source.dart';
import 'package:yingji/src/sources/server_mark.dart';

void main() {
  testWidgets('server mark uses persistent lookup for saved icons', (
    tester,
  ) async {
    final source = MediaSource(
      id: 'server-1',
      name: 'Living room',
      kind: SourceKind.emby,
      endpoint: Uri.parse('https://media.example.com'),
      iconUrl: 'https://media.example.com/Branding/Splashscreen',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerMark(source: source, token: 'secret', size: 34),
        ),
      ),
    );

    expect(find.byType(FutureBuilder<String?>), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('remote icon lookup keeps a visible fallback while loading', (
    tester,
  ) async {
    final source = MediaSource(
      id: 'server-2',
      name: 'Cinema',
      kind: SourceKind.jellyfin,
      endpoint: Uri.parse('https://media.example.com'),
      iconUrl: 'https://icons.example.net/jellyfin.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerMark(source: source, token: 'secret', size: 34),
        ),
      ),
    );

    expect(find.byType(FutureBuilder<String?>), findsOneWidget);
    expect(find.byType(Icon), findsOneWidget);
  });
}
