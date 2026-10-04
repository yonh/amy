// PROTOTYPE — Variant B「配对码」: Send Anywhere / Snapdrop 式。
// 模型：一次性事务。没有常驻的"设备列表"，每趟传输
// 由一组 6 位码（或扫码）撮合，连上即传，传完即散。
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';

class VariantB extends StatefulWidget {
  const VariantB({super.key});

  @override
  State<VariantB> createState() => _VariantBState();
}

enum _SendStep { pick, code, active, done }
enum _RecvStep { input, connecting, offer, active, done }

class _VariantBState extends State<VariantB> {
  static const _bg = Color(0xFF0D1117);
  static const _panel = Color(0xFF161B22);
  static const _edge = Color(0xFF30363D);
  static const _accent = Color(0xFF39D0D8);
  static const _dim = Color(0xFF8B949E);

  bool _sending = true;

  // send side
  final _files = <ProtoFile>[];
  _SendStep _sendStep = _SendStep.pick;
  String _code = '';
  String? _peer;
  double _sendProgress = 0;

  // recv side
  final _codeCtrl = TextEditingController();
  _RecvStep _recvStep = _RecvStep.input;
  double _recvProgress = 0;

  final _timers = <Timer>[];

  static const _recent = [
    ('iPhone → 本机', 'IMG_1990.heic ×2 · 7.8 MB', '昨天'),
    ('本机 → Windows PC', '季度报告.pdf · 2.3 MB', '昨天'),
  ];

