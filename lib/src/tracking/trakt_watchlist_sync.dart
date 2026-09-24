import 'package:shared_preferences/shared_preferences.dart';

import '../history/watchlist_store.dart';
import '../metadata/tmdb_client.dart';
import 'trakt_client.dart';
import 'trakt_auth.dart';

/// Reconciles Mova and Trakt watchlists using the last successfully synced set.
/// First sync is additive; later removals on either side are mirrored.
class TraktWatchlistSync {
  const TraktWatchlistSync(this.client);

  static const _keyPrefix = 'yingji.trakt.watchlist-sync.v1.';
  // ponytail: one app-wide queue prevents competing snapshot writes; split by
  // account only if simultaneous account sessions are introduced.
  static Future<void> _pending = Future<void>.value();
  final TraktClient client;

  Future<void> synchronize({
    required WatchlistStore store,
    required String clientId,
    required String accessToken,
  }) {
    final task = _pending.then(
      (_) => _synchronize(
        store: store,
        clientId: clientId,
        accessToken: accessToken,
      ),
    );
    _pending = task.then<void>((_) {}, onError: (error, stack) {});
    return task;
  }

  Future<void> _synchronize({
    required WatchlistStore store,
    required String clientId,
    required String accessToken,
  }) async {
    if (clientId.trim().isEmpty || accessToken.trim().isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final uuid = await client.accountUuid(
      clientId: clientId,
      accessToken: accessToken,
    );
    final key = '$_keyPrefix$uuid';
    final remoteItems = await client.watchlist(
      clientId: clientId,
      accessToken: accessToken,
    );
    final local = store.load().where(_supported).toList(growable: false);
    final localByKey = {for (final item in local) _itemKey(item): item};
    final remoteByKey = {
      for (final item in remoteItems.where(_supported)) _itemKey(item): item,
    };
    final previous = (prefs.getStringList(key) ?? const <String>[]).toSet();
    final localKeys = localByKey.keys.toSet();
    final remoteKeys = remoteByKey.keys.toSet();

    final localAdded = localKeys.difference(previous);
    final remoteAdded = remoteKeys.difference(previous);
    final localRemoved = previous.difference(localKeys);
    final remoteRemoved = previous.difference(remoteKeys);

    // New additions win over a simultaneous removal from the other side.
    final toRemote = localAdded
        .difference(remoteKeys)
        .map((key) => localByKey[key]!)
        .toList(growable: false);
    final toLocal = remoteAdded
        .difference(localKeys)
        .map((key) => remoteByKey[key]!)
        .toList(growable: false);
    final removeRemote = localRemoved
        .intersection(remoteKeys)
        .map((key) => remoteByKey[key]!)
        .toList(growable: false);
    final removeLocalKeys = remoteRemoved
        .intersection(localKeys)
        .difference(localAdded);

    await client.addWatchlistItems(
      clientId: clientId,
      accessToken: accessToken,
      items: toRemote,
    );
    await client.removeWatchlistItems(
      clientId: clientId,
      accessToken: accessToken,
      items: removeRemote,
    );
    await store.reconcile(
      add: toLocal,
      removeIds: {for (final id in removeLocalKeys) localByKey[id]!.id},
    );

    final next = <String>{
      ...localKeys.difference(removeLocalKeys),
      ...remoteKeys.difference(localRemoved),
      ...remoteAdded,
      ...localAdded,
    };
    await prefs.setStringList(key, next.toList()..sort());
  }

  static bool _supported(TmdbItem item) =>
      item.id > 0 && (item.kind == '剧集' || item.kind == '电影');

  static String _itemKey(TmdbItem item) =>
      '${item.kind == '剧集' ? 'shows' : 'movies'}:${item.id}';
}

Future<void> synchronizeTraktWatchlist(
  WatchlistStore store, {
  TraktClient? client,
}) async {
  var credentials = await TraktCredentials.read();
  try {
    credentials = await credentials.refreshIfNeeded();
  } catch (_) {
    // Let the authorized watchlist request decide whether the old token works.
  }
  if (!credentials.isConnected) return;

  final trakt = client ?? TraktClient();
  try {
    await TraktWatchlistSync(trakt).synchronize(
      store: store,
      clientId: credentials.clientId,
      accessToken: credentials.accessToken,
    );
  } finally {
    if (client == null) trakt.dispose();
  }
}
