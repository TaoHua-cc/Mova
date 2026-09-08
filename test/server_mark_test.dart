import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yingji/src/sources/media_source.dart';
import 'package:yingji/src/sources/server_mark.dart';

void main() {
  testWidgets('server mark renders the saved server icon with auth', (
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

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as NetworkImage;
    expect(provider.url, source.iconUrl);
    expect(provider.headers, {'X-Emby-Token': 'secret'});
  });

  testWidgets('server mark does not leak auth to an icon pack host', (
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

    final provider =
        tester.widget<Image>(find.byType(Image)).image as NetworkImage;
    expect(provider.headers, isNull);
  });
}