  @override
  void dispose() {
    _codeCtrl.dispose();
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

  void _pickFiles() {
    final picked = _files.toSet();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('选择要发送的文件',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
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
                        secondary: Icon(iconForFileKind(f.kind), color: _dim),
                        title: Text(f.name,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(fmtBytes(f.bytes),
                            style: const TextStyle(color: _dim)),
                        activeColor: _accent,
                        checkColor: _bg,
                        side: const BorderSide(color: _edge),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: _accent, foregroundColor: _bg),
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

  void _generateCode() {
    final r = Random();
    setState(() {
      _code = List.generate(6, (_) => r.nextInt(10)).join();
      _sendStep = _SendStep.code;
      _peer = null;
    });
    // Simulate a peer typing the code on their device after a beat.
    _later(const Duration(milliseconds: 2800), () {
      _peer = 'houmu 的 iPhone';
      _sendStep = _SendStep.active;
    });
    _later(const Duration(milliseconds: 3400), () {
      _timers.add(
        fakeTransfer(
          onProgress: (p) {
            if (mounted) setState(() => _sendProgress = p);
          },
          onDone: () {
            if (mounted) setState(() => _sendStep = _SendStep.done);
          },
        ),
      );
    });
  }

  void _connect() {
    setState(() => _recvStep = _RecvStep.connecting);
    _later(const Duration(milliseconds: 1300), () {
      _recvStep = _RecvStep.offer;
    });
  }

  void _acceptIncoming() {
    setState(() => _recvStep = _RecvStep.active);
    _timers.add(
      fakeTransfer(
        onProgress: (p) {
          if (mounted) setState(() => _recvProgress = p);
        },
        onDone: () {
          if (mounted) setState(() => _recvStep = _RecvStep.done);
        },
      ),
    );
  }

  void _reset() {
    setState(() {
      _sendStep = _SendStep.pick;
      _recvStep = _RecvStep.input;
      _files.clear();
      _code = '';
      _peer = null;
      _sendProgress = 0;
      _recvProgress = 0;
      _codeCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
              children: [
                _header(),
                const SizedBox(height: 20),
                _modeToggle(),
                const SizedBox(height: 28),
                _sending ? _sendFlow() : _recvFlow(),
                const SizedBox(height: 36),
                _recentStrip(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Text(
          'AMY',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 6,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: _edge),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: Color(0xFF3FB950)),
              SizedBox(width: 6),
              Text('Amy 的 Mac mini',
                  style: TextStyle(color: _dim, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modeToggle() {
    Widget seg(String label, bool active, VoidCallback onTap) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: active ? _accent : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active ? _bg : _dim,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _edge),
      ),
      child: Row(
        children: [
          seg('发送', _sending, () => setState(() => _sending = true)),
          seg('接收', !_sending, () => setState(() => _sending = false)),
        ],
      ),
    );
  }

  // ---- send flow ----

  Widget _sendFlow() {
    return switch (_sendStep) {
      _SendStep.pick => _sendPick(),
      _SendStep.code => _sendCode(),
      _SendStep.active => _progressView(
          title: '正在发送到 $_peer',
          progress: _sendProgress,
          files: _files,
        ),
      _SendStep.done => _doneView('传输完成', _files),
    };
  }

  Widget _sendPick() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panelBox(
          child: Column(
            children: [
              if (_files.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Text('还没有选择文件', style: TextStyle(color: _dim)),
                )
              else
                for (final f in _files)
                  ListTile(
                    dense: true,
                    leading: Icon(iconForFileKind(f.kind), color: _dim),
                    title:
                        Text(f.name, style: const TextStyle(color: Colors.white)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(fmtBytes(f.bytes),
                            style: const TextStyle(color: _dim, fontSize: 12)),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16, color: _dim),
                          onPressed: () => setState(() => _files.remove(f)),
                        ),
                      ],
                    ),
                  ),
              const Divider(color: _edge, height: 1),
              TextButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.add, color: _accent),
                label: const Text('添加文件', style: TextStyle(color: _accent)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _files.isEmpty ? _panel : _accent,
            foregroundColor: _files.isEmpty ? _dim : _bg,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: _files.isEmpty ? null : _generateCode,
          child: const Text('生成配对码',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _sendCode() {
    return Column(
      children: [
        const Text('让接收方输入这组代码', style: TextStyle(color: _dim)),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 6; i++)
              Container(
                width: 44,
                height: 56,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _panel,
                  border: Border.all(color: _edge),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _code[i],
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          width: 132,
          height: 132,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: CustomPaint(painter: _FakeQrPainter()),
        ),
        const SizedBox(height: 8),
        const Text('或扫码连接', style: TextStyle(color: _dim, fontSize: 12)),
        const SizedBox(height: 24),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: _accent),
            ),
            SizedBox(width: 10),
            Text('等待对方输入代码…', style: TextStyle(color: _dim)),
          ],
        ),
      ],
    );
  }

  // ---- recv flow ----

  Widget _recvFlow() {
    return switch (_recvStep) {
      _RecvStep.input || _RecvStep.connecting => _recvInput(),
      _RecvStep.offer => _recvOffer(),
      _RecvStep.active => _progressView(
          title: '正在从 houmu 的 iPhone 接收',
          progress: _recvProgress,
          files: const [
            ProtoFile('IMG_2041.heic', 4200000, kind: ProtoFileKind.image),
            ProtoFile('IMG_2042.heic', 3900000, kind: ProtoFileKind.image),
          ],
        ),
      _RecvStep.done => _doneView('接收完成', const [
          ProtoFile('IMG_2041.heic', 4200000, kind: ProtoFileKind.image),
          ProtoFile('IMG_2042.heic', 3900000, kind: ProtoFileKind.image),
        ]),
    };
  }

  Widget _recvInput() {
    final connecting = _recvStep == _RecvStep.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('输入发送方屏幕上的 6 位代码',
            style: TextStyle(color: _dim), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextField(
          controller: _codeCtrl,
          enabled: !connecting,
          maxLength: 6,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            color: _accent,
            fontSize: 32,
            letterSpacing: 18,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
          cursorColor: _accent,
          decoration: InputDecoration(
            counterText: '',
            hintText: '------',
            hintStyle: TextStyle(
                color: _dim.withValues(alpha: 0.4), letterSpacing: 18),
            filled: true,
            fillColor: _panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _edge),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _edge),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _accent),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor:
                _codeCtrl.text.length == 6 ? _accent : _panel,
            foregroundColor:
                _codeCtrl.text.length == 6 ? _bg : _dim,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed:
              _codeCtrl.text.length == 6 && !connecting ? _connect : null,
          child: connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _dim))
              : const Text('连接', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _recvOffer() {
    const files = [
      ProtoFile('IMG_2041.heic', 4200000, kind: ProtoFileKind.image),
      ProtoFile('IMG_2042.heic', 3900000, kind: ProtoFileKind.image),
    ];
    return _panelBox(
      child: Column(
        children: [
          const Icon(Icons.phone_iphone, color: Colors.white, size: 36),
          const SizedBox(height: 10),
          const Text('houmu 的 iPhone 想要发送文件',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('${files.length} 个文件 · ${fmtBytes(totalBytes(files))}',
              style: const TextStyle(color: _dim, fontSize: 13)),
          const SizedBox(height: 14),
          for (final f in files)
            ListTile(
              dense: true,
              leading: Icon(iconForFileKind(f.kind), color: _dim),
              title: Text(f.name, style: const TextStyle(color: Colors.white)),
              trailing: Text(fmtBytes(f.bytes),
                  style: const TextStyle(color: _dim, fontSize: 12)),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _dim,
                      side: const BorderSide(color: _edge)),
                  onPressed: _reset,
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: _accent, foregroundColor: _bg),
                  onPressed: _acceptIncoming,
                  child: const Text('接受',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- shared bits ----

  Widget _progressView({
    required String title,
    required double progress,
    required List<ProtoFile> files,
  }) {
    return _panelBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: _edge,
              valueColor: const AlwaysStoppedAnimation(_accent),
            ),
          ),
          const SizedBox(height: 8),
          Text('${(progress * 100).round()}%',
              style: const TextStyle(color: _accent, fontFamily: 'monospace')),
          const SizedBox(height: 10),
          for (final f in files)
            Text('${f.name} · ${fmtBytes(f.bytes)}',
                style: const TextStyle(color: _dim, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _doneView(String title, List<ProtoFile> files) {
    return Column(
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF3FB950), size: 56),
        const SizedBox(height: 12),
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('${files.length} 个文件 · ${fmtBytes(totalBytes(files))}',
            style: const TextStyle(color: _dim)),
        const SizedBox(height: 20),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              side: const BorderSide(color: _accent)),
          onPressed: _reset,
          child: const Text('再来一趟'),
        ),
      ],
    );
  }

  Widget _recentStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('最近',
            style: TextStyle(
                color: _dim, fontSize: 12, letterSpacing: 1.5)),
        const SizedBox(height: 8),
        for (final r in _recent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('${r.$1}  ·  ${r.$2}',
                      style: const TextStyle(color: _dim, fontSize: 12)),
                ),
                Text(r.$3, style: const TextStyle(color: _edge, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _panelBox({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _edge),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

/// A plausible-looking QR stand-in: deterministic dot grid plus the three
/// finder squares. Nobody scans a prototype anyway.
class _FakeQrPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const n = 21;
    final cell = size.width / n;
    final ink = Paint()..color = const Color(0xFF0D1117);

    void dot(int x, int y) => canvas.drawRect(
        Rect.fromLTWH(x * cell, y * cell, cell, cell), ink);

    void finder(int ox, int oy) {
      for (var x = 0; x < 7; x++) {
        for (var y = 0; y < 7; y++) {
          final ring = x == 0 || x == 6 || y == 0 || y == 6;
          final core = x >= 2 && x <= 4 && y >= 2 && y <= 4;
          if (ring || core) dot(ox + x, oy + y);
        }
      }
    }

    bool inFinder(int x, int y) =>
        (x < 8 && y < 8) || (x >= n - 8 && y < 8) || (x < 8 && y >= n - 8);

    for (var x = 0; x < n; x++) {
      for (var y = 0; y < n; y++) {
        if (inFinder(x, y)) continue;
        if ((x * 31 + y * 17 + x * y * 7) % 4 == 0) dot(x, y);
      }
    }
    finder(0, 0);
    finder(n - 7, 0);
    finder(0, n - 7);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
