import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/identity.dart';
import '../core/models.dart';
import '../state/providers.dart';
import 'theme.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const SettingsSheet(),
  );
}

/// Device alias + receive directory + housekeeping.
class SettingsSheet extends ConsumerStatefulWidget {
  const SettingsSheet({super.key});

  @override
  ConsumerState<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<SettingsSheet> {
  late final TextEditingController _aliasCtrl;

  @override
  void initState() {
    super.initState();
    _aliasCtrl = TextEditingController(text: ref.read(identityProvider).alias);
  }

  @override
  void dispose() {
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAlias() async {
    final alias = _aliasCtrl.text.trim();
    if (alias.isEmpty) return;
    final identity = ref.read(identityProvider);
    identity.alias = alias;
    await saveAlias(alias);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称已保存，重启后对其他设备生效')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
    final engine = ref.watch(engineProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('本机设置',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(
              controller: _aliasCtrl,
              decoration: InputDecoration(
                labelText: '设备名（其他设备看到的名字）',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _saveAlias(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AmyTheme.accent),
              onPressed: _saveAlias,
              child: const Text('保存名称'),
            ),
            const SizedBox(height: 20),
            _infoRow('接收目录', engine.ready ? engine.downloads.path : '…'),
            _infoRow('监听端口', '${identity.port}'),
            _infoRow('协议版本', 'v1 · 局域网明文传输'),
            const SizedBox(height: 20),
            _AiSection(),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(k, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// AI/agent controls: how much automation this device permits, and whether
/// a leader device may instruct it remotely.
class _AiSection extends ConsumerWidget {
  static const _thresholds = [8, 32, 128, 512];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final p = engine.aiPolicy;
    final mb = (p.autoApproveBytes / (1024 * 1024)).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('AI 助手',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('控制 agent / 主控设备 可以代做的动作',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        SegmentedButton<AiMode>(
          segments: const [
            ButtonSegment(value: AiMode.off, label: Text('关闭')),
            ButtonSegment(value: AiMode.ask, label: Text('需确认')),
            ButtonSegment(value: AiMode.auto, label: Text('自动')),
          ],
          selected: {p.mode},
          onSelectionChanged: (s) {
            p.mode = s.first;
            engine.setAiPolicy(p);
          },
        ),
        if (p.mode == AiMode.auto) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('超过此大小的发送仍需确认',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              ),
              DropdownButton<int>(
                value: _thresholds.contains(mb) ? mb : 32,
                items: [
                  for (final t in _thresholds)
                    DropdownMenuItem(value: t, child: Text('$t MB')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  p.autoApproveBytes = v * 1024 * 1024;
                  engine.setAiPolicy(p);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许主控设备指挥本机', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '开启后其他设备可用 token 远程发起发送，仍需本机逐次确认',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          value: p.allowRemoteControl,
          onChanged: (v) {
            p.allowRemoteControl = v;
            engine.setAiPolicy(p);
          },
        ),
        if (p.allowRemoteControl) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    p.remoteToken,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制 token',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: p.remoteToken));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('token 已复制')));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '轮换 token（旧的立即失效）',
                  onPressed: () => engine.rotateRemoteToken(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '把这个 token 发给主控设备一次，之后它才可指挥本机',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ],
    );
  }
}
