import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p2;

import 'agent_api.dart';
import 'ai_brain.dart';
import 'discovery.dart';
import 'files.dart' as files;
import 'identity.dart';
import 'llm.dart';
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
  Map<String, String> tokens = {};
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

  /// sessionId:fileId -> reserved destination path, so two accepted uploads
  /// with the same filename can never pick the same free name.
  final _saveReservations = <String, String>{};

  /// Per-run credential local agents must send as X-Amy-Token. Written into
  /// ~/.amy/endpoint.json where amy_cli/amy_mcp pick it up.
  String get agentToken => _agentToken;
  String _agentToken = '';

  /// AI/agent safety policy (persisted in SharedPreferences).
  AiPolicy aiPolicy = AiPolicy();

  /// Leader-side: member fingerprint -> remote Bearer token.
  Map<String, String> _remoteTokens = {};

  /// Filesystem isolation for agent sends (persisted in SharedPreferences).
  SecurityScope securityScope = SecurityScope();

  /// staged dest path -> the origin path its uploader claimed (via the
  /// `source` param). Staged payloads are opaque, so the scope gate
  /// checks this claim; a staged path with no claim is unverifiable and
  /// counts as out-of-scope. Memory-only: after a restart staged files
  /// revert to unverifiable, which fails closed under strict mode.
  final stagedSources = <String, String>{};

  /// In-app AI assistant endpoint (OpenAI-compatible, persisted).
  LlmConfig llmConfig = LlmConfig();

  /// Natural-language assistant driving the same gated agent paths.
  late final AiBrain brain = AiBrain(this);

  /// Pending AI/agent actions awaiting the user's tap.
  final _approvals = <String, AgentAction>{};

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
    aiPolicy = await loadAiPolicy();
    _remoteTokens = await loadRemoteTokens();
    securityScope = await loadSecurityScopeOrSeed();
    llmConfig = await loadLlmConfig();
    identity.agentCapable = aiPolicy.allowRemoteControl;
    _agentToken = randomId(16);
    unawaited(_writeAgentEndpoint());
    unawaited(files.pruneStaging(keep: {
      for (final p in plans)
        if (p.status == PlanStatus.pending) ...p.filePaths,
    }));
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
      final f = File('${dir.path}/endpoint.json');
      if (!f.existsSync()) await f.create();
      // The file doubles as the agent credential store — restrict it
      // BEFORE the token lands in it so there is no readable window.
      await Process.run('chmod', ['600', f.path]).catchError((_) =>
          ProcessResult(0, 0, '', ''));
      await f.writeAsString(jsonEncode({
        'port': identity.port,
        'token': _agentToken,
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
  SendPlan createPlan(Peer peer, List<String> filePaths,
      {DateTime? runAt, bool agent = false}) {
    final p = SendPlan(
      id: randomId(),
      peerFingerprint: peer.fingerprint,
      peerAlias: peer.alias,
      filePaths: List.of(filePaths),
      runAt: runAt,
      agentCreated: agent,
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
        final wasRunning = p.status == PlanStatus.running;
        p.status = PlanStatus.cancelled;
        // A running plan already dispatched its message — abort it too,
        // otherwise a cancelled plan still delivers its files.
        if (wasRunning) {
          final m = p.messageId == null ? null : _findMessage(p.messageId!);
          if (m != null && !m.terminal) cancelMessage(m);
        }
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
      if (!_dispatchingPlans.add(p.id)) continue;
      dirty = true;
      unawaited(
        _dispatchPlan(p, peer)
            .whenComplete(() => _dispatchingPlans.remove(p.id)),
      );
    }
    if (dirty) _persist();
  }

  /// Plans mid-dispatch (async scope re-check + send kickoff) so the tick
  /// loop doesn't start them twice.
  final _dispatchingPlans = <String>{};

  /// Dispatches a due plan. Agent-created plans are re-validated against
  /// the CURRENT security scope here — the whitelist may have tightened
  /// since the plan was queued. Strict mode fails the plan; otherwise a
  /// confirm card asks the user (AI mode off denies as well).
  Future<void> _dispatchPlan(SendPlan p, Peer peer) async {
    try {
      if (p.agentCreated) {
        // AI mode off kills agent plans outright — a plan queued earlier
        // must not fire after the user switched automation off.
        if (aiPolicy.mode == AiMode.off) {
          p.status = PlanStatus.failed;
          p.error = 'AI 模式已关闭';
          return;
        }
        final denied = <String>[];
        final staging = canonPath((await files.stagingDir()).path) ?? '';
        for (final x in p.filePaths) {
          // Canonicalize first so disguised paths can't dodge the
          // staged check; staged files re-check their recorded origin
          // claim — none means unverifiable and counts as outside.
          final cp = canonPath(x);
          final isStaged = cp != null &&
              staging.isNotEmpty &&
              cp.startsWith('$staging${Platform.pathSeparator}');
          final claimed = cp == null ? null : stagedSources[cp];
          final effective = isStaged ? claimed : cp;
          if (effective == null || !await pathInScope(effective)) {
            denied.add(x.split(Platform.pathSeparator).last);
          }
        }
        final total =
            p.filePaths.fold(0, (s, x) => s + File(x).lengthSync());
        // In auto mode the size cap applies to the ACTUAL dispatch, not
        // just plan creation — use the 'send' kind so agentApprove counts
        // it against autoApproveBytes. Out-of-scope still forces a card.
        final needsCard = denied.isNotEmpty ||
            (aiPolicy.mode == AiMode.auto &&
                total > aiPolicy.autoApproveBytes);
        if (denied.isNotEmpty && securityScope.strict) {
          p.status = PlanStatus.failed;
          p.error = '安全隔离:文件不在允许目录内: ${denied.first}';
          return;
        }
        if (needsCard) {
          final ok = await agentApprove(
              'send',
              denied.isNotEmpty
                  ? '计划发送含白名单外文件: ${denied.join(', ')}'
                  : '计划发送超过自动批准大小: '
                      '${p.filePaths.map((x) => x.split(Platform.pathSeparator).last).join(', ')} '
                      '→ ${peer.alias}',
              total,
              remote: false,
              forceConfirm: denied.isNotEmpty);
          // The policy may have been switched off while the card waited.
          if (!ok || aiPolicy.mode == AiMode.off) {
            p.status = PlanStatus.failed;
            p.error = denied.isNotEmpty
                ? '安全隔离:文件不在允许目录内: ${denied.first}'
                : '未批准或 AI 模式已关闭';
            return;
          }
        }
      }
      // The plan may have been cancelled, or the peer dropped, while the
      // async checks ran.
      if (p.status != PlanStatus.pending) return;
      final pe = peers[p.peerFingerprint];
      if (pe == null || !pe.online) return;
      // The mode-off check at dispatch start can be stale by now —
      // re-check so switching AI off mid-flight still stops the send.
      if (p.agentCreated && aiPolicy.mode == AiMode.off) {
        p.status = PlanStatus.failed;
        p.error = 'AI 模式已关闭';
        return;
      }
      final tf = [
        for (final x in p.filePaths)
          TransferFile(
            id: randomId(),
            name: x.split(Platform.pathSeparator).last,
            size: File(x).lengthSync(),
            path: x,
          ),
      ];
      // Set messageId before flipping status so a tick running mid-await
      // never sees `running` with no message and marks the plan failed.
      p.messageId = (await sendFiles(pe, tf)).id;
      p.status = PlanStatus.running;
      p.peerAlias = pe.alias;
    } finally {
      _persist();
      notifyListeners();
    }
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

  // ------------------------------------------------------------ AI 控制

  /// Pending AI/agent actions waiting for the user's decision.
  List<AgentAction> get pendingAgentActions =>
      _approvals.values.toList(growable: false)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Future<void> setAiPolicy(AiPolicy p) async {
    // Enabling remote control always implies a token exists to mint against.
    if (p.allowRemoteControl && p.remoteToken.isEmpty) {
      p.remoteToken = randomId(16);
    }
    aiPolicy = p;
    identity.agentCapable = p.allowRemoteControl;
    await saveAiPolicy(p);
    notifyListeners();
  }

  /// Rotates the remote token; returns the new one.
  Future<String> rotateRemoteToken() async {
    aiPolicy.remoteToken = randomId(16);
    await setAiPolicy(aiPolicy);
    return aiPolicy.remoteToken;
  }

  String? remoteTokenFor(String fp) => _remoteTokens[fp];

  Future<void> setRemoteToken(String fp, String token) async {
    if (token.isEmpty) {
      _remoteTokens.remove(fp);
    } else {
      _remoteTokens[fp] = token;
    }
    await saveRemoteTokens(_remoteTokens);
  }

  Future<void> setSecurityScope(SecurityScope s) async {
    securityScope = s;
    await saveSecurityScope(s);
    notifyListeners();
  }

  /// Saves the AI assistant endpoint config.
  Future<void> setLlmConfig(LlmConfig c) async {
    llmConfig = c;
    await saveLlmConfig(c);
    notifyListeners();
  }

  /// Directories agent sends may read from: the configured scope dirs
  /// (with `~` expanded) plus the app's own staging and download dirs,
  /// which are always allowed so staged/received files can be re-sent.
  Future<List<String>> allowedRoots() async {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final roots = <String>[];
    for (final d in securityScope.dirs) {
      var e = d.trim();
      if (e.isEmpty) continue;
      if (e.startsWith('~') && home != null) {
        e = home + e.substring(1);
      }
      final c = _canon(e);
      if (c != null) roots.add(c);
    }
    final staging = _canon((await files.stagingDir()).path);
    if (staging != null) roots.add(staging);
    final dl = _canon(downloads.path);
    if (dl != null) roots.add(dl);
    return roots.toSet().toList();
  }

  /// True when [path] resolves inside an allowed root. A path whose
  /// symlinks cannot be resolved counts as outside — fail-safe.
  Future<bool> pathInScope(String path) async {
    final c = _canon(path);
    return c != null && pathWithinRoots(c, await allowedRoots());
  }

  /// Public wrapper for the canonicalizer — the agent API needs it to
  /// detect staged paths before trusting recorded origin claims.
  String? canonPath(String path) => _canon(path);

  /// Normalized absolute path with symlinks resolved, or null when
  /// resolution fails (broken link / permission) — treat as unverifiable.
  String? _canon(String path) {
    var p = p2.normalize(File(path).absolute.path);
    try {
      p = File(p).resolveSymbolicLinksSync();
    } catch (_) {
      return null;
    }
    return p;
  }

  /// Decides whether an agent action may proceed.
  ///  - remote (leader-instructed) calls ALWAYS need the user's tap;
  ///  - mode off refuses outright;
  ///  - ask requires a tap;
  ///  - auto passes unless the transfer exceeds autoApproveBytes or
  ///    [forceConfirm] is set (e.g. an out-of-scope path).
  /// Approval waits up to 60s; unanswered = denied.
  Future<bool> agentApprove(
    String kind,
    String label,
    int bytes, {
    required bool remote,
    bool forceConfirm = false,
  }) async {
    if (aiPolicy.mode == AiMode.off) return false;
    if (remote ||
        aiPolicy.mode == AiMode.ask ||
        (aiPolicy.mode == AiMode.auto &&
            ((forceConfirm) ||
                (kind == 'send' && bytes > aiPolicy.autoApproveBytes)))) {
      final a = AgentAction(
        id: randomId(),
        kind: kind,
        label: label,
        bytes: bytes,
        remote: remote,
        decision: Completer<bool>(),
      );
      _approvals[a.id] = a;
      notifyListeners();
      final ok = await a.decision.future
          .timeout(const Duration(seconds: 60), onTimeout: () => false);
      _approvals.remove(a.id);
      notifyListeners();
      return ok;
    }
    return true;
  }

  void answerAgentAction(String id, bool allow) {
    final a = _approvals.remove(id);
    if (a != null && !a.decision.isCompleted) {
      a.decision.complete(allow);
    }
    notifyListeners();
  }

  /// Leader orchestration: ask [member] to send [paths] (member-local
  /// absolute paths) to the peer named [peerKey]. Returns the member's
  /// response body. The member still requires its own user's approval.
  Future<Map<String, dynamic>> remoteSend(
    Peer member,
    String peerKey,
    List<String> paths, {
    String? token,
  }) async {
    final t = (token != null && token.isNotEmpty)
        ? token
        : _remoteTokens[member.fingerprint];
    if (t == null || t.isEmpty) {
      throw StateError('no remote token for ${member.alias} — set it first');
    }
    final r = await _remoteCall(member, t, 'POST', 'send', {
      'peer': peerKey,
      'paths': paths,
    });
    // Persist the credential only once the member has accepted it.
    if (token != null && token.isNotEmpty) {
      await setRemoteToken(member.fingerprint, token);
    }
    return r;
  }

  /// Leader: list recent files on [member]'s device (its downloads dir).
  Future<List<dynamic>> remoteFiles(Peer member, {String? token}) async {
    final t = (token != null && token.isNotEmpty)
        ? token
        : _remoteTokens[member.fingerprint];
    if (t == null || t.isEmpty) {
      throw StateError('no remote token for ${member.alias} — set it first');
    }
    final j = await _remoteCall(member, t, 'GET', 'files', null);
    if (token != null && token.isNotEmpty) {
      await setRemoteToken(member.fingerprint, token);
    }
    return (j['files'] as List?) ?? const [];
  }

  Future<Map<String, dynamic>> _remoteCall(
    Peer member,
    String token,
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.openUrl(
        method,
        member.baseUri.replace(path: '${AgentApi.prefix}$path'),
      );
      req.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      // Approval on the member can take up to 60s — wait longer.
      final res = await req.close().timeout(const Duration(seconds: 90));
      final text = await utf8.decodeStream(res);
      final j = jsonDecode(text.isEmpty ? '{}' : text);
      if (res.statusCode >= 300) {
        throw StateError(
            '${member.alias} ${res.statusCode}: ${(j as Map)['error'] ?? text}');
      }
      return (j as Map).cast<String, dynamic>();
    } finally {
      c.close();
    }
  }

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
      send.tokens = tokens;
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
    // Stall watchdog: re-armed on every progress tick and each finished
    // file — any silent gap past the limit means the sender died mid-flight.
    _armStallWatchdog(messageId);
    _persist();
  }

  /// (Re)starts the 30s stall watchdog for an accepted incoming session.
  /// Fails unfinished files and cancels the message if the sender goes
  /// silent — covers "accepted but no bytes" and mid-transfer abandonment.
  void _armStallWatchdog(String id) {
    _watchdogs.remove(id)?.cancel();
    _watchdogs[id] = Timer(const Duration(seconds: 30), () {
      final session = server.sessions[id];
      final msg = _findMessage(id);
      if (session == null || msg == null || msg.terminal) return;
      for (final f in msg.files) {
        if (f.status != FileStatus.done && f.status != FileStatus.failed) {
          f.status = FileStatus.failed;
        }
      }
      session.cancelled = true;
      server.sessions.remove(id);
      _saveReservations.removeWhere((k, _) => k.startsWith('$id:'));
      msg.status = MessageStatus.cancelled;
      msg.error = '对方已停止发送';
      _persist();
    });
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
        // Tell the receiver so its session stops instead of waiting for the
        // stall watchdog. Requires one of our issued per-file tokens — the
        // receiver only honors cancels from the transfer's owner.
        final sid = send.sessionId;
        final token =
            send.tokens.isEmpty ? null : send.tokens.values.first;
        if (sid != null && token != null) {
          unawaited(
            HttpClient()
                .postUrl(send.peer.baseUri.replace(
                  path: kCancelPath,
                  queryParameters: {'sessionId': sid, 'token': token},
                ))
                .then((r) => r.close())
                .then((r) => r.drain<void>())
                .catchError((_) {}),
          );
        }
      }
    } else {
      final session = server.sessions[msg.id];
      msg.status = MessageStatus.cancelled;
      if (session != null) {
        session.cancelled = true;
        if (!session.decision.isCompleted) session.decision.complete(false);
        server.sessions.remove(msg.id);
      }
      // Free any filename reservations held by this aborted upload so a
      // later transfer of the same name keeps the original path.
      _saveReservations.removeWhere((k, _) => k.startsWith('${msg.id}:'));
    }
    _watchdogs.remove(msg.id)?.cancel();
    _persist();
  }

  Future<String> _savePathFor(IncomingSession s, TransferFile f) async {
    final dir = await files.downloadsDir();
    var dest = files.dedupePath(dir.path, files.sanitizeFileName(f.name));
    // Race guard: another accepted upload may have reserved the same free
    // name but not written it yet — keep deduping until ours is unique.
    var n = 1;
    while (_saveReservations.containsValue(dest)) {
      dest = files.dedupePath(
          dir.path, '${files.sanitizeFileName(f.name)} ($n)');
      n++;
    }
    _saveReservations['${s.id}:${f.id}'] = dest;
    return dest;
  }

  void _uploadProgress(IncomingSession s, String fileId, int received) {
    final msg = _findMessage(s.id);
    final f = s.files[fileId];
    if (msg == null || f == null) return;
    if (msg.terminal) return; // cancelled/failed — don't resurrect it
    f.status = FileStatus.receiving;
    f.progress = f.size == 0 ? 1 : (received / f.size).clamp(0, 1);
    msg.status = MessageStatus.active;
    _armStallWatchdog(s.id);
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
    _saveReservations.remove('${s.id}:$fileId');
    // The sender aborts the whole message on any failed file, so files
    // still queued will never arrive — skip them and settle now.
    if (savedTo.isEmpty) {
      for (final x in s.files.values) {
        if (x.status != FileStatus.done && x.status != FileStatus.failed) {
          x.status = FileStatus.skipped;
        }
      }
    }
    final allDone = s.files.values.every(
      (x) =>
          x.status == FileStatus.done ||
          x.status == FileStatus.failed ||
          x.status == FileStatus.skipped,
    );
    if (allDone && msg != null) {
      final ok = s.files.values.where((x) => x.status == FileStatus.done);
      final allOk = ok.length == s.files.length;
      msg.status = allOk ? MessageStatus.done : MessageStatus.failed;
      if (!allOk && ok.isNotEmpty) {
        msg.error = '部分文件失败（${ok.length}/${s.files.length} 已接收）';
      }
      _watchdogs.remove(s.id)?.cancel();
      _saveReservations.removeWhere((k, _) => k.startsWith('${s.id}:'));
      server.sessions.remove(s.id);
    } else if (msg != null && !msg.terminal) {
      // Next file's clock starts now — without this the sender could stall
      // forever between uploads.
      _armStallWatchdog(s.id);
    }
    _persist();
  }

  void _sessionEnd(IncomingSession s, String reason) {
    _watchdogs.remove(s.id)?.cancel();
    _saveReservations.removeWhere((k, _) => k.startsWith('${s.id}:'));
    final msg = _findMessage(s.id);
    if (msg != null && !msg.terminal) {
      // Anything still queued will never arrive now — mark it so the
      // message resolves instead of waiting on the stall watchdog.
      for (final f in msg.files) {
        if (f.status != FileStatus.done && f.status != FileStatus.failed) {
          f.status = FileStatus.skipped;
        }
      }
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
