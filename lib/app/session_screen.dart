import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/models.dart';
import '../state/providers.dart';
import 'icons.dart';
import 'plans_sheet.dart';
import 'theme.dart';

/// Chat-style transfer thread with one device — the heart of variant D:
/// files flow in bubbles, incoming offers take 接受/拒绝 inline, progress is
/// shown on the bubble while bytes move.
class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.peer, this.embedded = false});

  final Peer peer;

  /// True when hosted in the wide master-detail layout (no back button,
  /// no own Scaffold).
  final bool embedded;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  final _draft = <TransferFile>[];
  bool _picking = false;

  Peer get _peer {
    // Follow live updates (online status, alias changes).
    final map = ref.read(peersProvider).value ?? const {};
    return map[widget.peer.fingerprint] ?? widget.peer;
  }

  Future<void> _pickFiles() async {
    if (_picking) return;
    _picking = true;
    try {
      final files = await FilePicker.pickFiles();
      final picked = <TransferFile>[];
      for (final f in files) {
        var path = f.path;
        if (path == null) {
          // Platform returned no local file — materialize it into the
          // cache dir so the uploader can stream it.
          final bytes = await f.readAsBytes();
          final tmp = await getTemporaryDirectory();
          path =
              '${tmp.path}/amy-pick-${DateTime.now().microsecondsSinceEpoch}-${f.name}';
          await File(path).writeAsBytes(bytes, flush: true);
        }
        final size =
            f.lengthSync() ?? await f.length() ?? await File(path).length();
        picked.add(
          TransferFile(id: randomId(4), name: f.name, size: size, path: path),
        );
      }
      setState(() => _draft.addAll(picked));
    } finally {
      _picking = false;
    }
  }

  void _sendDraft() {
    if (_draft.isEmpty) return;
    ref
        .read(engineProvider)
        .sendFiles(_peer, List.of(_draft));
    setState(_draft.clear);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(engineProvider); // rebuild on any transfer update
    final peer = _peer;
    final thread = ref.read(engineProvider).threadFor(peer.fingerprint);

    final body = Column(
      children: [
        _header(peer),
        const Divider(height: 1),
        Expanded(
          child: thread.isEmpty
              ? Center(
                  child: Text(
                    '还没有传过文件\n用下面的回形针发第一条',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: thread.length,
                  itemBuilder: (ctx, i) => _Bubble(
                    msg: thread[i],
                    onAnswer: (accept) => ref
                        .read(engineProvider)
                        .answerOffer(thread[i].id, accept),
                    onCancel: () =>
                        ref.read(engineProvider).cancelMessage(thread[i]),
                  ),
                ),
        ),
        _composer(peer),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(body: SafeArea(child: body));
  }

  Widget _header(Peer peer) {
    return Container(
      color: AmyTheme.bubblePeer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          if (!widget.embedded)
            const BackButton(),
          CircleAvatar(
            backgroundColor: AmyTheme.accent.withValues(alpha: 0.12),
            child: Icon(iconForPlatform(peer.platform),
                size: 20, color: AmyTheme.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(peer.alias,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  peer.online ? '在附近 · 局域网' : '不在附近',
                  style: TextStyle(
                    fontSize: 12,
                    color: peer.online ? AmyTheme.online : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(Peer peer) {
    final online = peer.online;
    return Container(
      color: AmyTheme.bubblePeer,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_draft.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in _draft)
                    InputChip(
                      avatar: Icon(iconForFileKind(f.kind), size: 16),
                      label:
                          Text(f.name, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setState(() => _draft.remove(f)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file, color: AmyTheme.accent),
                onPressed: online ? _pickFiles : null,
                tooltip: '添加文件',
              ),
              Expanded(
                child: Text(
                  !online
                      ? '设备不在附近，恢复后可发送'
                      : _draft.isEmpty
                          ? '点回形针选择要发送的文件'
                          : '待发 ${_draft.length} 个文件',
                  style:
                      const TextStyle(color: Colors.black38, fontSize: 13),
                ),
              ),
              if (_draft.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.schedule_send,
                      size: 20, color: AmyTheme.accent),
                  tooltip: '计划发送',
                  onPressed: () => showNewPlanSheet(
                    context,
                    peer: peer,
                    preselectedPaths:
                        _draft.map((f) => f.path!).toList(),
                    onCreated: () => setState(_draft.clear),
                  ),
                ),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: AmyTheme.accent,
                  disabledBackgroundColor: Colors.black12,
                ),
                icon: const Icon(Icons.send, size: 18, color: Colors.white),
                onPressed:
                    _draft.isEmpty || !online ? null : _sendDraft,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.msg,
    required this.onAnswer,
    required this.onCancel,
  });

  final TransferMessage msg;
  final void Function(bool accept) onAnswer;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final active = msg.status == MessageStatus.active;
    return Align(
      alignment: msg.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: msg.outgoing ? AmyTheme.bubbleMe : AmyTheme.bubblePeer,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in msg.files) _fileRow(context, f, active),
            const SizedBox(height: 6),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _fileRow(BuildContext context, TransferFile f, bool active) {
    final done = f.status == FileStatus.done && !msg.outgoing;
    return InkWell(
      onTap: done ? () => _openFile(context, f) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconForFileKind(f.kind), size: 18, color: AmyTheme.accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${f.name}  ·  ${fmtBytes(f.size)}',
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (active && f.progress > 0 && f.progress < 1) ...[
              const SizedBox(width: 6),
              Text(
                '${(f.progress * 100).round()}%',
                style: const TextStyle(fontSize: 11, color: Colors.black45),
              ),
            ],
            if (done) ...[
              const SizedBox(width: 6),
              Icon(
                Platform.isMacOS ? Icons.folder_open : Icons.ios_share,
                size: 14,
                color: AmyTheme.accent,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openFile(BuildContext context, TransferFile f) async {
    final path = f.path;
    if (path == null) return;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      await Process.run(
        Platform.isMacOS ? 'open' : 'xdg-open',
        [path],
      );
    } else {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    }
  }

  Widget _footer(BuildContext context) {
    final time =
        '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}';
    return switch (msg.status) {
      MessageStatus.offered => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => onAnswer(false),
              child: const Text('拒绝', style: TextStyle(color: Colors.black45)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AmyTheme.accent,
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onPressed: () => onAnswer(true),
              child: const Text('接受'),
            ),
          ],
        ),
      MessageStatus.waitingApproval => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            const Text('等待对方接受…',
                style: TextStyle(fontSize: 11, color: Colors.black45)),
            TextButton(
              onPressed: onCancel,
              child: const Text('取消', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      MessageStatus.active => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: msg.progress,
                minHeight: 5,
                backgroundColor: Colors.black12,
                valueColor: const AlwaysStoppedAnimation(AmyTheme.accent),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${(msg.progress * 100).round()}%',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black54)),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.only(left: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      MessageStatus.done => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, size: 13, color: Colors.black38),
            const SizedBox(width: 4),
            Text(time,
                style:
                    const TextStyle(fontSize: 11, color: Colors.black38)),
          ],
        ),
      MessageStatus.declined => _statusLine('已拒绝', Icons.block),
      MessageStatus.cancelled =>
        _statusLine('已取消', Icons.cancel_outlined),
      MessageStatus.failed =>
        _statusLine('发送失败${msg.error != null ? ' · ${msg.error}' : ''}',
            Icons.error_outline),
    };
  }

  Widget _statusLine(String text, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.black38),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: Colors.black38),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
