import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'identity.dart';
import 'models.dart';
import 'protocol.dart';

/// Finds other amy devices. Three complementary mechanisms:
///  * bonsoir broadcast + discovery (Bonjour on Apple, NSD on Android)
///  * periodic HTTP scan of the local /24 subnets (works where multicast is
///    filtered, e.g. iOS without the multicast entitlement, enterprise Wi-Fi)
///  * explicit connects: 6-digit code match, scanned QR, or typed host:port
class DiscoveryService {
  DiscoveryService({required this.identity});

  final SelfIdentity identity;

  final _peers = <String, Peer>{};
  final _peersController = StreamController<Map<String, Peer>>.broadcast();
  /// Pending code-connect: the code we are currently asking peers to verify.
  String? _pendingVerifyCode;
  Completer<Peer?>? _pendingCodeCompleter;
  int _scanCycle = 0;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 4);

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  Timer? _scanTimer;
  bool _scanning = false;
  bool _started = false;

  /// First non-loopback IPv4 address — used for QR/manual connect hints.
  static Future<String?> primaryIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.address.startsWith('127.')) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Map<String, Peer> get peers => Map.unmodifiable(_peers);

  Stream<Map<String, Peer>> get peersStream => _peersController.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _startBonsoir();
    // Scan once soon, then periodically — cheap and catches peers mDNS misses.
    unawaited(Future.delayed(const Duration(seconds: 2), scanLocalSubnets));
    _scanTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(scanLocalSubnets());
    });
  }

  Future<void> _startBonsoir() async {
    try {
      _broadcast = BonsoirBroadcast(
        service: BonsoirService(
          name: identity.alias,
          type: kBonsoirType,
          port: identity.port,
          attributes: {
            'fp': identity.fingerprint,
            'pf': platformName(identity.platform),
            'model': identity.model,
            'alias': identity.alias,
          },
        ),
      );
      await _broadcast!.initialize();
      await _broadcast!.start();
    } catch (_) {
      _broadcast = null;
    }

    try {
      _discovery = BonsoirDiscovery(type: kBonsoirType);
      await _discovery!.initialize();
      _discovery!.eventStream!.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(service: final s):
            _discovery!.serviceResolver.resolveService(s);
          case BonsoirDiscoveryServiceResolvedEvent(service: final s):
            unawaited(_handleResolved(s));
          case BonsoirDiscoveryServiceUpdatedEvent(service: final s):
            unawaited(_handleResolved(s));
          case BonsoirDiscoveryServiceLostEvent(service: final s):
            _markGone(s);
          default:
        }
      });
      await _discovery!.start();
    } catch (_) {
      _discovery = null;
    }
  }

  Future<void> _handleResolved(BonsoirService service) async {
    final attrs = service.attributes;
    final fp = attrs['fp'];
    if (fp == null || fp == identity.fingerprint) return;
    final host = service.hostAddresses
        .cast<String?>()
        .firstWhere((a) => a != null && !a.contains(':'), orElse: () => null);
    if (host == null || host.isEmpty) return;
    final peer = _upsert(
      fingerprint: fp,
      alias: attrs['alias'] ?? service.name,
      platform: platformFromName(attrs['pf']),
      model: attrs['model'] ?? '',
      host: host,
      port: service.port,
    );
    unawaited(_checkPendingCode(peer));
  }

  void _markGone(BonsoirService service) {
    final fp = service.attributes['fp'];
    if (fp == null) return;
    final peer = _peers[fp];
    if (peer == null) return;
    peer.lastSeen = DateTime.now().subtract(const Duration(minutes: 10));
    _peersController.add(Map.of(_peers));
  }

  Peer _upsert({
    required String fingerprint,
    required String alias,
    required DevicePlatform platform,
    required String model,
    required String host,
    required int port,
  }) {
    final existing = _peers[fingerprint];
    final peer = existing ??
        Peer(
          fingerprint: fingerprint,
          alias: alias,
          platform: platform,
          model: model,
          host: host,
          port: port,
        );
    peer
      ..alias = alias.isNotEmpty ? alias : peer.alias
      ..platform = platform
      ..model = model
      ..host = host
      ..port = port
      ..lastSeen = DateTime.now();
    _peers[fingerprint] = peer;
    _peersController.add(Map.of(_peers));
    return peer;
  }

  /// If a code-connect is in flight, ask this (re)discovered peer whether it
  /// owns the pending code; completes the pending connect on a match.
  /// Fingerprints currently being asked about the pending code — keeps a
  /// concurrent second verification of the same peer from completing the
  /// shared completer twice.
  final _codeChecksInFlight = <String>{};

  Future<void> _checkPendingCode(Peer peer) async {
    final code = _pendingVerifyCode;
    final completer = _pendingCodeCompleter;
    if (code == null || completer == null || completer.isCompleted) return;
    if (!_codeChecksInFlight.add(peer.fingerprint)) return;
    try {
      if (await _verifyCode(peer, code)) {
        _pendingVerifyCode = null;
        _pendingCodeCompleter = null;
        if (!completer.isCompleted) completer.complete(peer);
      }
    } finally {
      _codeChecksInFlight.remove(peer.fingerprint);
    }
  }

  /// Re-checks every known peer at its last-seen host:port so lastSeen
  /// stays fresh while the device is still reachable (mDNS does not
  /// periodically re-resolve).
  Future<void> _revalidateKnown() async {
    final jobs = [
      for (final p in _peers.values)
        _probe(p.host, p.port).then((found) {
          // Nothing to do on failure — lastSeen simply ages toward offline.
          return found;
        }),
    ];
    await Future.wait(jobs);
  }

  /// Probes every address on each local /24 for the /info endpoint.
  /// Concurrent, short-timeout; safe to run often. Every fourth pass also
  /// probes the first few alternate ports on hosts that miss the base port —
  /// mDNS can drop out, and a device that could not bind kBasePort would
  /// otherwise never appear.
  Future<void> scanLocalSubnets() async {
    if (_scanning) return;
    _scanning = true;
    try {
      await _revalidateKnown();
      final subnets = await _localSubnets();
      final deep = ++_scanCycle % 4 == 0;
      final jobs = <Future<void>>[];
      for (final prefix in subnets) {
        for (var i = 1; i < 255; i++) {
          jobs.add(_probeHost('$prefix.$i', deep: deep));
          // Keep a bound on in-flight sockets.
          if (jobs.length >= 80) {
            await Future.wait(jobs);
            jobs.clear();
          }
        }
      }
      await Future.wait(jobs);
    } finally {
      _scanning = false;
    }
  }

  /// Probes one host on the base port; on deep sweeps also probes the
  /// first few alternate ports so devices that could not bind 47777 —
  /// or a second instance sitting behind a sibling that did — are
  /// still found without mDNS.
  Future<void> _probeHost(String host, {required bool deep}) async {
    // Probe the base port AND alternates even when the first responds — a
    // host may run two amy instances and the device we want may sit on
    // 47778 while 47777 belongs to another.
    final jobs = <Future<Peer?>>[_probe(host)];
    if (deep) {
      for (var off = 1; off <= 3; off++) {
        jobs.add(_probe(host, kBasePort + off));
      }
    }
    await Future.wait(jobs);
  }

  Future<Set<String>> _localSubnets() async {
    final prefixes = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4 && !addr.address.startsWith('127.')) {
            prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (_) {}
    return prefixes;
  }

  Future<Peer?> _probe(String host, [int port = kBasePort]) async {
    try {
      final req = await _http
          .getUrl(Uri.parse('http://$host:$port$kInfoPath'))
          .timeout(const Duration(milliseconds: 900));
      final res = await req.close().timeout(const Duration(milliseconds: 900));
      if (res.statusCode != 200) return null;
      final body = await utf8.decodeStream(res);
      final j = jsonDecode(body) as Map<String, dynamic>;
      final fp = j['fingerprint'] as String?;
      if (fp == null || fp == identity.fingerprint) return null;
      final peer = _upsert(
        fingerprint: fp,
        alias: (j['alias'] as String?) ?? '',
        platform: platformFromName(j['platform'] as String?),
        model: (j['model'] as String?) ?? '',
        host: host,
        port: (j['port'] as num?)?.toInt() ?? port,
      );
      unawaited(_checkPendingCode(peer));
      return peer;
    } catch (_) {
      return null;
    }
  }

  /// Connect by the peer's displayed 6-digit code. Matches already-discovered
  /// peers first, then kicks a subnet scan and waits a while for a match.
  /// Connect by the peer's displayed 6-digit code. Codes are never
  /// broadcast — we ask each candidate host to verify it via /verify-code,
  /// so a network observer learns nothing by watching discovery traffic.
  Future<Peer?> connectByCode(String code) async {
    // Fast path: ask each known online peer first (cheap, few requests).
    for (final p in _peers.values.toList()) {
      if (!p.online) continue;
      if (await _verifyCode(p, code)) {
        p.pinned = true;
        _peersController.add(Map.of(_peers));
        return p;
      }
    }
    final completer = Completer<Peer?>();
    _pendingVerifyCode = code;
    _pendingCodeCompleter = completer;
    unawaited(scanLocalSubnets());
    final peer = await completer.future
        .timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (_pendingVerifyCode == code) {
      _pendingVerifyCode = null;
      _pendingCodeCompleter = null;
    }
    if (peer != null) {
      peer.pinned = true;
      _peersController.add(Map.of(_peers));
    }
    return peer;
  }

  /// POSTs /verify-code — 200 iff the remote device currently shows [code].
  Future<bool> _verifyCode(Peer p, String code) async {
    try {
      final req = await _http
          .postUrl(p.baseUri.replace(path: kVerifyCodePath))
          .timeout(const Duration(milliseconds: 900));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'code': code}));
      final res = await req.close()
          .timeout(const Duration(milliseconds: 1200));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Connect directly to host[:port] — used by QR codes and manual entry.
  /// Validates that the remote end is actually amy before adding it.
  Future<Peer?> connectDirect(String host, [int? port]) async {
    final peer = await _probe(host, port ?? kBasePort);
    if (peer != null) {
      peer.pinned = true;
      _peersController.add(Map.of(_peers));
    }
    return peer;
  }

  /// Registers/updates a peer discovered out-of-band — e.g. the sender info
  /// attached to an inbound /prepare-upload, whose remote address we trust.
  Peer learnPeer(Map<String, dynamic> info, String host) {
    final fp = info['fingerprint'] as String? ?? 'unknown-$host';
    return _upsert(
      fingerprint: fp,
      alias: (info['alias'] as String?) ?? '设备',
      platform: platformFromName(info['platform'] as String?),
      model: (info['model'] as String?) ?? '',
      host: host,
      port: (info['port'] as num?)?.toInt() ?? kBasePort,
    );
  }

  /// Loads persisted peers (saved by the store) at startup.
  void restorePeers(Iterable<Peer> saved) {
    for (final p in saved) {
      _peers[p.fingerprint] = p;
    }
    _peersController.add(Map.of(_peers));
  }

  Future<void> dispose() async {
    _scanTimer?.cancel();
    try {
      await _broadcast?.stop();
    } catch (_) {}
    try {
      await _discovery?.stop();
    } catch (_) {}
    _http.close();
    await _peersController.close();
  }
}
