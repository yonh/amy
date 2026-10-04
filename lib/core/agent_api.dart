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
    if (!ok) {
      _json(req, 403, {
        'error': 'action denied',
        'hint': '用户未批准或 AI 模式为关闭',
      });
    }
    return ok;
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
    if (!await _checkScope(req, fs)) return;
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
        total, remote: remote, forceConfirm: _outOfScope.isNotEmpty)) {
      return;
    }
    final msg = await engine.sendFiles(peer, fs);
    _json(req, 200, {'message': msg.toJson()});
  }

  /// Basenames of the paths rejected by the last [_checkScope] call.
  List<String> _outOfScope = [];

  /// Filesystem isolation: every file must resolve inside an allowed
  /// directory. Strict scope → deny outright; otherwise the send gate
  /// gets forceConfirm so `auto` mode still asks when files sit outside
  /// the whitelist. Returns false with the response already written.
  Future<bool> _checkScope(HttpRequest req, List<TransferFile> fs) async {
    _outOfScope = [];
    final roots = await engine.allowedRoots();
    for (final f in fs) {
      final p = f.path ?? '';
      // Staged files always live inside the app's own staging root.
      if (!pathWithinRoots(_canon(p), roots)) {
        _outOfScope.add(f.name);
      }
    }
    if (_outOfScope.isNotEmpty && engine.securityScope.strict) {
      _json(req, 403, {
        'error': 'files outside allowed directories',
        'files': _outOfScope,
        'hint': '安全隔离为严格模式 — 将该目录加入白名单或放宽模式',
      });
      return false;
    }
    return true;
  }

  String _canon(String path) {
    var p = File(path).absolute.path;
    try {
      p = File(p).resolveSymbolicLinksSync();
    } catch (_) {}
    return p;
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
    final dir = await files.stagingDir();
    final dest = '${dir.path}/${randomId(4)}-$name';
    final sink = File(dest).openWrite();
    var size = 0;
    try {
      await for (final chunk in req) {
        sink.add(chunk);
        size += chunk.length;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    _json(req, 200, {'path': dest, 'size': size});
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
    if (!await _checkScope(req, fs)) return;
    final total = fs.fold(0, (s, f) => s + f.size);
    if (!await _gate(req, 'plan',
        'agent 请求创建计划发送给 ${peer.alias}', total, remote: false,
        forceConfirm: _outOfScope.isNotEmpty)) {
      return;
    }
    final plan = engine.createPlan(peer, fs.map((f) => f.path!).toList(),
        runAt: runAt?.toLocal());
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
