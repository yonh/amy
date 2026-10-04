import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine.dart';
import 'files.dart' as files;
import 'models.dart';

/// Loopback-only HTTP API for local agents: amy_cli and amy_mcp both drive
/// the running app through this. Everything under /api/v1/agent/* lands here.
class AgentApi {
  AgentApi(this.engine);

  final TransferEngine engine;

  static const prefix = '/api/v1/agent/';

  Future<void> handle(HttpRequest req) async {
    // Any local process can reach loopback, so a per-run token is required —
    // it lives in ~/.amy/endpoint.json (chmod 600) where CLI/MCP read it.
    if (engine.agentToken.isNotEmpty &&
        req.headers.value('x-amy-token') != engine.agentToken) {
      _json(req, 403, {'error': 'missing or bad agent token'});
      return;
    }
    final path = req.uri.path.substring(prefix.length);
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
        case ('POST', 'stage'):
          await _stage(req);
        case ('POST', 'send'):
          await _send(req);
        case ('GET', 'message'):
          _message(req);
        case ('GET', 'offers'):
          _json(req, 200, {
            'offers': [
              for (final m in engine.pendingOffers) m.toJson(),
            ],
          });
        case ('POST', 'answer'):
          _answer(req);
        case ('GET', 'plans'):
          _json(req, 200, {
            'plans': [for (final p in engine.plans) p.toJson()],
          });
        case ('POST', 'plans'):
          await _addPlan(req);
        case ('DELETE', 'plans'):
          _cancelPlan(req);
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

  Future<void> _send(HttpRequest req) async {
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
    final files = _materialize(j);
    if (files.error != null) {
      _json(req, 400, {'error': files.error});
      return;
    }
    if (!peer.online) {
      _json(req, 409, {
        'error': 'peer offline',
        'hint': 'POST /api/v1/agent/plans to queue it for when it comes online',
      });
      return;
    }
    final msg = await engine.sendFiles(peer, files.files!);
    _json(req, 200, {'message': msg.toJson()});
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

  void _message(HttpRequest req) {
    final id = req.uri.queryParameters['id'];
    final msg = id == null ? null : engine.messageById(id);
    if (msg == null) {
      _json(req, 404, {'error': 'message not found'});
      return;
    }
    _json(req, 200, {'message': msg.toJson()});
  }

  void _answer(HttpRequest req) {
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
    final files = _materialize(j);
    if (files.error != null) {
      _json(req, 400, {'error': files.error});
      return;
    }
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
    final plan = engine.createPlan(peer, files.files!.map((f) => f.path!).toList(),
        runAt: runAt?.toLocal());
    _json(req, 200, {'plan': plan.toJson()});
  }

  void _cancelPlan(HttpRequest req) {
    final id = req.uri.queryParameters['id'];
    if (id == null) {
      _json(req, 400, {'error': 'missing id'});
      return;
    }
    engine.cancelPlan(id);
    _json(req, 200, {'ok': true});
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
