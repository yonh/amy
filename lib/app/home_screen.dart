import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/providers.dart';
import 'ai_sheet.dart';
import 'approvals_card.dart';
import 'connect_sheet.dart';
import 'icons.dart';
import 'plans_sheet.dart';
import 'session_screen.dart';
import 'settings_sheet.dart';
import 'theme.dart';

/// Desktop OS drag-and-drop is a no-op on mobile — safe to wrap everywhere.
bool get supportsDrop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Builds a sendable [TransferFile] from a local path (drag & drop / picker).
TransferFile fileFromPath(String path) {
  final name = path.split('/').last.split('\\').last;
  var size = 0;
  try {
    size = File(path).lengthSync();
  } catch (_) {}
  return TransferFile(id: randomId(4), name: name, size: size, path: path);
}

/// Device list + adaptive detail pane, ported from prototype variant D:
/// online devices surface under 附近设备, devices with transfer history under
/// 会话, and tapping either opens the chat-style session.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Peer? _selected;
  bool _aiOpen = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Files staged for one-tap sends: while non-empty, tapping a device
  /// sends immediately instead of opening the session (AirDrop-style).
  final List<TransferFile> _quick = [];
  String? _dropFp;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    // 320 (device list) + 340 (AI panel) + a workable session needs ~1080.
    final threePane = MediaQuery.of(context).size.width >= 1080;
    final nearby = ref.watch(nearbyProvider);
    final threaded = ref.watch(threadedPeersProvider);

    return Scaffold(
      key: _scaffoldKey,
      // On phones the AI panel lives in the end drawer; on wide layouts
      // it is an inline sidebar, so the drawer only exists for narrow ones.
      endDrawer: wide
          ? null
          : const Drawer(
              width: 320,
              child: SafeArea(
                child: AiPanel(),
              ),
            ),
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: _deviceList(nearby, threaded),
                  ),
                  const VerticalDivider(width: 1),
                  // Three fixed panes only fit once there's real room —
                  // at ~720px a 340px sidebar would leave the session
                  // unusable, so the AI panel replaces the detail pane.
                  Expanded(
                    child: _aiOpen && !threePane
                        ? AiPanel(
                            onClose: () => setState(() => _aiOpen = false),
                          )
                        : _selected == null
                            ? const _EmptyDetail()
                            : SessionScreen(
                                key: ValueKey(_selected!.fingerprint),
                                peer: _selected!,
                                embedded: true,
                              ),
                  ),
                  if (_aiOpen && threePane) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 340,
                      child: AiPanel(
                        onClose: () => setState(() => _aiOpen = false),
                      ),
                    ),
                  ],
                ],
              )
            : _deviceList(nearby, threaded),
      ),
    );
  }

  void _open(Peer peer) {
    final wide = MediaQuery.of(context).size.width >= 720;
    if (wide) {
      setState(() => _selected = peer);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(peer: peer),
        ),
      );
    }
  }

  Widget _deviceList(List<Peer> nearby, List<Peer> threaded) {
    final wide = MediaQuery.of(context).size.width >= 720;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '设备',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.smart_toy_outlined,
                    color: AmyTheme.accent),
                tooltip: 'AI 助手',
                onPressed: () {
                  if (wide) {
                    setState(() => _aiOpen = !_aiOpen);
                  } else {
                    _scaffoldKey.currentState?.openEndDrawer();
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.schedule_send,
                    color: AmyTheme.accent),
                tooltip: '计划发送',
                onPressed: () => showPlansSheet(context),
              ),
              IconButton(
                icon: const Icon(Icons.tune, color: AmyTheme.accent),
                tooltip: '本机设置',
                onPressed: () => showSettingsSheet(context),
              ),
              IconButton(
                icon:
                    const Icon(Icons.add_circle_outline, color: AmyTheme.accent),
                tooltip: '用代码连接',
                onPressed: () => showConnectSheet(context),
              ),
            ],
          ),
        ),
        _quickSendBar(),
        const AgentApprovals(),
        Expanded(
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    const Text(
                      '附近设备',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AmyTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _scanStatus(nearby.length),
                  ],
                ),
              ),
              for (final p in nearby) _peerTile(p, nearby: true),
              if (threaded.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                  child: Text(
                    '会话',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
                for (final p in threaded) _peerTile(p, nearby: false),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Scan status + manual refresh: discovery runs one pass at launch and
  /// afterwards only when the user asks for it.
  Widget _scanStatus(int online) {
    final discovery = ref.watch(engineProvider).discovery;
    return StreamBuilder<bool>(
      stream: discovery.scanningStream,
      initialData: discovery.scanning,
      builder: (context, snap) {
        final busy = snap.data ?? false;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AmyTheme.accent.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '搜索中…',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ] else
              Text(
                '$online 台在线',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            SizedBox(
              width: 30,
              height: 30,
              child: IconButton(
                iconSize: 16,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.refresh),
                tooltip: '重新搜索',
                onPressed: busy ? null : discovery.scanNow,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _quickSendBar() {
    Widget inner = Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _dropFp == 'quick' || _quick.isNotEmpty
            ? AmyTheme.accent.withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border.all(
          color: _dropFp == 'quick'
              ? AmyTheme.accent
              : AmyTheme.accent.withValues(alpha: 0.35),
          style: _quick.isEmpty ? BorderStyle.solid : BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _quick.isEmpty
          ? Row(
              children: [
                Icon(Icons.ios_share,
                    size: 20,
                    color: AmyTheme.accent.withValues(alpha: 0.8)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    supportsDrop ? '拖文件到这里，再点设备即发送' : '选好文件，再点设备即发送',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ),
                TextButton(
                  onPressed: _pickQuick,
                  child: const Text('选择文件'),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt, size: 18, color: AmyTheme.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '点下方设备即发送 ${_quick.length} 个文件',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(_quick.clear),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close, size: 16, color: Colors.black45),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in _quick)
                      Chip(
                        avatar: Icon(iconForFileKind(f.kind), size: 14),
                        label: Text(f.name,
                            style: const TextStyle(fontSize: 11),
                            overflow: TextOverflow.ellipsis),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
    );
    if (!supportsDrop) return inner;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropFp = 'quick'),
      onDragExited: (_) => setState(() => _dropFp = null),
      onDragDone: (d) => setState(
          () => _quick.addAll(d.files.map((f) => fileFromPath(f.path)))),
      child: inner,
    );
  }

  Future<void> _pickQuick() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    setState(() {
      _quick.addAll([
        for (final f in files)
          if (f.path != null) fileFromPath(f.path!),
      ]);
    });
  }

  void _quickSend(Peer p) {
    final files = List.of(_quick);
    setState(_quick.clear);
    ref.read(engineProvider).sendFiles(p, files);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已发给 ${p.alias} · ${files.length} 个文件，等待对方接受'),
      duration: const Duration(seconds: 2),
    ));
    _open(p);
  }

  void _peerOptions(Peer p) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _PeerOptionsSheet(peer: p),
    );
  }

  Widget _peerTile(Peer p, {required bool nearby}) {
    final engine = ref.watch(engineProvider);
    final selected = _selected?.fingerprint == p.fingerprint;
    final thread = engine.threadFor(p.fingerprint);
    final online = p.online;
    final dropping = _dropFp == p.fingerprint;
    Widget tile = Container(
      color: dropping ? AmyTheme.accent.withValues(alpha: 0.15) : null,
      child: ListTile(
      selected: selected,
      selectedTileColor: AmyTheme.bubbleMe,
      leading: deviceAvatar(p, selected: selected),
      title: Text(p.alias, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        nearby && thread.isEmpty
            ? '同一局域网 · 点按开始会话'
            : online
                ? _preview(thread)
                : '不在附近',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: nearby && thread.isEmpty ? AmyTheme.accent : null,
        ),
      ),
      trailing: nearby && thread.isEmpty
          ? Icon(Icons.bolt, size: 18, color: AmyTheme.accent.withValues(alpha: 0.7))
          : (!online ? const Icon(Icons.cloud_off, size: 16, color: Colors.grey) : null),
      onTap: () => _quick.isNotEmpty
          ? _quickSend(p)
          : _open(p),
      onLongPress: () => _peerOptions(p),
      ),
    );
    if (!supportsDrop || !online) return tile;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropFp = p.fingerprint),
      onDragExited: (_) => setState(() => _dropFp = null),
      onDragDone: (d) {
        setState(() => _dropFp = null);
        final files = d.files.map((f) => fileFromPath(f.path)).toList();
        if (files.isEmpty) return;
        ref.read(engineProvider).sendFiles(p, files);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('已发给 ${p.alias} · ${files.length} 个文件，等待对方接受'),
          duration: const Duration(seconds: 2),
        ));
      },
      child: tile,
    );
  }

  String _preview(List<TransferMessage> thread) {
    if (thread.isEmpty) return '同一局域网 · 点按开始会话';
    final m = thread.last;
    final who = m.outgoing ? '你' : '对方';
    final what =
        m.files.length == 1 ? m.files.first.name : '${m.files.length} 个文件';
    return switch (m.status) {
      MessageStatus.offered => '$who想发送 $what',
      MessageStatus.waitingApproval => '等待对方接受…',
      MessageStatus.active => '传输中 ${(m.progress * 100).round()}%',
      MessageStatus.done => '$who发送了 $what',
      MessageStatus.declined => '$who拒绝了 $what',
      MessageStatus.cancelled => '$what 已取消',
      MessageStatus.failed => '$what 发送失败',
    };
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.forum_outlined, size: 48, color: AmyTheme.accent),
          const SizedBox(height: 12),
          const Text('点一台设备开始传文件', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 4),
          Text(
            '附近设备在线时自动出现在列表',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

/// Long-press device options: custom avatar emoji + pin/unpin.
class _PeerOptionsSheet extends ConsumerStatefulWidget {
  const _PeerOptionsSheet({required this.peer});

  final Peer peer;

  @override
  ConsumerState<_PeerOptionsSheet> createState() => _PeerOptionsSheetState();
}

class _PeerOptionsSheetState extends ConsumerState<_PeerOptionsSheet> {
  static const _presets = [
    '😀', '🐱', '🐶', '🦊', '🐼', '🚀', '⭐', '🌸',
    '📱', '💻', '🖥️', '🤖', '🎧', '📷', '🎮', '⌚',
  ];

  late final TextEditingController _emojiCtrl =
      TextEditingController(text: widget.peer.iconEmoji ?? '');

  @override
  void dispose() {
    _emojiCtrl.dispose();
    super.dispose();
  }

  void _save(String emoji) {
    ref.read(engineProvider).customizePeer(widget.peer, iconEmoji: emoji);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    final engine = ref.watch(engineProvider);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              deviceAvatar(p, radius: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.alias,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    Text(p.online ? '在附近' : '不在附近',
                        style: TextStyle(
                            fontSize: 12,
                            color: p.online ? AmyTheme.online : Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('自定义图标',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _presets)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _save(e),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emojiCtrl,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    hintText: '或输入任意 emoji',
                    isDense: true,
                    counterText: '',
                  ),
                  onSubmitted: _save,
                ),
              ),
              TextButton(
                onPressed: () => _save(_emojiCtrl.text.trim()),
                child: const Text('保存'),
              ),
              if (p.iconEmoji != null)
                TextButton(
                  onPressed: () => _save(''),
                  child: const Text('恢复默认',
                      style: TextStyle(color: Colors.black45)),
                ),
            ],
          ),
          const Divider(height: 24),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(p.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: AmyTheme.accent),
            title: Text(p.pinned ? '取消记住这台设备' : '记住这台设备（离线也保留）'),
            onTap: () {
              p.pinned ? engine.unpinPeer(p) : engine.pinPeer(p);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}
