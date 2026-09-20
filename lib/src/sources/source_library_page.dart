import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../brand.dart';
import '../metadata/metadata_detail_page.dart';
import '../metadata/tmdb_client.dart';
import '../network/proxy_routing.dart';
import 'emby_client.dart';
import 'media_source.dart';
import 'server_mark.dart';
import 'source_store.dart';

class EmbyLibraryPage extends StatefulWidget {
  const EmbyLibraryPage({super.key, required this.source});
  final MediaSource source;

  @override
  State<EmbyLibraryPage> createState() => _EmbyLibraryPageState();
}

class _EmbyLibraryPageState extends State<EmbyLibraryPage> {
  String? _parentId;
  String _title = '完整媒体库';
  String? _token;
  MediaSource? _resolvedSource;
  late Future<List<MediaItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = _load();
  }

  Future<List<MediaItem>> _load() async {
    final store = await SourceStore.create();
    final saved = store.load().where((row) => row.id == widget.source.id);
    var source = saved.isEmpty ? widget.source : saved.first;
    final token = store.tokenFor(source);
    if (token == null || token.isEmpty) throw Exception('未找到服务器登录令牌');
    _token = token;
    final client = EmbyClient(proxy: ProxyRouting.serverUsesProxy(source.id));
    try {
      final resolved = await client.resolveSession(
        EmbySession(source: source, token: token),
      );
      source = resolved.source;
      final identity = await client.serverIdentity(source, token: token);
      final endpoints = <Uri>{
        identity.endpoint,
        ...identity.discoveredEndpoints,
      };
      source = MediaSource(
        id: source.id,
        name: identity.name,
        kind: source.kind,
        endpoint: identity.endpoint,
        userId: source.userId,
        serverId: identity.id,
        alternateEndpoints: endpoints
            .where((value) => value != identity.endpoint)
            .toList(growable: false),
        iconUrl: source.iconUrl,
        customIcon: source.customIcon,
      );
      await store.upsert(source, token);
      _resolvedSource = source;
      return await client.browse(
        EmbySession(source: source, token: token),
        parentId: _parentId,
      );
    } finally {
      client.dispose();
    }
  }

  void _open(MediaItem item) {
    if (item.isContainer) {
      setState(() {
        _parentId = item.id;
        _title = item.title;
        _items = _load();
      });
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MetadataDetailPage(
          item: TmdbItem(
            id: int.tryParse(item.providerIds['Tmdb'] ?? '') ?? 0,
            title: item.title,
            kind: item.type == 'Series' ? '剧集' : '电影',
            overview: item.overview,
            year: item.year,
          ),
          media: item,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: YingjiColors.canvas,
    appBar: PreferredSize(
      preferredSize: const Size.fromHeight(76),
      child: YingjiPageChrome(
        onBack: () => Navigator.pop(context),
        title: _title,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() => _items = _load()),
            icon: const Icon(YingjiIcons.refresh),
          ),
        ],
      ),
    ),
    body: FutureBuilder<List<MediaItem>>(
      future: _items,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _SourceFailure(
                message: snapshot.error.toString().replaceFirst(
                  'Exception: ',
                  '',
                ),
                onRetry: () => setState(() => _items = _load()),
              ),
            ),
          );
        }
        final items = snapshot.data ?? const <MediaItem>[];
        if (items.isEmpty) return const Center(child: Text('此目录没有内容'));
        final folders = items
            .where(
              (item) =>
                  item.isContainer &&
                  item.type != 'Series' &&
                  item.type != 'Season',
            )
            .toList();
        final shows = items.where((item) => item.type == 'Series').toList();
        final seasons = items.where((item) => item.type == 'Season').toList();
        final movies = items
            .where((item) => !item.isContainer && item.type == 'Movie')
            .toList();
        final other = items
            .where(
              (item) =>
                  item.type != 'Series' &&
                  item.type != 'Movie' &&
                  item.type != 'Season' &&
                  !folders.contains(item),
            )
            .toList();
        final groups = <(String, String, List<MediaItem>)>[
          ('媒体库', '按服务器目录进入分类内容', folders),
          ('剧集', '${shows.length} 部剧集', shows),
          ('季', '${seasons.length} 季', seasons),
          ('电影', '${movies.length} 部电影', movies),
          ('其他内容', '${other.length} 项', other),
        ].where((group) => group.$3.isNotEmpty).toList();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(42, 18, 42, 10),
              sliver: SliverToBoxAdapter(
                child: GlassPanel(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      ServerMark(
                        source: _resolvedSource ?? widget.source,
                        token: _token,
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.source.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${widget.source.kindLabel} · ${groups.length} 个内容分组 · ${items.length} 项',
                              style: const TextStyle(
                                color: YingjiColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            for (final group in groups) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(42, 24, 42, 12),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          group.$1,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        group.$2,
                        style: const TextStyle(
                          color: YingjiColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(42, 0, 42, 26),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisExtent: 310,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 22,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, index) => _SourceMediaCard(
                      item: group.$3[index],
                      onOpen: () => _open(group.$3[index]),
                    ),
                    childCount: group.$3.length,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _SourceMediaCard extends StatelessWidget {
  const _SourceMediaCard({required this.item, this.onOpen});
  final MediaItem item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 164,
    child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap:
          onOpen ??
          (() => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MetadataDetailPage(
                item: TmdbItem(
                  id: 0,
                  title: item.title,
                  kind: '视频',
                  overview: item.overview,
                  year: item.year,
                ),
                media: item,
              ),
            ),
          )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 230,
            width: 164,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: YingjiColors.line),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 20,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: item.imageUrl == null
                    ? const ColoredBox(
                        color: YingjiColors.elevated,
                        child: Center(
                          child: Icon(
                            YingjiIcons.play_rectangle_fill,
                            color: YingjiColors.focus,
                            size: 34,
                          ),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: item.imageUrl.toString(),
                        fit: BoxFit.cover,
                        // 源缩略图卡片约 260px 宽，按显示分辨率解码。
                        memCacheWidth: (320 *
                                MediaQuery.devicePixelRatioOf(context))
                            .clamp(1.0, 512.0)
                            .round(),
                        errorWidget: (_, _, _) =>
                            const ColoredBox(color: YingjiColors.elevated),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(
            '${item.year ?? '—'} · ${item.type}',
            style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _SourceFailure extends StatelessWidget {
  const _SourceFailure({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: YingjiGlass.surface(),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        const Icon(
          YingjiIcons.exclamationmark_triangle,
          color: Color(0xFFFFA1A9),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}
