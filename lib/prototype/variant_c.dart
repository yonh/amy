// PROTOTYPE — Variant C「设备会话」: 聊天式模型。
// 没有"发送/接收"模式之分 —— 每台设备是一条长期会话，
// 文件像消息一样在气泡里流动，进度就长在气泡上。
import 'dart:async';

import 'package:flutter/material.dart';

import 'data.dart';

class VariantC extends StatefulWidget {
  const VariantC({super.key});

  @override
  State<VariantC> createState() => _VariantCState();
}

enum _MsgStatus { offered, active, done }

class _Msg {
  _Msg({
    required this.fromMe,
    required this.files,
    required this.when,
    this.status = _MsgStatus.done,
  });
  final bool fromMe;
  final List<ProtoFile> files;
  final String when;
  _MsgStatus status;
  double progress = 0;
}

class _VariantCState extends State<VariantC> {
  static const _bg = Color(0xFFFAF3EC);
  static const _accent = Color(0xFFD95D39);
  static const _bubbleMe = Color(0xFFFFE3D3);
  static const _bubblePeer = Colors.white;

  int? _selected;
  final _draft = <ProtoFile>[];
  final _timers = <Timer>[];
  final _offerFired = <int>{};

  late final Map<int, List<_Msg>> _threads = {
    0: [
      _Msg(
        fromMe: false,
        files: const [
          ProtoFile('IMG_1990.heic', 4100000, kind: ProtoFileKind.image),
          ProtoFile('IMG_1991.heic', 3800000, kind: ProtoFileKind.image),
        ],
        when: '昨天 22:14',
      ),
      _Msg(
        fromMe: true,
        files: const [ProtoFile('机票订单.pdf', 900000)],
        when: '昨天 22:20',
      ),
    ],
    1: [
      _Msg(
        fromMe: true,
        files: const [
          ProtoFile('设计稿归档.zip', 12600000, kind: ProtoFileKind.archive)
        ],
        when: '周一 18:40',
      ),
    ],
  };

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

  List<_Msg> _thread(int i) => _threads.putIfAbsent(i, () => []);

  void _select(int i) {
    setState(() => _selected = i);
    // First visit to the iPhone thread: a file offer lands a few seconds in.
    if (i == 0 && _offerFired.add(i)) {
      _later(const Duration(seconds: 3), () {
        _thread(0).add(
          _Msg(
            fromMe: false,
            files: const [
              ProtoFile('截屏.png', 600000, kind: ProtoFileKind.image),
              ProtoFile('快递单.pdf', 400000),
            ],
            when: '现在',
            status: _MsgStatus.offered,
          ),
        );
      });
    }
  }

