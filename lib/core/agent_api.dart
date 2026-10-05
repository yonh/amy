import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine.dart';
import 'files.dart' as files;
import 'models.dart';

/// HTTP API driving the running app for agents — amy_cli / amy_mcp call it
/// over loopback (per-run X-Amy-Token), and a leader device may call a
/// subset remotely when the member enables 允许主控指挥 (Bearer token +
/// the member's user still approves every remote action).
class AgentApi {
  AgentApi(this.engine);

  final TransferEngine engine;

  static const prefix = '/api/v1/agent/';

  /// Remote (non-loopback) callers may only read + instruct sends. Policy
  /// changes, staging bytes, answering offers and plan control stay local.
  static const _remoteAllowed = {
    ('GET', 'identity'),
    ('GET', 'peers'),
    ('GET', 'files'),
    ('GET', 'message'),
    ('POST', 'send'),
  };

  Future<void> handle(HttpRequest req) async {
    final addr = req.connectionInfo?.remoteAddress;
    final remote = addr == null || !addr.isLoopback;
    if (remote) {
      // Member side of leader control: enabled flag + Bearer token.
      final p = engine.aiPolicy;
      final auth = req.headers.value('authorization') ?? '';
      if (!p.allowRemoteControl ||
          p.remoteToken.isEmpty ||
          auth != 'Bearer ${p.remoteToken}') {
        _json(req, 403, {'error': 'remote control disabled or bad token'});
        return;
      }
    } else {
      // Loopback: per-run token from ~/.amy/endpoint.json.
      if (engine.agentToken.isNotEmpty &&
          req.headers.value('x-amy-token') != engine.agentToken) {
        _json(req, 403, {'error': 'missing or bad agent token'});
        return;
      }
    }
    final path = req.uri.path.substring(prefix.length);
    if (remote && !_remoteAllowed.contains((req.method, path))) {
      _json(req, 403, {'error': 'not allowed for remote callers'});
      return;
    }
    try {
      switch ((req.method, path)) {
        case ('GET', 'identity'):
          _json(req, 200, {
            ...engine.identity.infoJson(),
            'port': engine.identity.port,
            'downloads': engine.downloads.path,
          });
        case ('GET', 'peers'):
          _json(req, 200, {
            'peers': [for (final p in engine.peers.values) _peerJson(p)],
          });
        case ('GET', 'files'):
          await _listFiles(req, remote: remote);
        case ('POST', 'stage'):
          await _stage(req);
        case ('POST', 'send'):
          await _send(req, remote: remote);
        case ('GET', 'message'):
          _message(req);
        case ('GET', 'offers'):
          _json(req, 200, {
            'offers': [
              for (final m in engine.pendingOffers) m.toJson(),
            ],
          });
        case ('POST', 'answer'):
          await _answer(req);
        case ('GET', 'actions'):
          _json(req, 200, {
            'actions': [
              for (final a in engine.pendingAgentActions) a.toJson(),
            ],
          });
        case ('GET', 'plans'):
          _json(req, 200, {
            'plans': [for (final p in engine.plans) p.toJson()],
          });
        case ('POST', 'plans'):
          await _addPlan(req);
        case ('DELETE', 'plans'):
          await _cancelPlan(req);
        case ('GET', 'policy'):
          _json(req, 200, {
            'policy': engine.aiPolicy.toPublicJson(),
            if (!remote) 'remoteToken': engine.aiPolicy.remoteToken,
            'agentCapable': engine.identity.agentCapable,
          });
        case ('POST', 'policy'):
          await _setPolicy(req);
        case ('GET', 'scope'):
          _json(req, 200, {
            'scope': engine.securityScope.toJson(),
            'roots': await engine.allowedRoots(),
          });
        case ('POST', 'scope'):
          await _setScope(req);
        case ('POST', 'remote-send'):
          await _remoteSend(req);
        case ('POST', 'remote-files'):
          await _remoteFiles(req);
        default:
          _json(req, 404, {'error': 'unknown agent route: $path'});
      }
    } catch (e) {
      _json(req, 500, {'error': '$e'});
    }
  }

