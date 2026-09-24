import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingji/src/metadata/tmdb_client.dart';
import 'package:yingji/src/tracking/trakt_auth.dart';
import 'package:yingji/src/tracking/trakt_client.dart';

void main() {
  test(
    'desktop callback rejects wrong state then exchanges authorization code',
    () async {
      late Map<String, dynamic> exchangeBody;
      final client = TraktClient(
        client: MockClient((request) async {
          expect(
            request.url,
            Uri.parse('${TmdbClient.managedEndpoint}/trakt/oauth/token'),
          );
          exchangeBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'access_token': 'access',
              'refresh_token': 'refresh',
              'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'expires_in': 604800,
            }),
            200,
          );
        }),
      );
      final flow = TraktDesktopAuthorization(client: client, port: 0);
      final browser = http.Client();
      try {
        final tokenFuture = flow.authorize(
          clientId: 'client-id',
          openUrl: (url) async {
            final authorize = Uri.parse(url);
            expect(authorize.host, 'auth.trakt.tv');
            expect(authorize.path, '/oauth/authorize');
            expect(authorize.queryParameters['response_type'], 'code');
            expect(authorize.queryParameters['client_id'], 'client-id');
            final redirectUri = Uri.parse(
              authorize.queryParameters['redirect_uri']!,
            );
            expect(redirectUri.host, '127.0.0.1');
            expect(redirectUri.port, greaterThan(0));
            expect(redirectUri.path, traktDesktopCallbackPath);
            final state = authorize.queryParameters['state']!;
            final rejected = await browser.get(
              redirectUri.replace(
                queryParameters: {'state': 'wrong', 'code': 'ignored'},
              ),
            );
            expect(rejected.statusCode, 400);
            final accepted = await browser.get(
              redirectUri.replace(
                queryParameters: {'state': state, 'code': 'one-time-code'},
              ),
            );
            expect(accepted.statusCode, 200);
            expect(accepted.body, contains('Trakt 已授权'));
            return true;
          },
        );
        final token = await tokenFuture;
        expect(token.accessToken, 'access');
        expect(token.refreshToken, 'refresh');
        expect(token.expiresAt, isNotNull);
        expect(exchangeBody['code'], 'one-time-code');
        expect(exchangeBody.containsKey('client_id'), isFalse);
        expect(exchangeBody.containsKey('client_secret'), isFalse);
        expect(exchangeBody['grant_type'], 'authorization_code');
        expect(exchangeBody['redirect_uri'], startsWith('http://127.0.0.1:'));
      } finally {
        browser.close();
        client.dispose();
      }
    },
  );

  test(
    'refresh exchanges the rotating refresh token with the same callback',
    () async {
      late Map<String, dynamic> body;
      final client = TraktClient(
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'access_token': 'next-access',
              'refresh_token': 'next-refresh',
              'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'expires_in': 604800,
            }),
            200,
          );
        }),
      );
      try {
        final token = await client.refreshAccessToken(
          refreshToken: 'old-refresh',
          redirectUri: traktDesktopRedirectUri(),
        );
        expect(token.accessToken, 'next-access');
        expect(token.refreshToken, 'next-refresh');
        expect(body['refresh_token'], 'old-refresh');
        expect(body['grant_type'], 'refresh_token');
        expect(body['redirect_uri'], traktDesktopRedirectUri().toString());
        expect(body.containsKey('client_secret'), isFalse);
      } finally {
        client.dispose();
      }
    },
  );
}
