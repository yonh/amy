// PROTOTYPE — Variant A「雷达发现」: LocalSend/AirDrop 式。
// 模型：模式切换。发送 / 接收 / 历史是三个并列 tab，
// 假设同一局域网的设备会被自动发现，点设备即传。
import 'dart:async';

import 'package:flutter/material.dart';

import 'data.dart';

class VariantA extends StatefulWidget {
  const VariantA({super.key});

  @override
  State<VariantA> createState() => _VariantAState();
}

class _Session {
  _Session({required this.device, required this.files, required this.sending});
  final ProtoDevice device;
  final List<ProtoFile> files;
  final bool sending;
  double progress = 0;
  bool done = false;
}

class _Offer {
  _Offer(this.device, this.files);
  final ProtoDevice device;
  final List<ProtoFile> files;
}

class _Entry {
  const _Entry({
    required this.sent,
    required this.device,
    required this.summary,
    required this.bytes,
    required this.when,
  });
  final bool sent;
  final String device;
  final String summary;
  final int bytes;
  final String when;
}

class _VariantAState extends State<VariantA> {
  int _tab = 0;
  final _files = <ProtoFile>[];
  int _discovered = 0;

  _Session? _session;
  _Offer? _offer;

  final _timers = <Timer>[];

  final _history = <_Entry>[
    const _Entry(
      sent: false,
      device: 'houmu 的 iPhone',
      summary: 'IMG_1990.heic 等 2 个文件',
      bytes: 7800000,
      when: '昨天 22:14',
    ),
    const _Entry(
      sent: true,
      device: '客厅 Windows PC',
      summary: '季度报告.pdf',
      bytes: 2300000,
      when: '昨天 09:02',
    ),
    const _Entry(
      sent: true,
      device: 'iPad Pro',
      summary: '设计稿归档.zip',
      bytes: 12600000,
      when: '周一 18:40',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  Timer _later(Duration d, void Function() fn) {
    final t = Timer(d, () {
      if (mounted) setState(fn);
    });
    _timers.add(t);
    return t;
  }

  void _startDiscovery() {
    // Devices appear one by one, like a real scan.
    for (var i = 0; i < kNearby.length; i++) {
      _later(Duration(milliseconds: 600 + i * 650), () => _discovered++);
    }
  }

  void _switchTab(int tab) {
    setState(() {
      _tab = tab;
      _offer = null;
    });
    if (tab == 1) _scheduleOffer();
  }

  void _scheduleOffer() {
    _later(const Duration(seconds: 2), () {
      if (_tab == 1 && _session == null) {
        _offer = _Offer(kNearby[0], const [
          ProtoFile('IMG_2041.heic', 4200000, kind: ProtoFileKind.image),
          ProtoFile('IMG_2042.heic', 3900000, kind: ProtoFileKind.image),
          ProtoFile('行程单.pdf', 800000),
        ]);
      }
    });
  }

  void _pickFiles() {
    final picked = _files.toSet();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('选择要发送的文件', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('原型数据，非真实文件'),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in kPickableFiles)
                      CheckboxListTile(
                        value: picked.contains(f),
                        onChanged: (v) => setSheet(
                          () => v! ? picked.add(f) : picked.remove(f),
                        ),
                        secondary: Icon(iconForFileKind(f.kind)),
                        title: Text(f.name),
                        subtitle: Text(fmtBytes(f.bytes)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: () {
                    setState(() {
                      _files
                        ..clear()
                        ..addAll(picked);
                    });
                    Navigator.pop(ctx);
                  },
                  child: Text('已选 ${picked.length} 个文件'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startSession(ProtoDevice device, {required bool sending, List<ProtoFile>? files}) {
    final session = _Session(
      device: device,
      files: files ?? List.of(_files),
      sending: sending,
    );
    setState(() => _session = session);
    _timers.add(
      fakeTransfer(
        onProgress: (p) {
          if (mounted) setState(() => session.progress = p);
        },
        onDone: () {
          if (mounted) setState(() => session.done = true);
        },
      ),
    );
  }

  void _finishSession() {
    final s = _session!;
    setState(() {
      _history.insert(
        0,
        _Entry(
          sent: s.sending,
          device: s.device.name,
          summary: s.files.length == 1
              ? s.files.first.name
              : '${s.files.first.name} 等 ${s.files.length} 个文件',
          bytes: totalBytes(s.files),
          when: '刚刚',
        ),
      );
      if (s.sending) _files.clear();
      _session = null;
      _tab = 2; // land on history so the new entry is visible
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E8A6D)),
      useMaterial3: true,
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _session != null
                    ? _buildTransfer(context, _session!)
                    : _buildHome(context, theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHome(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(iconForPlatform(kSelf.platform),
                    color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(kSelf.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16)),
                    Row(
                      children: [
                        Icon(Icons.wifi, size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('局域网已就绪 · 可被附近设备发现',
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.outline)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.north_east), label: Text('发送')),
              ButtonSegment(value: 1, icon: Icon(Icons.south_west), label: Text('接收')),
              ButtonSegment(value: 2, icon: Icon(Icons.history), label: Text('历史')),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => _switchTab(s.first),
            showSelectedIcon: false,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: switch (_tab) {
            0 => _buildSend(context, theme),
            1 => _buildReceive(context, theme),
            _ => _buildHistory(context, theme),
          },
        ),
      ],
    );
  }

  Widget _buildSend(BuildContext context, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        // File tray
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in _files)
              InputChip(
                avatar: Icon(iconForFileKind(f.kind), size: 18),
                label: Text(f.name),
                onDeleted: () => setState(() => _files.remove(f)),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: Text(_files.isEmpty ? '添加要发送的文件' : '添加'),
              onPressed: _pickFiles,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('附近设备',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(width: 8),
            if (_discovered < kNearby.length)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
            const SizedBox(width: 4),
            if (_discovered < kNearby.length)
              Text('搜索中…',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.outline)),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _discovered; i++)
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: Icon(iconForPlatform(kNearby[i].platform), size: 20),
              ),
              title: Text(kNearby[i].name),
              subtitle: const Text('同一局域网'),
              trailing: Icon(Icons.north_east,
                  size: 18, color: theme.colorScheme.primary),
              onTap: () {
                if (_files.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('先添加要发送的文件')),
                  );
                } else {
                  _startSession(kNearby[i], sending: true);
                }
              },
            ),
          ),
        if (_discovered == 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('正在寻找附近设备…',
                  style: TextStyle(color: theme.colorScheme.outline)),
            ),
          ),
      ],
    );
  }

  Widget _buildReceive(BuildContext context, ThemeData theme) {
    final offer = _offer;
    if (offer != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          elevation: 0,
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconForPlatform(offer.device.platform), size: 40),
                const SizedBox(height: 12),
                Text('${offer.device.name} 想要发送文件',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  '${offer.files.length} 个文件 · ${fmtBytes(totalBytes(offer.files))}',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                for (final f in offer.files)
                  ListTile(
                    dense: true,
                    leading: Icon(iconForFileKind(f.kind)),
                    title: Text(f.name),
                    trailing: Text(fmtBytes(f.bytes)),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(() {
                        _offer = null;
                        _scheduleOffer();
                      }),
                      child: const Text('拒绝'),
                    ),
                    FilledButton(
                      onPressed: () => _startSession(
                        offer.device,
                        sending: false,
                        files: offer.files,
                      ),
                      child: const Text('接受'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 20),
          const Text('等待接收', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('其他设备现在可以在附近找到这台机器',
              style: TextStyle(fontSize: 13, color: theme.colorScheme.outline)),
        ],
      ),
    );
  }

  Widget _buildHistory(BuildContext context, ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: _history.length,
      itemBuilder: (ctx, i) {
        final e = _history[i];
        return ListTile(
          leading: Icon(
            e.sent ? Icons.north_east : Icons.south_west,
            color: e.sent
                ? theme.colorScheme.primary
                : theme.colorScheme.tertiary,
          ),
          title: Text(e.summary),
          subtitle: Text('${e.device} · ${fmtBytes(e.bytes)}'),
          trailing: Text(e.when,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
        );
      },
    );
  }

  Widget _buildTransfer(BuildContext context, _Session s) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(iconForPlatform(s.device.platform), size: 34),
          ),
          const SizedBox(height: 16),
          Text(
            s.done
                ? (s.sending ? '已发送到 ${s.device.name}' : '已接收完成')
                : (s.sending ? '正在发送到 ${s.device.name}' : '正在从 ${s.device.name} 接收'),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: s.done ? 1 : s.progress,
                    strokeWidth: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                s.done
                    ? Icon(Icons.check_circle,
                        size: 56, color: theme.colorScheme.primary)
                    : Text('${(s.progress * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 30, fontWeight: FontWeight.w300)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          for (final f in s.files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(iconForFileKind(f.kind), size: 16,
                      color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Text('${f.name} · ${fmtBytes(f.bytes)}',
                      style: TextStyle(
                          fontSize: 13, color: theme.colorScheme.outline)),
                ],
              ),
            ),
          const SizedBox(height: 28),
          if (s.done)
            FilledButton(onPressed: _finishSession, child: const Text('完成'))
          else
            OutlinedButton(
              onPressed: () => setState(() => _session = null),
              child: const Text('取消'),
            ),
        ],
      ),
    );
  }
}
