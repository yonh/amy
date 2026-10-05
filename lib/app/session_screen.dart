import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/models.dart';
import '../state/providers.dart';
import 'home_screen.dart' show fileFromPath, supportsDrop;
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
  final _textCtrl = TextEditingController();
  bool _picking = false;
  bool _dropping = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

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

  void _send() {
    final text = _textCtrl.text.trim();
    if (_draft.isNotEmpty) {
      ref
          .read(engineProvider)
          .sendFiles(_peer, List.of(_draft));
      setState(_draft.clear);
    }
    if (text.isNotEmpty) {
      ref.read(engineProvider).sendText(_peer, text);
      setState(_textCtrl.clear);
    }
  }

  /// Clipboard send: copied files (desktop) → draft; copied image →
  /// materialized to a temp file → draft; plain text → sent as a text
  /// message right away.
  Future<void> _pasteClipboard() async {
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        setState(() => _draft.addAll(files.map(fileFromPath)));
        return;
      }
    } catch (_) {}
    try {
      final img = await Pasteboard.image;
      if (img != null) {
        final tmp = await getTemporaryDirectory();
        final p =
            '${tmp.path}/amy-clip-${DateTime.now().microsecondsSinceEpoch}.png';
        await File(p).writeAsBytes(img, flush: true);
        setState(() => _draft.add(fileFromPath(p)));
        return;
      }
    } catch (_) {}
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim() ?? '';
    if (t.isNotEmpty) {
      await ref.read(engineProvider).sendText(_peer, t);
      _toast('剪贴板文本已发送');
    } else {
      _toast('剪贴板是空的');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(engineProvider); // rebuild on any transfer update
    final peer = _peer;
    final engine = ref.read(engineProvider);
    final thread = engine.threadFor(peer.fingerprint);
    // Pending scheduled sends for this peer render as plan bubbles inline
    // — a scheduled message is still a message the user sent.
    final pendingPlans = engine.plans
        .where((p) =>
            p.peerFingerprint == peer.fingerprint &&
            p.status == PlanStatus.pending)
        .toList();

    final body = Column(
      children: [
        _header(peer),
        const Divider(height: 1),
        Expanded(
          child: thread.isEmpty && pendingPlans.isEmpty
              ? Center(
                  child: Text(
                    '还没有传过文件\n用下面的回形针发第一条',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                )
              : Builder(builder: (ctx) {
                  final items = <Object>[...thread, ...pendingPlans]
                    ..sort((a, b) => (a is TransferMessage
                            ? a.createdAt
                            : (a as SendPlan).createdAt)
                        .compareTo(b is TransferMessage
                            ? b.createdAt
                            : (b as SendPlan).createdAt));
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final it = items[i];
                      if (it is SendPlan) {
                        return _PlanBubble(
                          plan: it,
                          onCancel: () =>
                              ref.read(engineProvider).cancelPlan(it.id),
                        );
                      }
                      final msg = it as TransferMessage;
                      return _Bubble(
                        msg: msg,
                        onAnswer: (accept) => ref
                            .read(engineProvider)
                            .answerOffer(msg.id, accept),
                        onCancel: () =>
                            ref.read(engineProvider).cancelMessage(msg),
                      );
                    },
                  );
                }),
        ),
        _composer(peer),
      ],
    );
    Widget child = widget.embedded ? body : Scaffold(body: SafeArea(child: body));
    if (!supportsDrop) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (d) => setState(() {
        _dropping = false;
        _draft.addAll(d.files.map((f) => fileFromPath(f.path)));
      }),
      child: Stack(
        children: [
          child,
          if (_dropping)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: AmyTheme.accent.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AmyTheme.accent),
                    ),
                    child: const Text('松开即加入发送列表',
                        style: TextStyle(
                            color: AmyTheme.accent,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(Peer peer) {
    return Container(
      color: AmyTheme.bubblePeer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          if (!widget.embedded)
            const BackButton(),
          deviceAvatar(peer),
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
              IconButton(
                icon: const Icon(Icons.content_paste,
                    size: 19, color: AmyTheme.accent),
                onPressed: online ? _pasteClipboard : null,
                tooltip: '发送剪贴板',
              ),
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  enabled: online,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: !online
                        ? '设备不在附近，恢复后可发送'
                        : _draft.isEmpty
                            ? '输文字 · 📎 发文件 · 📋 发剪贴板'
                            : '待发 ${_draft.length} 个文件…',
                    isDense: true,
                    hintStyle: const TextStyle(
                        color: Colors.black38, fontSize: 13),
                    border: InputBorder.none,
                  ),
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
                onPressed: (_draft.isEmpty && _textCtrl.text.trim().isEmpty) ||
                        !online
                    ? null
                    : _send,
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
            if (msg.text != null)
              SelectableText(
                msg.text!,
                style: const TextStyle(fontSize: 14),
              ),
            for (final f in msg.files) _fileRow(context, f, active),
            const SizedBox(height: 6),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _fileRow(BuildContext context, TransferFile f, bool active) {
    final local = f.path != null && File(f.path!).existsSync();
    final isImage = f.kind == FileKind.image && local;
    final openable = local && (msg.outgoing || f.status == FileStatus.done);
    return InkWell(
      onTap: openable ? () => _previewFile(context, f) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Images that are already on disk render a thumbnail inline —
            // you can see what was sent without opening anything.
            if (isImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(f.path!),
                    width: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconForFileKind(f.kind),
                    size: 18, color: AmyTheme.accent),
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
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black45),
                  ),
                ],
                if (openable) ...[
                  const SizedBox(width: 6),
                  Icon(
                    isImage || f.kind == FileKind.video
                        ? Icons.play_circle_outline
                        : (Platform.isMacOS
                            ? Icons.folder_open
                            : Icons.ios_share),
                    size: 14,
                    color: AmyTheme.accent,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// In-app preview for images and videos; everything else falls back to
  /// the system opener / share sheet.
  Future<void> _previewFile(
      BuildContext context, TransferFile f) async {
    final path = f.path;
    if (path == null) return;
    switch (f.kind) {
      case FileKind.image:
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                InteractiveViewer(
                  child: Center(child: Image.file(File(path))),
                ),
                const Positioned(
                  top: 8,
                  right: 8,
                  child: CloseButton(color: Colors.white),
                ),
              ],
            ),
          ),
        );
      case FileKind.video:
        await showDialog<void>(
          context: context,
          builder: (_) => _VideoDialog(path: path, title: f.name),
        );
      default:
        await _openFile(context, f);
    }
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
      MessageStatus.sending => const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 13, color: Colors.black38),
            SizedBox(width: 4),
            Text('发送中…',
                style: TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ),
      MessageStatus.waitingApproval => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, size: 13, color: Colors.black38),
            const SizedBox(width: 4),
            Text(msg.text != null ? '发送中…' : '已送达 · 等待对方接受…',
                style: const TextStyle(fontSize: 11, color: Colors.black45)),
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
                if (msg.outgoing) ...[
                  const Icon(Icons.check, size: 13, color: Colors.black38),
                  const SizedBox(width: 4),
                ],
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
            // Telegram-style receipt: outgoing shows a double tick once
            // the peer confirmed receiving; incoming stays plain time.
            if (msg.outgoing) ...[
              const Icon(Icons.done_all, size: 13, color: AmyTheme.accent),
              const SizedBox(width: 4),
            ],
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

