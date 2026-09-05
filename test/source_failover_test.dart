import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  test(
    'server identity fails over and discovers published endpoints',
    () async {
      final client = EmbyClient(
        client: MockClient((request) async {
          if (request.url.host == 'offline.example') {
            throw http.ClientException('offline', request.url);
          }
          return http.Response(
            jsonEncode({
              'ServerName': 'Living room',
              'Id': 'server-1',
              'LocalAddress': 'http://192.168.1.8:8096',
              'WanAddress': 'https://media.example/emby/',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await client.serverIdentity(
        MediaSource(
          id: 'source-1',
          name: 'Old name',
          kind: SourceKind.emby,
          endpoint: Uri.parse('https://offline.example/'),
          alternateEndpoints: [Uri.parse('https://online.example/emby/')],
        ),
      );

      expect(result.name, 'Living room');
      expect(result.id, 'server-1');
      expect(result.endpoint, Uri.parse('https://online.example/emby/'));
      expect(
        result.discoveredEndpoints,
        contains(Uri.parse('http://192.168.1.8:8096/')),
      );
      expect(
        result.discoveredEndpoints,
        contains(Uri.parse('https://media.example/emby/')),
      );
      client.dispose();
    },
  );

  test('saved login selects the first authenticated server line', () async {
    final client = EmbyClient(
      client: MockClient((request) async {
        if (request.url.host == 'public-only.example') {
          return http.Response('unauthorized', 401);
        }
        expect(request.headers['X-Emby-Token'], 'token');
        return http.Response('{}', 200);
      }),
    );
    final session = await client.resolveSession(
      EmbySession(
        token: 'token',
        source: MediaSource(
          id: 'source-1',
          name: 'Server',
          kind: SourceKind.jellyfin,
          endpoint: Uri.parse('https://public-only.example/'),
          userId: 'user-1',
          alternateEndpoints: [Uri.parse('https://working.example/jellyfin/')],
        ),
      ),
    );

    expect(
      session.source.endpoint,
      Uri.parse('https://working.example/jellyfin/'),
    );
    expect(
      session.source.alternateEndpoints,
      contains(Uri.parse('https://public-only.example/')),
    );
    client.dispose();
  });

  test('server identity uses the saved login before public info', () async {
    final client = EmbyClient(
      client: MockClient((request) async {
        expect(request.url.path, '/System/Info');
        expect(request.headers['X-Emby-Token'], 'token');
        return http.Response(
          jsonEncode({'ServerName': 'Private server', 'Id': 'server-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final identity = await client.serverIdentity(
      MediaSource(
        id: 'source-1',
        name: 'Old name',
        kind: SourceKind.emby,
        endpoint: Uri.parse('https://online.example/'),
      ),
      token: 'token',
    );

    expect(identity.name, 'Private server');
    expect(identity.id, 'server-1');
    client.dispose();
  });
}
