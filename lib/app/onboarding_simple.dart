import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/identity.dart';
import '../state/providers.dart';
import 'theme.dart';

/// Variant A — minimal single-sheet onboarding: set your device name,
/// see where received files land, start. Shown once on first run.
Future<void> showSimpleOnboarding(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const SimpleOnboardingSheet(),
  );
}

class SimpleOnboardingSheet extends ConsumerStatefulWidget {
  const SimpleOnboardingSheet({super.key});

  @override
  ConsumerState<SimpleOnboardingSheet> createState() =>
      _SimpleOnboardingSheetState();
}

class _SimpleOnboardingSheetState
    extends ConsumerState<SimpleOnboardingSheet> {
  late final TextEditingController _aliasCtrl =
      TextEditingController(text: ref.read(identityProvider).alias);

  @override
  void dispose() {
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final alias = _aliasCtrl.text.trim();
    if (alias.isNotEmpty) {
      ref.read(identityProvider).alias = alias;
      await saveAlias(alias);
    }
    await markOnboarded();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 28,
          bottom: MediaQuery.of(context).viewInsets.bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: Text('👋', style: TextStyle(fontSize: 44)),
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text('欢迎使用 amy',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                '同一局域网的设备间互发文件，无需数据线',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _aliasCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '你的设备名',
                helperText: '附近设备会以这个名字看到你',
                prefixIcon: const Icon(Icons.badge_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _start(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.folder_outlined,
                    size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '收到的文件保存在：${engine.ready ? engine.downloads.path : '…'}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AmyTheme.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _start,
              child: const Text('开始使用', style: TextStyle(fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}