/// Outgoing-aligned bubble for a pending scheduled send — the "plan"
/// state of the delivery receipt: single tick only once it dispatches
/// into a real transfer message.
class _PlanBubble extends StatelessWidget {
  const _PlanBubble({required this.plan, required this.onCancel});

  final SendPlan plan;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final when = plan.timed
        ? '定于 ${plan.runAt!.month}/${plan.runAt!.day} '
            '${plan.runAt!.hour.toString().padLeft(2, '0')}:'
            '${plan.runAt!.minute.toString().padLeft(2, '0')}'
        : '设备上线即发';
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: AmyTheme.bubbleMe.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AmyTheme.accent.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final name in plan.filePaths)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.insert_drive_file_outlined,
                        size: 18, color: AmyTheme.accent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        name.split(RegExp(r'[/\\]')).last,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.schedule, size: 13,
                    color: AmyTheme.accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text('$when · 计划',
                      style: const TextStyle(
                          fontSize: 11, color: AmyTheme.accent)),
                ),
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
      ),
    );
  }
}

/// In-app video preview — plays the file inline instead of bouncing out
/// to a system player.
class _VideoDialog extends StatefulWidget {
  const _VideoDialog({required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  late final VideoPlayerController _c =
      VideoPlayerController.file(File(widget.path));
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      unawaited(_c.play());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    unawaited(_c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          Center(
            child: !_ready
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: _c.value.aspectRatio,
                    child: VideoPlayer(_c),
                  ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: CloseButton(color: Colors.white, onPressed: () {
              unawaited(_c.pause());
              Navigator.of(context).pop();
            }),
          ),
          if (_ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      _c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () => setState(() =>
                        _c.value.isPlaying ? _c.pause() : _c.play()),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