  Map<String, dynamic> _peerJson(Peer p) => {
        ...p.toJson(),
        'online': p.online,
      };

  /// Gate a mutating call through the AI policy. Returns false (with the
  /// response already written) when denied or unanswered.
  Future<bool> _gate(
    HttpRequest req,
    String kind,
    String label,
    int bytes, {
    required bool remote,
    bool forceConfirm = false,
  }) async {
    final ok = await engine.agentApprove(kind, label, bytes,
        remote: remote, forceConfirm: forceConfirm);
    // TOCTOU: the policy may have been switched off while the card waited —
    // re-check at resolution time so a stale approval can't apply anyway.
    final stillOn = ok && engine.aiPolicy.mode != AiMode.off;
    if (!ok || !stillOn) {
      _json(req, 403, {
        'error': 'action denied',
        'hint': '用户未批准或 AI 模式为关闭',
      });
      return false;
    }
    return true;
  }

  Future<void> _send(HttpRequest req, {required bool remote}) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final key = j['peer'] as String?;
    if (key == null) {
      _json(req, 400, {'error': 'missing "peer" (fingerprint or alias)'});
      return;
    }
    final peer = engine.resolvePeer(key);
    if (peer == null) {
      _json(req, 404, {'error': 'peer not found: $key'});
      return;
    }
    final materialized = _materialize(j);
    if (materialized.error != null) {
      _json(req, 400, {'error': materialized.error});
      return;
    }
    final fs = materialized.files!;
    final denied = await _checkScope(req, fs);
    if (denied == null) return;
    if (!peer.online) {
      _json(req, 409, {
        'error': 'peer offline',
        'hint': 'POST /api/v1/agent/plans to queue it for when it comes online',
      });
      return;
    }
    final total = fs.fold(0, (s, f) => s + f.size);
    final names = fs.map((f) => f.name).join(', ');
    final who = remote ? '主控设备' : 'agent';
    if (!await _gate(req, 'send', '$who 请求发送 $names 给 ${peer.alias}',
        total, remote: remote, forceConfirm: denied.isNotEmpty)) {
      return;
    }
    final msg = await engine.sendFiles(peer, fs);
    _json(req, 200, {'message': msg.toJson()});
  }

  /// Filesystem isolation: every file must resolve inside an allowed
  /// directory. Returns the out-of-scope basenames for this request
  /// (possibly empty), or null after writing a 403 in strict mode.
  /// Unresolvable paths count as outside — fail-safe.
  Future<List<String>?> _checkScope(
      HttpRequest req, List<TransferFile> fs) async {
    final denied = <String>[];
    final staging =
        engine.canonPath((await files.stagingDir()).path) ?? '';
    for (final f in fs) {
      // Canonicalize BEFORE the staged check: a disguised path (`..`,
      // symlink) that resolves into staging would otherwise skip the
      // origin check and pass as an always-allowed staging file.
      final cp = engine.canonPath(f.path ?? '');
      final isStaged = cp != null &&
          staging.isNotEmpty &&
          cp.startsWith('$staging${Platform.pathSeparator}');
      // Staged bytes are opaque: only a content-verified origin claim
      // recorded at stage time stands in for the real path. No claim —
      // planted bytes, unreadable sources, post-restart files — means
      // the origin is unverifiable and counts as outside.
      final claimed = cp == null ? null : engine.stagedSources[cp];
      final effective = isStaged ? claimed : cp;
      if (effective == null ||
          !await engine.pathInScope(effective)) {
        denied.add(f.name);
      }
    }
    if (denied.isNotEmpty && engine.securityScope.strict) {
      _json(req, 403, {
        'error': 'files outside allowed directories',
        'files': denied,
        'hint': '安全隔离为严格模式 — 将该目录加入白名单或放宽模式',
      });
      return null;
    }
    return denied;
  }

  _Materialized _materialize(Map<String, dynamic> j) {
    final paths = (j['paths'] as List? ?? const [])
        .map((e) => e.toString())
        .where((x) => x.isNotEmpty)
        .toList();
    if (paths.isEmpty) {
      return _Materialized(error: 'missing "paths"');
    }
    final files = <TransferFile>[];
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) {
        return _Materialized(error: 'file not found: $p');
      }
      files.add(TransferFile(
        id: randomId(),
        name: p.split(Platform.pathSeparator).last,
        size: f.lengthSync(),
        path: p,
      ));
    }
    return _Materialized(files: files);
  }

  /// Streams request body into the staging dir and returns its path.
  /// Agents push bytes so the app never needs read access to the
  /// caller's filesystem (macOS sandbox-safe).
  Future<void> _stage(HttpRequest req) async {
    final name = files.sanitizeFileName(
        req.uri.queryParameters['name'] ?? 'file');
    // Staging only writes into the app's own staging dir and can't trigger a
    // send by itself, so it doesn't warrant an approval card — but AI mode
    // off still refuses it.
    if (engine.aiPolicy.mode == AiMode.off) {
      _json(req, 403, {'error': 'AI mode is off'});
      return;
    }
    // Strict mode cannot scope-check opaque bytes, so staging is refused
    // outright: clients pass the real path to send/plans and the app
    // verifies + reads it itself.
    if (engine.securityScope.strict) {
      _json(req, 403, {
        'error': 'staging disabled in strict mode',
        'hint': '严格模式下直接以真实路径调用 send/plans，app 会按白名单校验并自行读取',
      });
      return;
    }
    // Bound staged uploads — a runaway or hostile loopback client must
    // not fill the app container's disk.
    const cap = 8 << 30; // 8 GiB
    if (req.contentLength > cap) {
      _json(req, 413, {'error': 'staged upload exceeds ${cap >> 30} GiB'});
      return;
    }
    final dir = await files.stagingDir();
    final dest = '${dir.path}/${randomId(4)}-$name';
    final sink = File(dest).openWrite();
    var size = 0;
    var oversized = false;
    try {
      await for (final chunk in req) {
        size += chunk.length;
        if (size > cap) {
          oversized = true;
          break;
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (oversized) {
      await File(dest).delete();
      _json(req, 413, {'error': 'staged upload exceeds ${cap >> 30} GiB'});
      return;
    }
    // The stager declares where the bytes came from (`source`); the scope
    // gate checks that claim instead of the always-allowed staging path.
    // A claim only counts when the app can PROVE it — byte-identical
    // content against the claimed source. An unreadable source is
    // unverifiable, so no claim is recorded and the file counts as
    // outside the whitelist; a readable-but-different source is a lie
    // (or raced write) and the upload is rejected.
    final source = req.uri.queryParameters['source'];
    if (source != null && source.isNotEmpty) {
      final sf = File(source);
      if (await sf.exists()) {
        if (await _sameBytes(sf, File(dest))) {
          engine.stagedSources[
              engine.canonPath(dest) ?? dest] = source;
        } else {
          await File(dest).delete();
          _json(req, 400, {
            'error': 'staged bytes differ from claimed source',
          });
          return;
        }
      }
    }
    _json(req, 200, {'path': dest, 'size': size});
  }

  /// Byte-identical comparison of two files (chunked, no hashing).
  Future<bool> _sameBytes(File a, File b) async {
    if (await a.length() != await b.length()) return false;
    final fa = await a.open();
    final fb = await b.open();
    try {
      const chunk = 1 << 20;
      var off = 0;
      final len = await fa.length();
      while (off < len) {
        final n = len - off < chunk ? len - off : chunk;
        final ba = await fa.read(n);
        final bb = await fb.read(n);
        if (ba.length != bb.length) return false;
        for (var i = 0; i < ba.length; i++) {
          if (ba[i] != bb[i]) return false;
        }
        off += n;
      }
      return true;
    } finally {
      await fa.close();
      await fb.close();
    }
  }

  /// Recent files in the downloads dir — lets a leader pick what to pull
  /// (e.g. "把 A 的 a 文件发给 C"). Remote callers need a local tap: the
  /// inventory exposes filenames + absolute paths.
  Future<void> _listFiles(HttpRequest req, {required bool remote}) async {
    if (remote &&
        !await _gate(req, 'files', '主控设备 请求浏览接收目录文件', 0,
            remote: true)) {
      return;
    }
    final entries = <Map<String, dynamic>>[];
    try {
      await for (final e in engine.downloads.list()) {
        if (e is File) {
          final st = await e.stat();
          entries.add({
            'name': e.path.split(Platform.pathSeparator).last,
            'path': e.path,
            'size': st.size,
            'modified': st.modified.toIso8601String(),
          });
        }
      }
    } catch (_) {}
    entries.sort((a, b) =>
        (b['modified'] as String).compareTo(a['modified'] as String));
    _json(req, 200, {'files': entries.take(50).toList()});
  }

  void _message(HttpRequest req) {
    final id = req.uri.queryParameters['id'];
    final msg = id == null ? null : engine.messageById(id);
    if (msg == null) {
      _json(req, 404, {'error': 'message not found'});
      return;
    }
    _json(req, 200, {'message': msg.toJson()});
  }

  Future<void> _answer(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final id = q['id'];
    final accept = q['accept'] == 'true';
    if (id == null) {
      _json(req, 400, {'error': 'missing id'});
      return;
    }
    final msg = engine.messageById(id);
    if (msg == null || msg.status != MessageStatus.offered) {
      _json(req, 404, {'error': 'no pending offer with that id'});
      return;
    }
    if (!await _gate(req, 'answer',
        'agent 请求${accept ? '接受' : '拒绝'}来自 ${msg.peerId} 的 ${msg.files.length} 个文件',
        msg.totalBytes, remote: false)) {
      return;
    }
    // The offer may have expired or been answered while the card sat
    // open — re-check before reporting success.
    if (msg.status != MessageStatus.offered) {
      _json(req, 409, {'error': 'offer no longer pending'});
      return;
    }
    engine.answerOffer(id, accept);
    _json(req, 200, {'ok': true});
  }

  Future<void> _addPlan(HttpRequest req) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final key = j['peer'] as String?;
    final peer = key == null ? null : engine.resolvePeer(key);
    if (peer == null) {
      _json(req, 404, {'error': 'peer not found: $key'});
      return;
    }
    final materialized = _materialize(j);
    if (materialized.error != null) {
      _json(req, 400, {'error': materialized.error});
      return;
    }
    final fs = materialized.files!;
    // Validate before the approval gate — a bad timestamp must not wait on
    // (or be masked by) a 60s approval card.
    final rawRunAt = j['runAt'];
    DateTime? runAt;
    if (rawRunAt != null) {
      runAt = rawRunAt is String ? DateTime.tryParse(rawRunAt) : null;
      if (runAt == null) {
        // Never fall back to "on online" — a typo would send immediately.
        _json(req, 400, {'error': 'invalid runAt (expect ISO8601): $rawRunAt'});
        return;
      }
    }
    final denied = await _checkScope(req, fs);
    if (denied == null) return;
    final total = fs.fold(0, (s, f) => s + f.size);
    if (!await _gate(req, 'plan',
        'agent 请求创建计划发送给 ${peer.alias}', total, remote: false,
        forceConfirm: denied.isNotEmpty)) {
      return;
    }
    final plan = engine.createPlan(peer, fs.map((f) => f.path!).toList(),
        runAt: runAt?.toLocal(), agent: true);
    _json(req, 200, {'plan': plan.toJson()});
  }

  Future<void> _cancelPlan(HttpRequest req) async {
    final id = req.uri.queryParameters['id'];
    if (id == null) {
      _json(req, 400, {'error': 'missing id'});
      return;
    }
    if (!await _gate(req, 'cancel-plan', 'agent 请求取消计划 $id', 0,
        remote: false)) {
      return;
    }
    engine.cancelPlan(id);
    _json(req, 200, {'ok': true});
  }

  Future<void> _setPolicy(HttpRequest req) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    // Policy edits are security-critical — always require a human tap even
    // in auto mode, and deny outright when the agent is off (an agent must
    // not re-enable or self-escalate). The card names the concrete changes
    // so the approver sees exactly what is being granted.
    final changes = <String>[
      if (j.containsKey('mode')) 'mode→${j['mode']}',
      if (j['autoApproveMB'] != null) 'autoApproveMB→${j['autoApproveMB']}',
      if (j.containsKey('allowRemoteControl'))
        'allowRemoteControl→${j['allowRemoteControl']}',
      if (j['rotate'] == true) 'rotate token',
    ];
    if (!await _gate(req, 'policy',
        'agent 请求修改 AI 策略：${changes.isEmpty ? '(无变更)' : changes.join(', ')}',
        0, remote: false, forceConfirm: true)) {
      return;
    }
    final p = engine.aiPolicy;
    if (j.containsKey('mode')) {
      p.mode = aiModeFromName(j['mode'] as String?);
    }
    if (j['autoApproveMB'] != null) {
      p.autoApproveBytes =
          (j['autoApproveMB'] as num).toInt() * 1024 * 1024;
    }
    if (j.containsKey('allowRemoteControl')) {
      p.allowRemoteControl = j['allowRemoteControl'] == true;
      // Enabling with no token mints one; disabling keeps it for re-enable.
      if (p.allowRemoteControl && p.remoteToken.isEmpty) {
        p.remoteToken = randomId(16);
      }
    }
    if (j['rotate'] == true) {
      p.remoteToken = randomId(16);
    }
    await engine.setAiPolicy(p);
    _json(req, 200, {
      'policy': p.toPublicJson(),
      'remoteToken': p.remoteToken,
    });
  }

  /// Adjusts the filesystem isolation whitelist (local callers only).
  Future<void> _setScope(HttpRequest req) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    // Whitelist edits are security-critical — always require a human tap
    // even in auto mode; an agent must not widen its own sandbox. The card
    // names the concrete changes so the approver sees the exact grant.
    final changes = <String>[
      if (j['dirs'] is List) 'dirs=${(j['dirs'] as List).join(', ')}',
      if (j['add'] is String) '+${j['add']}',
      if (j['remove'] is String) '-${j['remove']}',
      if (j.containsKey('strict')) 'strict→${j['strict']}',
    ];
    if (!await _gate(req, 'scope',
        'agent 请求修改目录白名单：${changes.isEmpty ? '(无变更)' : changes.join(', ')}',
        0, remote: false, forceConfirm: true)) {
      return;
    }
    final s = engine.securityScope;
    if (j['dirs'] is List) {
      s.dirs = (j['dirs'] as List)
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (j['add'] is String) {
      final d = (j['add'] as String).trim();
      if (d.isNotEmpty && !s.dirs.contains(d)) s.dirs.add(d);
    }
    if (j['remove'] is String) {
      s.dirs.remove(j['remove']);
    }
    if (j.containsKey('strict')) {
      s.strict = j['strict'] == true;
    }
    await engine.setSecurityScope(s);
    _json(req, 200, {
      'scope': s.toJson(),
      'roots': await engine.allowedRoots(),
    });
  }

  /// Leader instruction: member sends member-local [paths] to [peer].
  Future<void> _remoteSend(HttpRequest req) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final memberKey = j['member'] as String?;
    final peerKey = j['peer'] as String?;
    final paths = (j['paths'] as List? ?? const [])
        .map((e) => e.toString())
        .where((x) => x.isNotEmpty)
        .toList();
    final member = memberKey == null ? null : engine.resolvePeer(memberKey);
    if (member == null) {
      _json(req, 404, {'error': 'member not found: $memberKey'});
      return;
    }
    if (peerKey == null || paths.isEmpty) {
      _json(req, 400, {'error': 'missing "peer" or "paths"'});
      return;
    }
    final result = await engine.remoteSend(member, peerKey, paths,
        token: j['token'] as String?);
    _json(req, 200, result);
  }

  /// POST body carries the member token (never a URL param — query
  /// strings end up in logs).
  Future<void> _remoteFiles(HttpRequest req) async {
    final j = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final memberKey = j['member'] as String?;
    final member = memberKey == null ? null : engine.resolvePeer(memberKey);
    if (member == null) {
      _json(req, 404, {'error': 'member not found: $memberKey'});
      return;
    }
    final list =
        await engine.remoteFiles(member, token: j['token'] as String?);
    _json(req, 200, {'files': list});
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(req.response.close());
  }
}

class _Materialized {
  _Materialized({this.files, this.error});

  final List<TransferFile>? files;
  final String? error;
}
