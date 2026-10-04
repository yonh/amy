import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_api.dart';
import 'discovery.dart';
import 'files.dart' as files;
import 'identity.dart';
import 'models.dart';
import 'protocol.dart';
import 'server.dart';
import 'store.dart';

class _OutgoingSend {
  _OutgoingSend({required this.peer, required this.message});

  final Peer peer;
  final TransferMessage message;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  String? sessionId;
  bool cancelled = false;
}

/// Orchestrates discovery, the inbound HTTP server, outbound transfers and
/// history. UI watches this (ChangeNotifier) plus [peersStream].
class TransferEngine extends ChangeNotifier {
  TransferEngine({required this.identity});

  final SelfIdentity identity;

  late final DiscoveryService discovery;
  late final AmyServer server;
  HistoryStore? _store;
  Directory? _downloads;

  /// peerFingerprint -> messages, oldest first; same map object as
  /// [_store].threads so mutations are what scheduleSave serializes.
  Map<String, List<TransferMessage>> threads = {};

  /// Scheduled sends; the same list object as [_store].plans so additions
  /// are persisted by scheduleSave.
  List<SendPlan> plans = [];
  final _outgoing = <String, _OutgoingSend>{};
  final _watchdogs = <String, Timer>{};
  Timer? _planTimer;

  bool ready = false;
  String? lastError;

  Stream<Map<String, Peer>> get peersStream => discovery.peersStream;
  Map<String, Peer> get peers => discovery.peers;

