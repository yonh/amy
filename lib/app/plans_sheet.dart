import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine.dart';
import '../core/models.dart';
import '../state/providers.dart';
import 'icons.dart';
import 'theme.dart';

Future<void> showPlansSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const PlansSheet(),
  );
}

/// Scheduled sends: pending/running plans live-update, done/failed ones stay
/// visible until removed. Plans persist across restarts.
class PlansSheet extends ConsumerWidget {
  const PlansSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(engineProvider);
    final engine = ref.read(engineProvider);
    final plans = engine.plans;
    final live = plans
        .where((p) =>
            p.status == PlanStatus.pending || p.status == PlanStatus.running)
        .toList();
    final past = plans
        .where((p) =>
            p.status != PlanStatus.pending && p.status != PlanStatus.running)
        .toList()
        .reversed
        .toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('计划发送',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AmyTheme.accent),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建'),
                  onPressed: () => showNewPlanSheet(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (plans.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '还没有计划任务\n可以定时发送，或等设备上线后自动发送',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in live) _planTile(context, engine, p),
                  for (final p in past) _planTile(context, engine, p),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planTile(BuildContext context, TransferEngine engine, SendPlan p) {
    final when = p.timed
        ? '定于 ${_fmtTime(p.runAt!)}'
        : '设备上线即发';
    final statusText = switch (p.status) {
      PlanStatus.pending => '$when · 待发送',
      PlanStatus.running => '发送中',
      PlanStatus.done => '已完成',
      PlanStatus.failed => '失败${p.error != null ? ' · ${p.error}' : ''}',
      PlanStatus.cancelled => '已取消',
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: AmyTheme.accent.withValues(alpha: 0.12),
        child: const Icon(Icons.schedule_send, size: 18, color: AmyTheme.accent),
      ),
      title: Text(
        '${p.peerAlias} · ${p.filePaths.length} 个文件',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        '${p.filePaths.map((x) => x.split(Platform.pathSeparator).last).join('、')} · $statusText',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: p.status == PlanStatus.pending || p.status == PlanStatus.running
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: '取消计划',
              onPressed: () => engine.cancelPlan(p.id),
            )
          : null,
    );
  }
}

Future<void> showNewPlanSheet(
  BuildContext context, {
  Peer? peer,
  List<String>? preselectedPaths,
  VoidCallback? onCreated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => NewPlanSheet(
      peer: peer,
      preselectedPaths: preselectedPaths,
      onCreated: onCreated,
    ),
  );
}

/// Create a plan: pick peer + files + when.
class NewPlanSheet extends ConsumerStatefulWidget {
  const NewPlanSheet({super.key, this.peer, this.preselectedPaths, this.onCreated});

  /// Pre-selected peer (e.g. from inside a session). Null = choose here.
  final Peer? peer;

  /// Files already chosen by the caller (e.g. the session draft).
  final List<String>? preselectedPaths;

  /// Called after the plan is created.
  final VoidCallback? onCreated;

  @override
  ConsumerState<NewPlanSheet> createState() => _NewPlanSheetState();
}

class _NewPlanSheetState extends ConsumerState<NewPlanSheet> {
  Peer? _peer;
  final _paths = <String>[];
  Duration? _delay; // null = on-online

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
    _paths.addAll(widget.preselectedPaths ?? const []);
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles();
    setState(() {
      for (final f in files) {
        if (f.path != null) _paths.add(f.path!);
      }
    });
  }

  void _create() {
    final peer = _peer;
    if (peer == null || _paths.isEmpty) return;
    final runAt = _delay == null ? null : DateTime.now().add(_delay!);
    ref.read(engineProvider).createPlan(peer, _paths, runAt: runAt);
    widget.onCreated?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(peersProvider);
    final engine = ref.read(engineProvider);
    final peers = {
      for (final p in engine.peers.values) p.fingerprint: p,
    };
    final opts = <Duration?, String>{
      null: '对方上线时',
      const Duration(minutes: 15): '15 分钟后',
      const Duration(hours: 1): '1 小时后',
      const Duration(hours: 6): '6 小时后',
      const Duration(hours: 24): '明天此时',
    };

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
            const Text('新建计划发送',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            if (widget.peer == null)
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: '发送到',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                initialValue: _peer?.fingerprint,
                items: [
                  for (final p in peers.values)
                    DropdownMenuItem(
                      value: p.fingerprint,
                      child: Row(
                        children: [
                          Icon(iconForPlatform(p.platform), size: 18),
                          const SizedBox(width: 8),
                          Text(p.alias),
                          if (!p.online)
                            const Text('（不在附近）',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                ],
                onChanged: (fp) => setState(() {
                  _peer = fp == null ? null : engine.resolvePeer(fp);
                }),
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(iconForPlatform(_peer!.platform)),
                title: Text(_peer!.alias,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle:
                    Text(_peer!.online ? '在附近' : '不在附近（上线后自动发出）'),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in opts.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _delay == e.key,
                    onSelected: (_) => setState(() => _delay = e.key),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              label: Text(_paths.isEmpty ? '选择文件' : '已选 ${_paths.length} 个，继续添加'),
              onPressed: _pick,
            ),
            if (_paths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final x in _paths)
                      InputChip(
                        label: Text(
                          x.split(Platform.pathSeparator).last,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () => setState(() => _paths.remove(x)),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AmyTheme.accent),
              onPressed: _peer != null && _paths.isNotEmpty ? _create : null,
              child: const Text('创建计划'),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtTime(DateTime t) =>
    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
