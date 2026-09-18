import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../brand.dart';
import '../metadata/metadata_detail_page.dart';
import '../metadata/tmdb_client.dart';
import '../metadata/ratings.dart';
import 'playlist_store.dart';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  YingjiPlaylist? _playlist;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await PlaylistStore.create();
    final current = store
        .load()
        .where((playlist) => playlist.id == widget.playlistId)
        .firstOrNull;
    if (mounted) setState(() => _playlist = current);
  }

  Future<void> _saveItems(List<TmdbItem> items) async {
    final playlist = _playlist;
    if (playlist == null) return;
    final store = await PlaylistStore.create();
    await store.save(playlist.copyWith(items: items));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    return Scaffold(
      backgroundColor: YingjiColors.canvas,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const YingjiBackdrop(),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xF507090D),
                  Color(0xB007090D),
                  Color(0xE807090D),
                ],
              ),
            ),
          ),
          SafeArea(
            child: playlist == null
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.only(top: 76),
                    child: playlist.items.isEmpty
                        ? _EmptyPlaylist(name: playlist.name)
                        : ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.fromLTRB(54, 24, 54, 52),
                            header: _PlaylistHeader(playlist: playlist),
                            itemCount: playlist.items.length,
                            onReorderItem: (oldIndex, newIndex) async {
                              final rows = [...playlist.items];
                              final item = rows.removeAt(oldIndex);
                              rows.insert(newIndex, item);
                              await _saveItems(rows);
                            },
                            itemBuilder: (context, index) {
                              final item = playlist.items[index];
                              return Padding(
                                key: ValueKey('${item.id}-$index'),
                                padding: const EdgeInsets.only(bottom: 10),
                                child: GlassPanel(
                                  radius: 18,
                                  padding: EdgeInsets.zero,
                                  child: InkWell(
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            MetadataDetailPage(item: item),
                                      ),
                                    ),
                                    child: SizedBox(
                                      height: 92,
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 16),
                                          ReorderableDragStartListener(
                                            index: index,
                                            child: const Tooltip(
                                              message: '拖动排序',
                                              child: Padding(
                                                padding: EdgeInsets.all(10),
                                                child: Icon(
                                                  YingjiIcons.line_horizontal_3,
                                                  color: YingjiColors.quiet,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: SizedBox(
                                              width: 52,
                                              height: 70,
                                              child: item.posterUrl == null
                                                  ? const _PosterFallback()
                                                  : CachedNetworkImage(
                                                      imageUrl: item.posterUrl
                                                          .toString(),
                                                      fit: BoxFit.cover,
                                                      // 列表缩略图仅 52px 宽，按显示分辨率解码。
                                                      memCacheWidth: (160 *
                                                              MediaQuery
                                                                  .devicePixelRatioOf(
                                                                context,
                                                              ))
                                                          .clamp(1.0, 256.0)
                                                          .round(),
                                                      errorWidget: (_, _, _) =>
                                                          const _PosterFallback(),
                                                    ),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 5),
                                                MediaRatingRow(item: item),
                                                Text(
                                                  '${item.year ?? '年份未知'} · ${item.kind}',
                                                  style: const TextStyle(
                                                    color: YingjiColors.muted,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: '从片单移除',
                                            icon: const Icon(
                                              YingjiIcons.trash,
                                              color: YingjiColors.danger,
                                            ),
                                            onPressed: () async {
                                              final rows = [...playlist.items]
                                                ..removeAt(index);
                                              await _saveItems(rows);
                                            },
                                          ),
                                          const SizedBox(width: 12),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: YingjiPageChrome(
                onBack: () => Navigator.pop(context),
                title: playlist?.name ?? '片单',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({required this.playlist});
  final YingjiPlaylist playlist;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          playlist.name,
          style: const TextStyle(
            fontSize: 48,
            height: 1,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${playlist.items.length} 部内容 · 拖动左侧图标可调整顺序',
          style: const TextStyle(color: YingjiColors.muted),
        ),
      ],
    ),
  );
}

class _EmptyPlaylist extends StatelessWidget {
  const _EmptyPlaylist({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(54, 42, 54, 54),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 28),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: const GlassPanel(
            padding: EdgeInsets.all(28),
            child: Row(
              children: [
                Icon(YingjiIcons.rectangle_stack_badge_plus, size: 30),
                SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '这个片单还是空的',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '在影片详情页选择“加入片单”，内容就会出现在这里。',
                        style: TextStyle(
                          color: YingjiColors.muted,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: YingjiColors.elevated,
    child: Icon(YingjiIcons.film, color: YingjiColors.quiet),
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
