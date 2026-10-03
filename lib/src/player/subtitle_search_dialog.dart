import 'dart:async';

import 'package:flutter/material.dart';

import '../brand.dart';
import '../platform/window_host.dart';
import 'subtitle_search_service.dart';

class SubtitleSearchPanel extends StatefulWidget {
  const SubtitleSearchPanel({
    super.key,
    required this.query,
    required this.onApply,
    this.serviceFactory,
    this.completion,
  });

  final SubtitleSearchQuery query;
  final Future<void> Function(DownloadedSubtitle subtitle) onApply;
  final SubtitleSearchService Function()? serviceFactory;
  final Stream<bool>? completion;

  @override
  State<SubtitleSearchPanel> createState() => _SubtitleSearchPanelState();
}

class _SubtitleSearchPanelState extends State<SubtitleSearchPanel> {
  late final SubtitleSearchService _service;
  late String _language;
  SubtitleSearchResponse? _response;
  String? _error;
  String? _downloading;
  final Map<String, DownloadedSubtitle> _downloaded = {};
  final Map<String, SubtitleSearchResult> _savedResults = {};
  StreamSubscription<bool>? _completionSubscription;
  final Set<String> _applied = {};
  bool _searching = false;
  int _generation = 0;

  static const _languages = <String, String>{
    'zh': '中文',
    'en': '英语',
    'ja': '日语',
    'ko': '韩语',
    'fr': '法语',
    'de': '德语',
    'es': '西班牙语',
  };

  @override
  void initState() {
    super.initState();
    _service = widget.serviceFactory?.call() ?? SubtitleSearchService();
    _language = widget.query.language;
    _completionSubscription = widget.completion?.listen((completed) {
      if (!completed || !mounted) return;
      _generation++;
      setState(() {
        _savedResults.clear();
        _downloaded.clear();
        _applied.clear();
        _searching = false;
      });
    });
    _loadSavedAndSearch();
  }

