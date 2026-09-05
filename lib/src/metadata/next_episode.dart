import 'package:flutter/material.dart';

import '../brand.dart';
import 'tmdb_client.dart';

class NextEpisodeLabel extends StatefulWidget {
  const NextEpisodeLabel({super.key, required this.item});
  final TmdbItem item;
  @override
  State<NextEpisodeLabel> createState() => _NextEpisodeLabelState();
}

class _NextEpisodeLabelState extends State<NextEpisodeLabel> {
  late Future<TmdbUpcomingEpisode?> _next;
  @override
  void initState() {
    super.initState();
    _next = TmdbClient().upcomingEpisode(widget.item);
  }

  @override
  void didUpdateWidget(covariant NextEpisodeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id)
      _next = TmdbClient().upcomingEpisode(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.kind != '剧集') return const SizedBox.shrink();
    return FutureBuilder<TmdbUpcomingEpisode?>(
      future: _next,
      builder: (context, snapshot) {
        final next = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done)
          return const Text(
            '正在更新播出安排…',
            style: TextStyle(color: YingjiColors.muted, fontSize: 12),
          );
        if (next == null)
          return Text(
            snapshot.hasError ? '播出安排暂时无法获取' : '下一集播出安排尚未公布',
            style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
          );
        final date = next.timeKnown ? next.airDate.toLocal() : next.airDate;
        final day = '${date.year}年${date.month}月${date.day}日';
        final time = next.timeKnown
            ? ' ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}（当地时间）'
            : '（时分未公布）';
        return Tooltip(
          message: '来源：${next.source}；这是播出安排，不代表服务器入库时间。',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(YingjiIcons.calendar, size: 16),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '下一集 · 第 ${next.seasonNumber} 季 第 ${next.episodeNumber} 集\n$day$time${next.network == null ? '' : ' · ${next.network}'}',
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
