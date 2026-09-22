import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/sources/emby_client.dart';
import 'package:yingji/src/sources/media_source.dart';

void main() {
  test('continue watching uses the dedicated server resume endpoint', () async {
    Uri? requested;
    final client = EmbyClient(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'episode-1',
                'Name': '第一集',
                'Type': 'Episode',
                'RunTimeTicks': 6000000000,
                'UserData': {'PlaybackPositionTicks': 1200000000},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final session = EmbySession(
      token: 'token',
      source: MediaSource(
        id: 'source-1',
        name: 'Server',
        kind: SourceKind.emby,
        endpoint: Uri.parse('https://media.example/'),
        userId: 'user-1',
      ),
    );

    final items = await client.resumeItems(session);

    expect(requested?.path, '/Users/user-1/Items/Resume');
    expect(items.single.id, 'episode-1');
    expect(items.single.playbackPosition, const Duration(minutes: 2));
    client.dispose();
  });

  test('continue watching falls back for older servers', () async {
    final paths = <String>[];
    final client = EmbyClient(
      client: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/Resume')) {
          return http.Response('not found', 404);
        }
        return http.Response(jsonEncode({'Items': <Object>[]}), 200);
      }),
    );
    final session = EmbySession(
      token: 'token',
      source: MediaSource(
        id: 'source-1',
        name: 'Server',
        kind: SourceKind.jellyfin,
        endpoint: Uri.parse('https://media.example/'),
        userId: 'user-1',
      ),
    );

    expect(await client.resumeItems(session), isEmpty);
    expect(paths, ['/Users/user-1/Items/Resume', '/Users/user-1/Items']);
    client.dispose();
  });

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
        token: 'token',
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

  test(
    'server discovery rejects unreachable and foreign published lines',
    () async {
      final client = EmbyClient(
        client: MockClient((request) async {
          if (request.url.host == 'origin.example') {
            return http.Response(
              jsonEncode({
                'ServerName': 'Home',
                'Id': 'server-1',
                'LocalAddress': 'http://192.168.1.8:8096',
                'WanAddress': 'https://foreign.example/',
              }),
              200,
            );
          }
          if (request.url.host == 'foreign.example') {
            return http.Response(jsonEncode({'Id': 'server-2'}), 200);
          }
          if (request.url.host == 'valid.example') {
            return http.Response(jsonEncode({'Id': 'server-1'}), 200);
          }
          throw http.ClientException('unreachable', request.url);
        }),
      );

      final result = await client.serverIdentity(
        MediaSource(
          id: 'source-1',
          name: 'Home',
          kind: SourceKind.jellyfin,
          endpoint: Uri.parse('https://origin.example/'),
          alternateEndpoints: [
            Uri.parse('https://valid.example/'),
            Uri.parse('https://stale.example/'),
          ],
        ),
        token: 'token',
      );

      expect(result.discoveredEndpoints, [Uri.parse('https://valid.example/')]);
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

  test(
    'legacy icon records remain eligible for automatic server discovery',
    () {
      final legacy = MediaSource.fromJson({
        'id': 'source-1',
        'name': 'Server',
        'kind': 'emby',
        'endpoint': 'https://media.example/',
        'iconUrl': 'https://icons.example/unrelated.png',
      });
      final selected = MediaSource(
        id: legacy.id,
        name: legacy.name,
        kind: legacy.kind,
        endpoint: legacy.endpoint,
        iconUrl: 'https://icons.example/chosen.png',
        customIcon: true,
      );

      expect(legacy.customIcon, isFalse);
      expect(MediaSource.fromJson(selected.toJson()).customIcon, isTrue);
    },
  );
}
