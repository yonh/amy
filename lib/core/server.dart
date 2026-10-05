import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_api.dart';
import 'identity.dart';
import 'models.dart';
import 'protocol.dart';

/// One inbound transfer negotiation, created when a peer POSTs
/// /prepare-upload. The server keeps it until uploads finish or it is
/// cancelled/declined.
class IncomingSession {
  IncomingSession({required this.id, required this.files})
      : tokens = {for (final f in files.values) f.id: randomId(6)};

  final String id;

  /// fileId -> file meta (name/size as advertised).
  final Map<String, TransferFile> files;

  /// fileId -> per-file accept token the sender must echo on /upload.
  final Map<String, String> tokens;

  /// Completes true when the local user accepts, false on decline/timeout.
  final Completer<bool> decision = Completer<bool>();
  bool cancelled = false;

  /// Set only after the user actually accepted — /upload requires it, so an
  /// offer still awaiting an answer cannot receive bytes.
  bool accepted = false;
}

typedef PrepareHandler = Future<IncomingSession> Function(
  Peer from,
  Map<String, TransferFile> files,
);
typedef SavePathHandler = Future<String> Function(
  IncomingSession session,
  TransferFile file,
);
typedef UploadProgressHandler = void Function(
  IncomingSession session,
  String fileId,
  int received,
);
typedef UploadDoneHandler = void Function(
  IncomingSession session,
  String fileId,
  String savedTo,
);
typedef SessionEndHandler = void Function(
  IncomingSession session,
  String reason,
);
typedef PeerResolveHandler = Peer Function(
  Map<String, dynamic> info,
  InternetAddress remote,
);
typedef TextHandler = void Function(Peer from, String text);
typedef AgentHandler = FutureOr<void> Function(HttpRequest request);

/// HTTP server every device runs: discovery info, offer negotiation, and the
/// actual file bodies. All logic lives in the engine via callbacks.
class AmyServer {
  AmyServer({
    required this.identity,
    required this.onPrepare,
    required this.onSavePath,
    required this.onUploadProgress,
    required this.onUploadDone,
    required this.onSessionEnd,
    required this.onPeerInfo,
    required this.onText,
    this.onAgent,
  });

  final SelfIdentity identity;
  final PrepareHandler onPrepare;
  final SavePathHandler onSavePath;
  final UploadProgressHandler onUploadProgress;
  final UploadDoneHandler onUploadDone;
  final SessionEndHandler onSessionEnd;

  /// Resolves an /prepare-upload `from` block into a [Peer] the engine tracks.
  final PeerResolveHandler onPeerInfo;

  /// Chat text arriving over /api/v1/text — stored straight into the
  /// thread; no accept gate (chat semantics, like any LAN messenger).
  final TextHandler onText;

  /// Loopback-only agent API (amy_cli / amy_mcp). Receives requests under
  /// /api/v1/agent/*; must write and close the response.
  final AgentHandler? onAgent;

  final sessions = <String, IncomingSession>{};
  HttpServer? _server;

  int get port => _server?.port ?? 0;

