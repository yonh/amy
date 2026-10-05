import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/providers.dart';
import 'theme.dart';

/// Pending AI/agent actions awaiting the user's tap (leader instructions,
/// agent sends over the size cap, anything not auto-approved). Rendered
/// on the home screen AND inside the AI sheet so a modal dialog can
/// never block approval of the very send it requested.
class AgentApprovals extends ConsumerWidget {
  const AgentApprovals({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final actions = engine.pendingAgentActions;
    if (actions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD591)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined,
                  size: 18, color: Color(0xFFAD6800)),
              const SizedBox(width: 6),
              Text(
                'AI 待审批 · ${actions.length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFAD6800),
                ),
              ),
            ],
          ),
          // Cap the card so a burst of pending actions can't push the
          // buttons below the fold — older entries scroll inside.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in actions)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.label,
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              Text(
                                '${a.remote ? '主控设备指令 · ' : ''}${fmtBytes(a.bytes)}',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              engine.answerAgentAction(a.id, false),
                          child: const Text('拒绝'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: AmyTheme.accent,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14)),
                          onPressed: () =>
                              engine.answerAgentAction(a.id, true),
                          child: const Text('允许'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