  Future<void> _loadSavedAndSearch() async {
    final generation = _generation;
    try {
      final saved = await _service.savedDownloads(widget.query);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (final (result, file) in saved) {
          _savedResults[_resultKey(result)] = result;
          _downloaded[_resultKey(result)] = file;
        }
      });
    } catch (_) {
      /* Network search remains available when local storage fails. */
    }
    if (mounted && generation == _generation) await _search();
  }

  @override
  void dispose() {
    _generation++;
    _completionSubscription?.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final resultsBySource = <String, List<SubtitleSearchResult>>{};
    final status = <String, String>{'SubHD': '正在搜索'};
    setState(() {
      _response = SubtitleSearchResponse(results: const [], status: status);
      _error = null;
      _searching = true;
    });
    try {
      final response = await _service.search(
        SubtitleSearchQuery(
          title: widget.query.title,
          season: widget.query.season,
          episode: widget.query.episode,
          episodeTitle: widget.query.episodeTitle,
          language: _language,
        ),
        onSourceResults: (provider, found, message) {
          if (!mounted || generation != _generation) return;
          resultsBySource[provider] = found;
          status[provider] = message;
          final merged = <SubtitleSearchResult>[];
          final seen = <String>{};
          for (final sourceResults in resultsBySource.values) {
            for (final result in sourceResults) {
              if (seen.add(_resultKey(result))) merged.add(result);
            }
          }
          setState(() {
            _response = SubtitleSearchResponse(
              results: merged,
              status: Map<String, String>.of(status),
            );
          });
        },
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _response = response;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error.toString();
        _searching = false;
      });
    }
  }

  Future<void> _downloadOrApply(SubtitleSearchResult result) async {
    if (_downloading != null) return;
    final key = _resultKey(result);
    var downloadCompleted = _downloaded.containsKey(key);
    setState(() {
      _downloading = key;
      _error = null;
    });
    try {
      final downloaded =
          _downloaded[key] ??
          await _service.download(result, query: widget.query);
      if (!mounted) return;
      downloadCompleted = true;
      setState(() {
        _downloaded[key] = downloaded;
        _savedResults[key] = result;
      });
      await widget.onApply(downloaded);
      if (mounted) {
        setState(() {
          _applied.add(key);
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = downloadCompleted ? '字幕已下载，但应用失败：$error' : error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  String _resultKey(SubtitleSearchResult result) =>
      '${result.provider}:${result.providerId}';

  Future<void> _openProvider(String provider) async {
    final uri = provider == 'Gestdown'
        ? Uri.https('www.gestdown.info', '/')
        : Uri.https('www.subhd.me', '/search/${widget.query.searchText}');
    await WindowHost.openUrl(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final response = _response;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.query.episodeLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: YingjiColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(YingjiIcons.captions_bubble, size: 16),
            const SizedBox(width: 6),
            const Text('语言', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            DropdownButton<String>(
              value: _language,
              isDense: true,
              items: _languages.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _downloading != null || _searching
                  ? null
                  : (value) {
                      if (value == null || value == _language) return;
                      setState(() => _language = value);
                      _search();
                    },
            ),
            const Spacer(),
            IconButton(
              tooltip: _searching ? '正在搜索字幕' : '重新搜索',
              visualDensity: VisualDensity.compact,
              onPressed: _downloading == null && !_searching ? _search : null,
              icon: _searching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(YingjiIcons.refresh, size: 17),
            ),
          ],
        ),
        const Text(
          '选择字幕后会下载并立即应用，无需 Token。',
          style: TextStyle(color: YingjiColors.muted, fontSize: 11),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          _NoticeCard(
            icon: YingjiIcons.info_circle,
            text: _error!,
            danger: true,
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: response == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    if (_savedResults.isNotEmpty) ...[
                      const Text(
                        '已下载字幕',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      ..._savedResults.values.map(_resultTile),
                      const SizedBox(height: 8),
                    ],
                    ...response.status.entries.map(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _NoticeCard(
                          icon: entry.value.startsWith('找到')
                              ? YingjiIcons.checkmark_seal
                              : YingjiIcons.info_circle,
                          text: '${entry.key} · ${entry.value}',
                          onOpenSource: _needsRecoveryLink(entry.value)
                              ? () => _openProvider(entry.key)
                              : null,
                        ),
                      ),
                    ),
                    if (response.results.isEmpty && _searching)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: Text('来源正在搜索，结果会直接显示在这里…')),
                      )
                    else if (response.results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          children: [
                            const Icon(YingjiIcons.captions_bubble, size: 28),
                            const SizedBox(height: 8),
                            const Text('这次没有找到字幕'),
                            TextButton.icon(
                              onPressed: () => _openProvider('SubHD'),
                              icon: const Icon(YingjiIcons.link, size: 15),
                              label: const Text('打开 SubHD 检查'),
                            ),
                          ],
                        ),
                      )
                    else
                      ...response.results
                          .where(
                            (r) => !_savedResults.containsKey(_resultKey(r)),
                          )
                          .map(_resultTile),
                    if (_searching && response.results.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '其他字幕源仍在搜索…',
                          style: TextStyle(
                            color: YingjiColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _resultTile(SubtitleSearchResult result) {
    final key = _resultKey(result);
    final downloaded = _downloaded.containsKey(key);
    final applied = _applied.contains(key);
    final busy = _downloading == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: GlassPanel(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            const Icon(YingjiIcons.captions_bubble, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${result.matchLabel} · ${result.provider} · ${result.language} · ${result.fileName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: YingjiColors.muted,
                      fontSize: 10,
                    ),
                  ),
                  if (downloaded)
                    Text(
                      applied ? '✓ 已下载 · 已应用' : '✓ 已下载',
                      style: const TextStyle(
                        color: YingjiColors.success,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            YingjiGlassPillButton(
              icon: busy
                  ? YingjiIcons.refresh
                  : downloaded
                  ? YingjiIcons.checkmark_seal
                  : YingjiIcons.doc_on_clipboard,
              label: busy
                  ? (downloaded ? '应用中' : '下载中')
                  : downloaded
                  ? (applied ? '重新应用' : '应用字幕')
                  : '下载应用',
              tooltip: downloaded ? '应用已下载字幕' : '下载并应用这条字幕',
              onPressed: () => _downloadOrApply(result),
              busy: busy,
              height: 36,
            ),
          ],
        ),
      ),
    );
  }

  bool _needsRecoveryLink(String status) =>
      status.contains('验证') ||
      status.contains('限制') ||
      status.contains('刷新') ||
      status.contains('频繁');
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.text,
    this.danger = false,
    this.onOpenSource,
  });

  final IconData icon;
  final String text;
  final bool danger;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: 12,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    child: Row(
      children: [
        Icon(icon, size: 15, color: danger ? Colors.orangeAccent : null),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 11))),
        if (onOpenSource != null)
          IconButton(
            onPressed: onOpenSource,
            tooltip: '打开来源网页',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            icon: const Icon(YingjiIcons.link, size: 15),
          ),
      ],
    ),
  );
}