  Future<void> init() async {
    _downloads = await files.downloadsDir();
    _store = await HistoryStore.load();
    threads = _store!.threads;
    plans = _store!.plans;

    discovery = DiscoveryService(identity: identity);
    discovery.restorePeers(_store!.peers);
    server = AmyServer(
      identity: identity,
      onPrepare: _handlePrepare,
      onSavePath: _savePathFor,
      onUploadProgress: _uploadProgress,
      onUploadDone: _uploadDone,
      onSessionEnd: _sessionEnd,
      onPeerInfo: _peerFromInfo,
      onAgent: AgentApi(this).handle,
    );
    identity.port = await server.start();
    await discovery.start();
    unawaited(_writeAgentEndpoint());
    unawaited(files.pruneStaging());
    _planTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _tickPlans();
    });
    ready = true;
    notifyListeners();
  }

  /// Publishes the bound port + identity where local tools (amy_cli,
  /// amy_mcp) can find them without probing.
  Future<void> _writeAgentEndpoint() async {
    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'];
      if (home == null) return;
      final dir = Directory('$home/.amy');
      await dir.create(recursive: true);
      await File('${dir.path}/endpoint.json').writeAsString(jsonEncode({
        'port': identity.port,
        ...identity.infoJson(),
      }));
    } catch (_) {}
  }

  Directory get downloads => _downloads!;

  List<TransferMessage> threadFor(String peerId) =>
      threads[peerId] ?? const [];

  /// A peer we have messages with but is not in the discovery map right now.
  Peer? storedPeer(String fingerprint) {
    for (final p in _store?.peers ?? const <Peer>[]) {
      if (p.fingerprint == fingerprint) return p;
    }
    return null;
  }

  void _addMessage(TransferMessage m) {
    threads.putIfAbsent(m.peerId, () => []).add(m);
    _store?.scheduleSave();
    notifyListeners();
  }

  void _persist() {
    _store?.scheduleSave();
    notifyListeners();
  }

  // ------------------------------------------------------------------ send

  /// Queues a message of files to [peer]. Files must have [TransferFile.path]
  /// set to a readable local file. Returns the created message.
  Future<TransferMessage> sendFiles(
      Peer peer, List<TransferFile> picked) async {
    final msg = TransferMessage(
      id: randomId(),
      peerId: peer.fingerprint,
      outgoing: true,
      files: picked,
      status: MessageStatus.waitingApproval,
    );
    _addMessage(msg);
    final send = _OutgoingSend(peer: peer, message: msg);
    _outgoing[msg.id] = send;
    unawaited(_runSend(send));
    return msg;
  }

  // ------------------------------------------------------------------ plans

  /// Schedules a send: at [runAt] (null = the next time the peer is online).
  /// The plan stays pending if the peer is offline when due.
  SendPlan createPlan(Peer peer, List<String> filePaths, {DateTime? runAt}) {
    final p = SendPlan(
      id: randomId(),
      peerFingerprint: peer.fingerprint,
      peerAlias: peer.alias,
      filePaths: List.of(filePaths),
      runAt: runAt,
    );
    plans.add(p);
    _persist();
    _tickPlans();
    return p;
  }

  void cancelPlan(String id) {
    for (final p in plans) {
      if (p.id == id &&
          (p.status == PlanStatus.pending || p.status == PlanStatus.running)) {
        p.status = PlanStatus.cancelled;
      }
    }
    _persist();
  }

  void _tickPlans() {
    final now = DateTime.now();
    var dirty = false;
    for (final p in plans) {
      if (p.status == PlanStatus.running) {
        final m = p.messageId == null ? null : _findMessage(p.messageId!);
        if (m == null || m.terminal) {
          p.status = m != null && m.status == MessageStatus.done
              ? PlanStatus.done
              : PlanStatus.failed;
          if (m != null) p.error ??= m.error;
          dirty = true;
        }
        continue;
      }
      if (p.status != PlanStatus.pending) continue;
      if (p.runAt != null && now.isBefore(p.runAt!)) continue;
      final peer = peers[p.peerFingerprint];
      if (peer == null || !peer.online) continue;
      final missing =
          p.filePaths.where((x) => !File(x).existsSync()).toList();
      if (missing.isNotEmpty) {
        p.status = PlanStatus.failed;
        p.error = '文件不存在: ${missing.first}';
        dirty = true;
        continue;
      }
      p.status = PlanStatus.running;
      p.peerAlias = peer.alias;
      final files = [
        for (final x in p.filePaths)
          TransferFile(
            id: randomId(),
            name: x.split(Platform.pathSeparator).last,
            size: File(x).lengthSync(),
            path: x,
          ),
      ];
      unawaited(
        sendFiles(peer, files).then((m) {
          p.messageId = m.id;
          _persist();
        }),
      );
      dirty = true;
    }
    if (dirty) _persist();
  }

  // ------------------------------------------------------------ agent hooks

  /// Finds a peer by fingerprint (full or prefix) or alias (exact, then
  /// substring, case-insensitive). Online peers take precedence.
  Peer? resolvePeer(String key) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return null;
    final all = [...peers.values, ...?_store?.peers];
    for (final p in all) {
      if (p.fingerprint == key || p.fingerprint.startsWith(k)) return p;
    }
    for (final p in all) {
      if (p.alias.toLowerCase() == k) return p;
    }
    for (final p in all) {
      if (p.alias.toLowerCase().contains(k)) return p;
    }
    return null;
  }

  TransferMessage? messageById(String id) => _findMessage(id);

  /// Incoming offers still waiting for the user's answer.
  List<TransferMessage> get pendingOffers => [
        for (final list in threads.values)
          ...list.where((m) => !m.outgoing && m.status == MessageStatus.offered),
      ];

  Future<void> _runSend(_OutgoingSend send) async {
    final msg = send.message;
    final peer = send.peer;
    try {
      final prepareBody = jsonEncode({
        'from': identity.infoJson(),
        'files': [
          for (final f in msg.files)
            {'id': f.id, 'name': f.name, 'size': f.size, 'mime': f.mime},
        ],
      });
      final req = await send.client
          .postUrl(peer.baseUri.replace(path: kPreparePath))
          .timeout(const Duration(seconds: 6));
      req.headers.contentType = ContentType.json;
      req.write(prepareBody);
      final res = await req.close().timeout(kOfferClientTimeout);
      final body = await utf8.decodeStream(res);
      if (send.cancelled) return;
      if (res.statusCode != 200) {
        msg.status = MessageStatus.declined;
        _persist();
        return;
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      send.sessionId = j['sessionId'] as String;
      final tokens = (j['files'] as Map).cast<String, String>();
      msg.status = MessageStatus.active;
      _persist();

      for (final f in msg.files) {
        if (send.cancelled) break;
        final token = tokens[f.id];
        if (token == null) {
          f.status = FileStatus.skipped;
          continue;
        }
        await _sendOne(send, f, token);
        if (f.status != FileStatus.done && !send.cancelled) {
          throw HttpException('upload failed for ${f.name}');
        }
      }
      if (!send.cancelled) {
        msg.status = MessageStatus.done;
      }
    } on TimeoutException {
      if (!send.cancelled) {
        msg.status = MessageStatus.failed;
        msg.error = '连接超时';
      }
    } catch (e) {
      if (!send.cancelled) {
        msg.status = MessageStatus.failed;
        msg.error = '$e';
      }
    } finally {
      send.client.close(force: true);
      _outgoing.remove(msg.id);
      _persist();
    }
  }

  Future<void> _sendOne(
    _OutgoingSend send,
    TransferFile f,
    String token,
  ) async {
    final file = File(f.path!);
    f.status = FileStatus.sending;
    notifyListeners();

    final uri = send.peer.baseUri.replace(
      path: kUploadPath,
      queryParameters: {
        'sessionId': send.sessionId!,
        'fileId': f.id,
        'token': token,
      },
    );
    final req = await send.client.postUrl(uri);
    req.headers.contentType = ContentType.binary;
    req.contentLength = f.size;

    var sent = 0;
    var lastTick = 0;
    final stream = file.openRead().map((chunk) {
      sent += chunk.length;
      f.progress = (sent / f.size).clamp(0, 1);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastTick > 80) {
        lastTick = now;
        notifyListeners();
      }
      return chunk;
    });
    await req.addStream(stream);
    if (send.cancelled) return;
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode != 200) {
      f.status = FileStatus.failed;
      throw HttpException('status ${res.statusCode}');
    }
    f.status = FileStatus.done;
    f.progress = 1;
    notifyListeners();
  }

  // --------------------------------------------------------------- receive

  Peer _peerFromInfo(Map<String, dynamic> info, InternetAddress remote) {
    return discovery.learnPeer(info, remote.address);
  }

  /// Called by the server when a peer offers files. Creates the incoming
  /// message and returns the session whose decision the server awaits.
  Future<IncomingSession> _handlePrepare(
    Peer from,
    Map<String, TransferFile> offered,
  ) async {
    final session = IncomingSession(
      id: randomId(),
      files: Map.of(offered),
    );
    final msg = TransferMessage(
      id: session.id,
      peerId: from.fingerprint,
      outgoing: false,
      files: session.files.values.toList(),
      status: MessageStatus.offered,
    );
    _addMessage(msg);

    // If the sender aborts while waiting (or the network dies), the bubble
    // must not linger — auto-cancel a bit past the client-side timeout.
    _watchdogs[session.id] = Timer(
      kOfferClientTimeout + const Duration(seconds: 5),
      () {
        if (!msg.terminal && msg.status != MessageStatus.active) {
          session.cancelled = true;
          if (!session.decision.isCompleted) {
            session.decision.complete(false);
          }
          msg.status = MessageStatus.cancelled;
          msg.error = '对方已取消';
          _persist();
        }
      },
    );
    return session;
  }

  /// User answered an incoming offer.
  void answerOffer(String messageId, bool accept) {
    final session = server.sessions[messageId];
    final msg = _findMessage(messageId);
    if (session == null || msg == null) return;
    _watchdogs.remove(messageId)?.cancel();
    if (!accept) {
      msg.status = MessageStatus.declined;
      session.cancelled = true;
      if (!session.decision.isCompleted) session.decision.complete(false);
      _persist();
      return;
    }
    msg.status = MessageStatus.active;
    if (!session.decision.isCompleted) session.decision.complete(true);
    // Stall watchdog: if the sender never starts uploading after we accepted,
    // something died between approve and upload.
    _watchdogs[messageId] = Timer(const Duration(seconds: 20), () {
      final anyStarted = msg.files.any(
        (f) => f.status == FileStatus.receiving || f.status == FileStatus.done,
      );
      if (!anyStarted && !msg.terminal) {
        msg.status = MessageStatus.cancelled;
        msg.error = '对方已取消';
        session.cancelled = true;
        _persist();
      }
    });
    _persist();
  }

  /// Cancels a message from whichever side we are:
  ///  * outgoing waiting/active → abort connections, mark cancelled
  ///  * incoming offered/active  → decline/cancel the server session
  void cancelMessage(TransferMessage msg) {
    if (msg.outgoing) {
      final send = _outgoing[msg.id];
      msg.status = MessageStatus.cancelled;
      if (send != null) {
        send.cancelled = true;
        send.client.close(force: true);
        _outgoing.remove(msg.id);
      }
    } else {
      final session = server.sessions[msg.id];
      msg.status = MessageStatus.cancelled;
      if (session != null) {
        session.cancelled = true;
        if (!session.decision.isCompleted) session.decision.complete(false);
        server.sessions.remove(msg.id);
      }
      // Tell the sender so its bubble flips to cancelled too. The session
      // id is the same on both sides (receiver created it at prepare time).
      final peer = peers[msg.peerId];
      if (peer != null) {
        unawaited(
          HttpClient()
              .postUrl(peer.baseUri.replace(
                path: kCancelPath,
                queryParameters: {'sessionId': msg.id},
              ))
              .then((r) => r.close())
              .then((r) => r.drain<void>())
              .catchError((_) {}),
        );
      }
    }
    _watchdogs.remove(msg.id)?.cancel();
    _persist();
  }

  Future<String> _savePathFor(IncomingSession s, TransferFile f) async {
    final dir = await files.downloadsDir();
    return files.dedupePath(dir.path, files.sanitizeFileName(f.name));
  }

  void _uploadProgress(IncomingSession s, String fileId, int received) {
    final msg = _findMessage(s.id);
    final f = s.files[fileId];
    if (msg == null || f == null) return;
    f.status = FileStatus.receiving;
    f.progress = f.size == 0 ? 1 : (received / f.size).clamp(0, 1);
    msg.status = MessageStatus.active;
    notifyListeners();
  }

  void _uploadDone(IncomingSession s, String fileId, String savedTo) {
    final msg = _findMessage(s.id);
    final f = s.files[fileId];
    if (f == null) return;
    if (savedTo.isEmpty) {
      f.status = FileStatus.failed;
    } else {
      f.status = FileStatus.done;
      f.progress = 1;
      f.path = savedTo;
    }
    final allDone = s.files.values.every(
      (x) => x.status == FileStatus.done || x.status == FileStatus.failed,
    );
    if (allDone && msg != null) {
      final anyOk = s.files.values.any((x) => x.status == FileStatus.done);
      msg.status = anyOk ? MessageStatus.done : MessageStatus.failed;
      _watchdogs.remove(s.id)?.cancel();
      server.sessions.remove(s.id);
    }
    _persist();
  }

  void _sessionEnd(IncomingSession s, String reason) {
    _watchdogs.remove(s.id)?.cancel();
    final msg = _findMessage(s.id);
    if (msg != null && !msg.terminal) {
      msg.status = reason == 'cancelled'
          ? MessageStatus.cancelled
          : MessageStatus.declined;
      _persist();
    }
  }

  TransferMessage? _findMessage(String id) {
    for (final list in threads.values) {
      for (final m in list) {
        if (m.id == id) return m;
      }
    }
    return null;
  }

  void removeMessage(TransferMessage msg) {
    threads[msg.peerId]?.remove(msg);
    _persist();
  }

  void clearThread(String peerId) {
    threads[peerId]?.clear();
    _persist();
  }

  /// Remembers a peer for the device list even after it goes offline.
  void pinPeer(Peer p) {
    p.pinned = true;
    final stored = _store?.peers;
    if (stored != null &&
        !stored.any((x) => x.fingerprint == p.fingerprint)) {
      stored.add(p);
    }
    _store?.scheduleSave();
    notifyListeners();
  }

  void unpinPeer(Peer p) {
    p.pinned = false;
    _store?.peers.removeWhere((x) => x.fingerprint == p.fingerprint);
    _store?.scheduleSave();
    notifyListeners();
  }

  /// Sets or clears a peer's custom avatar emoji (null restores the
  /// platform/brand icon). Persisted so the choice survives restarts and
  /// merges back onto the discovered peer via restorePeers.
  void customizePeer(Peer p, {String? iconEmoji}) {
    p.iconEmoji = (iconEmoji != null && iconEmoji.isEmpty) ? null : iconEmoji;
    final stored = _store?.peers;
    if (stored != null &&
        !stored.any((x) => x.fingerprint == p.fingerprint)) {
      stored.add(p);
    }
    _store?.scheduleSave();
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _planTimer?.cancel();
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    for (final s in _outgoing.values) {
      s.client.close(force: true);
    }
    await _store?.flush();
    await discovery.dispose();
    await server.dispose();
    super.dispose();
  }
}