  void _pickFiles() {
    final picked = _draft.toSet();
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
                title: Text('添加到消息',
                    style: TextStyle(fontWeight: FontWeight.w600)),
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
                  style: FilledButton.styleFrom(backgroundColor: _accent),
                  onPressed: () {
                    setState(() {
                      _draft
                        ..clear()
                        ..addAll(picked);
                    });
                    Navigator.pop(ctx);
                  },
                  child: Text('已选 ${picked.length} 个'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendDraft(int deviceIndex) {
    if (_draft.isEmpty) return;
    final msg = _Msg(
      fromMe: true,
      files: List.of(_draft),
      when: '现在',
      status: _MsgStatus.active,
    );
    setState(() {
      _thread(deviceIndex).add(msg);
      _draft.clear();
    });
    _timers.add(
      fakeTransfer(
        onProgress: (p) {
          if (mounted) setState(() => msg.progress = p);
        },
        onDone: () {
          if (mounted) setState(() => msg.status = _MsgStatus.done);
        },
      ),
    );
  }

  void _answerOffer(_Msg msg, bool accept) {
    setState(() {
      if (!accept) {
        _thread(_selected!).remove(msg);
        return;
      }
      msg.status = _MsgStatus.active;
    });
    if (!accept) return;
    _timers.add(
      fakeTransfer(
        onProgress: (p) {
          if (mounted) setState(() => msg.progress = p);
        },
        onDone: () {
          if (mounted) setState(() => msg.status = _MsgStatus.done);
        },
      ),
    );
  }

  String _preview(List<_Msg> thread) {
    if (thread.isEmpty) return '还没有传过文件';
    final m = thread.last;
    final who = m.fromMe ? '你' : '对方';
    final what = m.files.length == 1
        ? m.files.first.name
        : '${m.files.length} 个文件';
    return switch (m.status) {
      _MsgStatus.offered => '$who想发送 $what',
      _MsgStatus.active => '传输中 ${(m.progress * 100).round()}%',
      _MsgStatus.done => '$who发送了 $what',
    };
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accent,
        surface: _bg,
      ),
      scaffoldBackgroundColor: _bg,
      useMaterial3: true,
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      SizedBox(width: 320, child: _deviceList(theme)),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _selected == null
                            ? _emptyDetail()
                            : _detail(theme, _selected!),
                      ),
                    ],
                  )
                : (_selected == null
                    ? _deviceList(theme)
                    : _detail(theme, _selected!)),
          ),
        ),
      ),
    );
  }

  Widget _deviceList(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('设备',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: _accent),
                tooltip: '连接新设备',
                onPressed: _connectSheet,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: kNearby.length,
            itemBuilder: (ctx, i) {
              final d = kNearby[i];
              final selected = _selected == i;
              return ListTile(
                selected: selected,
                selectedTileColor: _bubbleMe,
                leading: CircleAvatar(
                  backgroundColor:
                      selected ? _accent : _accent.withValues(alpha: 0.15),
                  child: Icon(
                    iconForPlatform(d.platform),
                    size: 20,
                    color: selected ? Colors.white : _accent,
                  ),
                ),
                title: Text(d.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  _preview(_thread(i)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => _select(i),
              );
            },
          ),
        ),
      ],
    );
  }

  void _connectSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('连接新设备',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextField(
                decoration: InputDecoration(
                  hintText: '输入对方显示的 6 位代码',
                  prefixIcon: const Icon(Icons.tag),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                keyboardType: TextInputType.number,
                maxLength: 6,
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('或扫码连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyDetail() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 48, color: _accent),
          SizedBox(height: 12),
          Text('选一台设备开始传文件', style: TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _detail(ThemeData theme, int i) {
    final d = kNearby[i];
    final wide = MediaQuery.of(context).size.width >= 720;
    final thread = _thread(i);
    return Column(
      children: [
        Container(
          color: _bubblePeer,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              if (!wide)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selected = null),
                ),
              CircleAvatar(
                backgroundColor: _accent.withValues(alpha: 0.15),
                child:
                    Icon(iconForPlatform(d.platform), size: 20, color: _accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const Text('在线 · 局域网',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF5BA150))),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: thread.length,
            itemBuilder: (ctx, idx) => _bubble(thread[idx]),
          ),
        ),
        _composer(i),
      ],
    );
  }

  Widget _bubble(_Msg m) {
    final radius = BorderRadius.circular(16);
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: m.fromMe ? _bubbleMe : _bubblePeer,
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in m.files)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(iconForFileKind(f.kind), size: 18, color: _accent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${f.name}  ·  ${fmtBytes(f.bytes)}',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            switch (m.status) {
              _MsgStatus.offered => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _answerOffer(m, false),
                      child: const Text('拒绝',
                          style: TextStyle(color: Colors.black45)),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 20)),
                      onPressed: () => _answerOffer(m, true),
                      child: const Text('接受'),
                    ),
                  ],
                ),
              _MsgStatus.active => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: m.progress,
                        minHeight: 5,
                        backgroundColor: Colors.black12,
                        valueColor: const AlwaysStoppedAnimation(_accent),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${(m.progress * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black54)),
                  ],
                ),
              _MsgStatus.done => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check, size: 13, color: Colors.black38),
                    const SizedBox(width: 4),
                    Text(m.when,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black38)),
                  ],
                ),
            },
          ],
        ),
      ),
    );
  }

  Widget _composer(int deviceIndex) {
    return Container(
      color: _bubblePeer,
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
                      label: Text(f.name,
                          style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setState(() => _draft.remove(f)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file, color: _accent),
                onPressed: _pickFiles,
                tooltip: '添加文件',
              ),
              Expanded(
                child: Text(
                  _draft.isEmpty ? '点回形针选择要发送的文件' : '待发 ${_draft.length} 个文件',
                  style: const TextStyle(color: Colors.black38, fontSize: 13),
                ),
              ),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor:
                      _draft.isEmpty ? Colors.black12 : _accent,
                ),
                icon: const Icon(Icons.send, size: 18),
                onPressed:
                    _draft.isEmpty ? null : () => _sendDraft(deviceIndex),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
