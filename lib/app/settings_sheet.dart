import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/identity.dart';
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