  Future<int> start() async {
    if (_server != null) return port;
    for (var i = 0; i < kPortSpan; i++) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          kBasePort + i,
        );
        break;
      } on SocketException {
        continue;
      }
    }
    final server = _server;
    if (server == null) {
      throw StateError('no free port in $kBasePort..${kBasePort + kPortSpan}');
    }
    server.idleTimeout = const Duration(minutes: 2);
    server.listen(_route, onError: (_) {});
    return server.port;
  }

  Future<void> _route(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == kInfoPath) {
        _json(req, 200, identity.infoJson());
      } else if (req.method == 'POST' && path == kPreparePath) {
        await _prepare(req);
      } else if (req.method == 'POST' && path == kUploadPath) {
        await _upload(req);
      } else if (req.method == 'POST' && path == kCancelPath) {
        _cancel(req);
      } else if (req.method == 'POST' && path == kTextPath) {
        await _text(req);
      } else if (req.method == 'POST' && path == kVerifyCodePath) {
        await _verifyCode(req);
      } else if (path.startsWith(AgentApi.prefix)) {
        // Loopback callers use the per-run token; remote members' leaders
        // use the Bearer token — the API layer decides per-origin.
        if (onAgent == null) {
          _json(req, 403, {'error': 'agent api disabled'});
          return;
        }
        await onAgent!(req);
      } else {
        _json(req, 404, {'error': 'not found'});
      }
    } catch (e) {
      try {
        _json(req, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _prepare(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final j = jsonDecode(body) as Map<String, dynamic>;
    final fromInfo = j['from'] as Map<String, dynamic>? ?? {};
    final remote = req.connectionInfo?.remoteAddress;
    if (remote == null) {
      _json(req, 400, {'error': 'no remote'});
      return;
    }
    final peer = onPeerInfo(fromInfo, remote);
    final filesJson = j['files'] as List? ?? const [];
    final files = <String, TransferFile>{
      for (final f in filesJson)
        (f as Map<String, dynamic>)['id'] as String:
            TransferFile.fromJson(f),
    };
    if (files.isEmpty) {
      _json(req, 400, {'error': 'empty file list'});
      return;
    }

    final session = await onPrepare(peer, files);
    sessions[session.id] = session;

    // Block until the user decides, or auto-decline on timeout.
    final accepted = await session.decision.future
        .timeout(kOfferTimeout, onTimeout: () => false);
    if (!accepted || session.cancelled) {
      sessions.remove(session.id);
      onSessionEnd(session, 'declined');
      _json(req, 403, {'accepted': false});
      return;
    }
    session.accepted = true;
    _json(req, 200, {
      'accepted': true,
      'sessionId': session.id,
      'files': session.tokens,
    });
  }

  Future<void> _text(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final j = jsonDecode(body) as Map<String, dynamic>? ?? {};
    final text = (j['text'] as String? ?? '').trim();
    final remote = req.connectionInfo?.remoteAddress;
    if (remote == null || text.isEmpty) {
      _json(req, 400, {'error': 'bad text'});
      return;
    }
    final peer = onPeerInfo(j['from'] as Map<String, dynamic>? ?? {}, remote);
    onText(peer, text);
    _json(req, 200, {'ok': true});
  }

  Future<void> _upload(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final session = sessions[q['sessionId']];
    final fileId = q['fileId'];
    final token = q['token'];
    if (session == null || fileId == null || token == null) {
      _json(req, 400, {'error': 'bad params'});
      return;
    }
    if (session.tokens[fileId] != token) {
      _json(req, 403, {'error': 'bad token'});
      return;
    }
    final file = session.files[fileId];
    if (file == null) {
      _json(req, 404, {'error': 'unknown file'});
      return;
    }
    if (session.cancelled) {
      _json(req, 410, {'error': 'cancelled'});
      return;
    }
    if (!session.accepted) {
      // Tokens only exist after acceptance — a session that has not been
      // accepted must never receive bytes.
      _json(req, 403, {'error': 'offer not accepted'});
      return;
    }

    final dest = await onSavePath(session, file);
    // Session+file-scoped temp name: a cancelled upload must never delete
    // (or collide with) a later same-named transfer's in-flight temp file.
    final tmp = File('$dest.${session.id}-$fileId.amypart');
    final sink = tmp.openWrite();
    var received = 0;
    var failed = false;
    var oversized = false;
    try {
      await for (final chunk in req) {
        received += chunk.length;
        if (received > file.size) {
          // Sender overrun — refuse early rather than fill the disk.
          failed = true;
          oversized = true;
          break;
        }
        sink.add(chunk);
        onUploadProgress(session, fileId, received);
        if (session.cancelled) {
          failed = true;
          break;
        }
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      failed = true;
      try {
        await sink.close();
      } catch (_) {}
    }

    if (failed || received != file.size) {
      await tmp.delete().catchError((_) => tmp);
      if (session.cancelled) {
        _json(req, 410, {'error': 'cancelled'});
      } else if (oversized) {
        onUploadDone(session, fileId, '');
        _json(req, 413, {'error': 'exceeds declared size: $received/${file.size}'});
      } else {
        onUploadDone(session, fileId, '');
        _json(req, 500, {'error': 'short read: $received/${file.size}'});
      }
      return;
    }
    await tmp.rename(dest);
    onUploadDone(session, fileId, dest);
    _json(req, 200, {'ok': true});
  }

  void _cancel(HttpRequest req) {
    final q = req.uri.queryParameters;
    final session = sessions[q['sessionId']];
    // Only the sender may abort: it must echo one of the per-file tokens it
    // was issued at accept time. A bare sessionId is not proof of ownership.
    if (session != null &&
        q['token'] != null &&
        session.tokens.values.contains(q['token'])) {
      session.cancelled = true;
      sessions.remove(session.id);
      onSessionEnd(session, 'cancelled');
      if (!session.decision.isCompleted) session.decision.complete(false);
      _json(req, 200, {'ok': true});
    } else {
      _json(req, session == null ? 404 : 403,
          {'error': 'unknown session or bad token'});
    }
  }

  /// Pairing-code check: the caller proves it saw the code on our screen
  /// without us ever broadcasting it. Wrong guesses cost 150ms each.
  Future<void> _verifyCode(HttpRequest req) async {
    final body = await utf8.decodeStream(req);
    final code =
        (jsonDecode(body) as Map<String, dynamic>?)?['code'] as String?;
    if (code != null && code == identity.code) {
      _json(req, 200, {'ok': true});
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _json(req, 404, {'ok': false});
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(req.response.close());
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
  }
}
