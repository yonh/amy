import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/discovery.dart';
import '../core/models.dart';
import '../state/providers.dart';
import 'session_screen.dart';
import 'theme.dart';

/// The "用代码连接" sheet from variant D, made real:
///  * shows this device's rotating 6-digit code + QR (peer scans to connect)
///  * enter the peer's code → matches whichever discovered device advertises it
///  * scan the peer's QR (mobile) or type host:port directly
Future<void> showConnectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => const ConnectSheet(),
  );
}

class ConnectSheet extends ConsumerStatefulWidget {
  const ConnectSheet({super.key});

  @override
  ConsumerState<ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends ConsumerState<ConnectSheet> {
  final _codeCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  String? _myIp;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DiscoveryService.primaryIpv4().then((ip) {
      if (mounted) setState(() => _myIp = ip);
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Peer?> Function() connect) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final peer = await connect();
    if (!mounted) return;
    setState(() => _busy = false);
    if (peer == null) {
      setState(() => _error = '没找到对应设备，确认两台设备在同一网络后重试');
      return;
    }
    ref.read(engineProvider).pinPeer(peer);
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SessionScreen(peer: peer)),
    );
  }

  void _connectCode() =>
      _run(() => ref.read(engineProvider).discovery.connectByCode(_codeCtrl.text.trim()));

  void _connectHost() {
    final text = _hostCtrl.text.trim();
    if (text.isEmpty) return;
    var host = text;
    var port = 0;
    if (text.contains(':')) {
      final parts = text.split(':');
      host = parts.first;
      port = int.tryParse(parts.last) ?? 0;
    }
    _run(() => ref
        .read(engineProvider)
        .discovery
        .connectDirect(host, port == 0 ? null : port));
  }

  void _scanQr() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _QrScanPage(
          onResult: (uri) {
            final host = uri.queryParameters['ip'] ?? uri.host;
            final port = uri.queryParameters['port'];
            Navigator.of(context).pop();
            _run(() => ref
                .read(engineProvider)
                .discovery
                .connectDirect(host, int.tryParse(port ?? '')));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
    final mobile = Platform.isIOS || Platform.isAndroid;
    final qrData = _myIp == null
        ? null
        : 'amy://connect?ip=$_myIp&port=${identity.port}&fp=${identity.fingerprint}';

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
            const Text('连接新设备',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '附近的设备会自动出现在上方列表；跨网段时用代码、扫码或直连',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AmyTheme.bubbleMe,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('本机代码',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                        Text(
                          identity.code,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 6,
                            color: AmyTheme.accent,
                          ),
                        ),
                        Text(
                          '${identity.alias} · ${_myIp ?? "…"}:${identity.port}',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  if (qrData != null)
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(6),
                      child: QrImageView(
                        data: qrData,
                        size: 88,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _codeCtrl,
              decoration: InputDecoration(
                hintText: '输入对方显示的 6 位代码',
                prefixIcon: const Icon(Icons.tag),
                errorText: _error,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                counterText: '',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              onSubmitted: (_) => _connectCode(),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AmyTheme.accent),
              onPressed: _busy ? null : _connectCode,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.link),
              label: const Text('用代码连接'),
            ),
            if (mobile) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码连接'),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _hostCtrl,
              decoration: InputDecoration(
                hintText: '或输入 IP[:端口]，如 192.168.1.8:47777',
                prefixIcon: const Icon(Icons.dns_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _connectHost(),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _connectHost,
              icon: const Icon(Icons.cable),
              label: const Text('直连'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrScanPage extends StatelessWidget {
  const _QrScanPage({required this.onResult});

  final void Function(Uri uri) onResult;

  @override
  Widget build(BuildContext context) {
    var done = false;
    return Scaffold(
      appBar: AppBar(title: const Text('扫码连接')),
      body: MobileScanner(
        onDetect: (capture) {
          if (done) return;
          for (final code in capture.barcodes) {
            final raw = code.rawValue;
            if (raw == null) continue;
            final uri = Uri.tryParse(raw);
            if (uri != null && uri.scheme == 'amy') {
              done = true;
              onResult(uri);
              return;
            }
          }
        },
      ),
    );
  }
}
