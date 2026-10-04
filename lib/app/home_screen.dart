import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/providers.dart';
import 'connect_sheet.dart';
import 'icons.dart';
import 'plans_sheet.dart';
import 'session_screen.dart';
import 'settings_sheet.dart';
import 'theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final nearby = ref.watch(nearbyProvider);
    final threaded = ref.watch(threadedPeersProvider);
    final scanning = nearby.isEmpty;

    return Scaffold(
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: _deviceList(nearby, threaded, scanning),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _selected == null
                        ? const _EmptyDetail()
                        : SessionScreen(
                            key: ValueKey(_selected!.fingerprint),
                            peer: _selected!,
                            embedded: true,
                          ),
                  ),
                ],
              )
            : _deviceList(nearby, threaded, scanning),
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

  Widget _deviceList(List<Peer> nearby, List<Peer> threaded, bool scanning) {
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
                    if (scanning) ...[
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
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ] else
                      Text(
                        '${nearby.length} 台在线',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
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

  Widget _peerTile(Peer p, {required bool nearby}) {
    final engine = ref.watch(engineProvider);
    final selected = _selected?.fingerprint == p.fingerprint;
    final thread = engine.threadFor(p.fingerprint);
    final online = p.online;
    return ListTile(
      selected: selected,
      selectedTileColor: AmyTheme.bubbleMe,
      leading: CircleAvatar(
        backgroundColor:
            selected ? AmyTheme.accent : AmyTheme.accent.withValues(alpha: 0.12),
        child: Icon(
          iconForPlatform(p.platform),
          size: 20,
          color: selected ? Colors.white : AmyTheme.accent,
        ),
      ),
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
      onTap: () => _open(p),
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
