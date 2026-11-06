import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_widgets.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/format.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.controller,
  });

  final DownloadController controller;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadController get downloadController => widget.controller;

  // Keep expansion state across controller snapshot replacements.
  final Map<String, bool> _expanded = {};

  @override
  void initState() {
    super.initState();
    downloadController.refreshRecords();
  }

  bool _isExpanded(String recordKey, DownloadRecord record) {
    return _expanded.putIfAbsent(
      recordKey,
      () => record.episodes.values
          .any((e) => e.status != DownloadStatus.completed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('下载管理'),
        actions: [
          PopupMenuButton<bool>(
            tooltip: '导入本地视频',
            icon: const Icon(Icons.video_file_rounded),
            onSelected: (folder) => _importLocalVideo(folder: folder),
            itemBuilder: (context) => const [
              PopupMenuItem(value: false, child: Text('导入文件')),
              PopupMenuItem(value: true, child: Text('导入文件夹')),
            ],
          ),
        ],
      ),
      body: Observer(builder: (context) {
        final recordKeys = downloadController.recordKeys.toList();
        _expanded.removeWhere((key, _) => !recordKeys.contains(key));
        if (recordKeys.isEmpty) {
          return const GeneralEmptyState(
            icon: Icons.download_rounded,
            title: '还没有下载记录',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: recordKeys.length,
          itemBuilder: (context, index) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: _buildRecordCard(recordKeys[index]),
              ),
            );
          },
        );
      }),
    );
  }

  static const _videoExtensions = {
    'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm4v', 'wmv', //
  };

  /// Zero-pads digit runs so "ep2" sorts before "ep10".
  static String _naturalKey(String path) => path.replaceAllMapped(
        RegExp(r'\d+'),
        (m) => m[0]!.padLeft(8, '0'),
      );

  Future<void> _importLocalVideo({required bool folder}) async {
    final String defaultTitle;
    final List<String> sources;
    if (folder) {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || !mounted) return;
      defaultTitle = dir.split(RegExp(r'[\\/]')).last;
      sources = Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where(
              (p) => _videoExtensions.contains(p.split('.').last.toLowerCase()))
          .toList();
    } else {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );
      sources = [...?picked?.files.map((f) => f.path).whereType<String>()];
      if (sources.isEmpty || !mounted) return;
      defaultTitle =
          sources.first.split(RegExp(r'[\\/]')).last.split('.').first;
    }
    if (sources.isEmpty) {
      KazumiDialog.showToast(message: '没有找到视频文件');
      return;
    }
    sources.sort((a, b) => _naturalKey(a).compareTo(_naturalKey(b)));
    final titleController = TextEditingController(text: defaultTitle);
    final episodeController = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导入本地视频 (${sources.length} 个文件)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: '番剧名称'),
            ),
            TextField(
              controller: episodeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '起始集数 (按文件名排序依次递增)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final title = titleController.text.trim();
    final episode = int.tryParse(episodeController.text.trim());
    if (ok != true || title.isEmpty || episode == null) return;
    var done = 0;
    try {
      for (final source in sources) {
        await downloadController.importLocalVideo(
          sourcePath: source,
          title: title,
          episodeNumber: episode + done,
        );
        done++;
      }
      KazumiDialog.showToast(message: '导入完成 ($done)');
    } catch (e) {
      KazumiDialog.showToast(message: '已导入 $done 个, 失败: $e');
    }
  }

  Widget _buildRecordCard(String recordKey) {
    return Observer(builder: (context) {
      final record = downloadController.getRecordSnapshot(recordKey);
      if (record == null) {
        return const SizedBox.shrink();
      }

      var totalSpeed = 0.0;
      for (final e in record.episodes.values) {
        if (e.status == DownloadStatus.downloading) {
          totalSpeed += downloadController.getSpeed(
            record.bangumiId,
            record.pluginName,
            e.episodeNumber,
          );
        }
      }
      final expanded = _isExpanded(recordKey, record);

      return DownloadRecordCard(
        record: record,
        expanded: expanded,
        onToggle: () {
          setState(() => _expanded[recordKey] = !expanded);
        },
        onResumeAll: () {
          downloadController.resumeAllDownloads(
            record.bangumiId,
            record.pluginName,
          );
          KazumiDialog.showToast(message: '已开始恢复下载');
        },
        onDeleteAll: () => _confirmDeleteRecord(record),
        totalSpeed: totalSpeed,
        episodeTileBuilder: () {
          final episodes = record.episodes.values.toList()
            ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
          return episodes.map((ep) => _buildEpisodeTile(record, ep)).toList();
        },
      );
    });
  }

  Widget _buildEpisodeTile(DownloadRecord record, DownloadEpisode episode) {
    return DownloadEpisodeTile(
      episode: episode,
      statusText: _getStatusText(record, episode),
      actions: _getActionButtons(record, episode),
      onPlay: episode.status == DownloadStatus.completed
          ? () => _playEpisode(record, episode)
          : null,
    );
  }

  String _getStatusText(DownloadRecord record, DownloadEpisode episode) {
    switch (episode.status) {
      case DownloadStatus.completed:
        return '已完成 · ${formatBytes(episode.totalBytes)}';
      case DownloadStatus.downloading:
        final speed = downloadController.getSpeed(
          record.bangumiId,
          record.pluginName,
          episode.episodeNumber,
        );
        final speedText = speed > 0 ? ' · ${formatSpeed(speed)}' : '';
        return '${(episode.progressPercent * 100).toStringAsFixed(0)}% · '
            '${episode.downloadedSegments}/${episode.totalSegments} 分片$speedText';
      case DownloadStatus.failed:
        return episode.errorMessage.isNotEmpty ? episode.errorMessage : '下载失败';
      case DownloadStatus.paused:
        return '已暂停 · ${(episode.progressPercent * 100).toStringAsFixed(0)}%';
      case DownloadStatus.pending:
        return '排队中';
      case DownloadStatus.resolving:
        return '正在解析视频源';
      default:
        return '';
    }
  }

  List<Widget> _getActionButtons(
      DownloadRecord record, DownloadEpisode episode) {
    final colorScheme = Theme.of(context).colorScheme;
    final buttons = <Widget>[];

    switch (episode.status) {
      case DownloadStatus.completed:
        buttons.add(IconButton(
          icon: Icon(Icons.play_circle_outline,
              size: 20, color: colorScheme.primary),
          onPressed: () => _playEpisode(record, episode),
          tooltip: '播放',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.downloading:
        buttons.add(IconButton(
          icon: const Icon(Icons.pause_rounded, size: 20),
          onPressed: () => downloadController.pauseDownload(
            record.bangumiId,
            record.pluginName,
            episode.episodeNumber,
          ),
          tooltip: '暂停',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.paused:
        buttons.add(IconButton(
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          onPressed: () => downloadController.retryDownload(
            bangumiId: record.bangumiId,
            pluginName: record.pluginName,
            episodeNumber: episode.episodeNumber,
          ),
          tooltip: '继续',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.failed:
        buttons.add(IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          onPressed: () => downloadController.retryDownload(
            bangumiId: record.bangumiId,
            pluginName: record.pluginName,
            episodeNumber: episode.episodeNumber,
          ),
          tooltip: '重试',
          visualDensity: VisualDensity.compact,
        ));
        break;
      case DownloadStatus.pending:
        buttons.add(IconButton(
          icon: Icon(Icons.priority_high, size: 20, color: colorScheme.primary),
          onPressed: () {
            downloadController.priorityDownload(
              bangumiId: record.bangumiId,
              pluginName: record.pluginName,
              episodeNumber: episode.episodeNumber,
            );
            KazumiDialog.showToast(message: '已插队优先下载');
          },
          tooltip: '优先下载',
          visualDensity: VisualDensity.compact,
        ));
        break;
      default:
        break;
    }

    buttons.add(IconButton(
      icon: Icon(Icons.delete_outline,
          size: 20, color: colorScheme.onSurfaceVariant),
      onPressed: () => _confirmDeleteEpisode(record, episode),
      tooltip: '删除',
      visualDensity: VisualDensity.compact,
    ));

    return buttons;
  }

  void _playEpisode(DownloadRecord record, DownloadEpisode episode) {
    final localPath = downloadController.getLocalVideoPath(
      record.bangumiId,
      record.pluginName,
      episode.episodeNumber,
    );
    if (localPath == null) {
      KazumiDialog.showToast(message: '本地文件不存在');
      return;
    }

    final bangumiItem = BangumiItem(
      id: record.bangumiId,
      type: 2,
      name: record.bangumiName,
      nameCn: record.bangumiName,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {'large': record.bangumiCover},
      tags: [],
      alias: [],
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );

    final downloadedEpisodes = downloadController.getCompletedEpisodes(
      record.bangumiId,
      record.pluginName,
    );

    context.pushNamed(
      '/video/',
      arguments: OfflineVideoPlaybackArgs(
        bangumiItem: bangumiItem,
        pluginName: record.pluginName,
        episodeNumber: episode.episodeNumber,
        road: episode.road,
        downloadedEpisodes: downloadedEpisodes,
      ),
    );
  }

  void _confirmDeleteEpisode(DownloadRecord record, DownloadEpisode episode) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text(
            '确定要删除「${episode.episodeName.isNotEmpty ? episode.episodeName : '第${episode.episodeNumber}集'}」的下载文件吗？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              KazumiDialog.dismiss();
              await _deleteDownload(
                () => downloadController.deleteEpisode(
                  record.bangumiId,
                  record.pluginName,
                  episode.episodeNumber,
                ),
              );
            },
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteRecord(DownloadRecord record) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除全部下载'),
        content: Text('确定要删除「${record.bangumiName}」的所有下载文件吗？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              KazumiDialog.dismiss();
              await _deleteDownload(
                () => downloadController.deleteRecord(
                  record.bangumiId,
                  record.pluginName,
                ),
              );
            },
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteDownload(Future<void> Function() delete) async {
    try {
      await delete();
    } catch (e) {
      KazumiLogger().w('DownloadPage: failed to delete download', error: e);
      if (!mounted) return;
      KazumiDialog.show(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除失败'),
          content: const Text('删除下载文件失败，请稍后重试'),
          actions: [
            TextButton(
              onPressed: () => KazumiDialog.dismiss(context: context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }
}
