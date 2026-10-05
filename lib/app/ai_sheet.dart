import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'approvals_card.dart';
import 'settings_sheet.dart';
import 'theme.dart';

Future<void> showAiSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const AiSheet(),
  );
}

class _Entry {
  _Entry(this.mine, this.text);

  final bool mine;
  final String text;
}

/// Chat-style command sheet for the in-app AI assistant. Every send the
/// model proposes still flows through the normal approval cards — this
/// panel is only the translator.
class AiSheet extends ConsumerStatefulWidget {
  const AiSheet({super.key});

  @override
  ConsumerState<AiSheet> createState() => _AiSheetState();
}

class _AiSheetState extends ConsumerState<AiSheet> {
  final _input = TextEditingController();
  final _entries = <_Entry>[];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _entries.add(_Entry(true, text));
      _busy = true;
      _input.clear();
    });
    String reply;
    try {
      reply = await ref.read(engineProvider).brain.run(text);
    } catch (e) {
      reply = '出错了: $e';
    }
    if (!mounted) return;
    setState(() {
      _entries.add(_Entry(false, reply));
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineProvider);
    final configured = engine.llmConfig.configured;
    // With the keyboard up plus an approval card, the fixed chat area
    // would overflow the sheet and push the input/approve controls off
    // screen — shrink it to whatever space is actually left.
    final mq = MediaQuery.of(context);
    final avail = mq.size.height - mq.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('AI 助手',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            configured
                ? '${engine.llmConfig.model} · 发送动作仍会走本机审批'
                : '未配置模型 — 先到本机设置 → AI 大脑 里填密钥',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 10),
          // The sheet is modal and would otherwise block the approval
          // card on the home screen — mirror it here so the user can
          // approve the very send this conversation is waiting on.
          const AgentApprovals(),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: (avail - 280).clamp(80.0, 320.0),
                minHeight: 80),
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      '试试:把 xx 文件发给 iPhone · 查看在线设备',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in _entries)
                        Align(
                          alignment: e.mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            constraints: const BoxConstraints(maxWidth: 420),
                            decoration: BoxDecoration(
                              color: e.mine
                                  ? AmyTheme.bubbleMe
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(e.text,
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 8),
                              Text('思考中…', style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          if (!configured)
            OutlinedButton.icon(
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('去配置模型'),
              onPressed: () {
                Navigator.of(context).pop();
                showSettingsSheet(context);
              },
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      hintText: '例如:把 report.pdf 发给 iPhone',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: AmyTheme.accent),
                  icon: const Icon(Icons.arrow_upward, size: 20),
                  onPressed: _busy ? null : _send,
                ),
              ],
            ),
        ],
      ),
    );
  }
}
