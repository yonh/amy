// Command line client for a running amy app: `dart run bin/amy_cli.dart`.
// Talks to the loopback-only agent API on the app's HTTP port (discovered
// via ~/.amy/endpoint.json or by probing 47777+).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<int> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    _usage();
    return args.isEmpty ? 1 : 0;
  }
  final port = await _findPort();
  if (port == null) {
    stderr.writeln('找不到运行中的 amy（~/.amy/endpoint.json 不存在且 47777+ 未响应）');
    return 2;
  }
  final api = _Api(port);
  final cmd = args.first;
  final rest = args.sublist(1);
  try {
    switch (cmd) {
      case 'identity':
        _print(await api.get('identity'));
      case 'peers':
        final j = await api.get('peers');
        for (final p in (j['peers'] as List).cast<Map<String, dynamic>>()) {
          final on = p['online'] == true ? '在线' : '离线';
          stdout.writeln(
              '${p['alias']}  ${p['fingerprint']}  $on  ${p['host']}:${p['port']}');
        }
        if ((j['peers'] as List).isEmpty) stdout.writeln('（无已知设备）');
      case 'send':
        final sPos = _positional(rest).toList();
        if (sPos.length < 2) return _err('用法: send <设备> <文件...>');
        final staged = await _stageAll(api, sPos.sublist(1).map(_abs));
        final j = await api.post('send', {
          'peer': sPos.first,
          'paths': staged,
        });
        final m = j['message'] as Map<String, dynamic>;
        stdout.writeln('已发出: ${m['id']} 状态 ${m['status']}');
        if (rest.contains('--wait') || true) await _waitDone(api, m['id']);
      case 'status':
        if (rest.isEmpty) return _err('用法: status <messageId>');
        _print(await api.get('message?id=${rest.first}'));
      case 'offers':
        final j = await api.get('offers');
        for (final m in (j['offers'] as List).cast<Map<String, dynamic>>()) {
          stdout.writeln(
              '${m['id']}  来自 ${m['peerId']}  ${(m['files'] as List).length} 个文件');
        }
        if ((j['offers'] as List).isEmpty) stdout.writeln('（无待处理）');
      case 'answer':
        if (rest.length < 2) return _err('用法: answer <messageId> accept|decline');
        await api.post('answer?id=${rest.first}&accept=${rest[1] == 'accept'}', {});
        stdout.writeln('ok');
      case 'plan':
        final at = _flag(rest, '--at');
        final when = _flag(rest, '--online') != null ? 'online' : at;
        final pos = _positional(rest).toList();
        if (pos.length < 2) {
          return _err('用法: plan <设备> <文件...> [--at ISO时间 | --online]');
        }
        final staged = await _stageAll(api, pos.sublist(1).map(_abs));
        final j = await api.post('plans', {
          'peer': pos.first,
          'paths': staged,
          if (when != null && when != 'online') 'runAt': when,
        });
        _print(j);
      case 'plans':
        final j = await api.get('plans');
        for (final p in (j['plans'] as List).cast<Map<String, dynamic>>()) {
          stdout.writeln(
              '${p['id']}  → ${p['peerAlias']}  ${(p['filePaths'] as List).length} 个文件  ${p['status']}'
              '${p['runAt'] != null ? '  定于 ${p['runAt']}' : '  上线即发'}');
        }
        if ((j['plans'] as List).isEmpty) stdout.writeln('（无计划）');
      case 'unplan':
        if (rest.isEmpty) return _err('用法: unplan <planId>');
        await api.delete('plans?id=${rest.first}');
        stdout.writeln('ok');
      default:
        _usage();
        return 1;
    }
    return 0;
  } on _ApiError catch (e) {
    stderr.writeln('错误 ${e.status}: ${e.body}');
    return 1;
  } finally {
    api.client.close();
  }
}

void _usage() {
  stdout.writeln('''
amy_cli — 控制运行中的 amy

  amy peers                            列出已知设备
  amy send <设备> <文件...>             立即发送并等结果
  amy plan <设备> <文件...> [--at ISO|--online]  计划发送（默认对方上线即发）
  amy plans / unplan <id>              查看/取消计划
  amy offers                           待你确认的传入文件
  amy answer <id> accept|decline       接受/拒绝对面发来的文件
  amy status <id> / identity           查一条消息/本机信息
''');
}

/// Pushes file bytes into the app's staging dir so sandboxed apps can
/// always read them (macOS can't open arbitrary user paths).
Future<List<String>> _stageAll(_Api api, Iterable<String> paths) async {
  final out = <String>[];
  for (final p in paths) {
    final f = File(p);
    if (!await f.exists()) throw _ApiError(0, '本机文件不存在: $p');
    final name = p.split(Platform.pathSeparator).last;
    final j = await api.postStream('stage?name=${Uri.encodeComponent(name)}', f);
    out.add(j['path'] as String);
    stdout.writeln('已暂存 $name → ${j['path']}');
  }
  return out;
}

String _abs(String p) {
  if (p.startsWith('/')) return p;
  return '${Directory.current.path}/$p';
}

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0) return i + 1 < args.length ? args[i + 1] : '';
  return null;
}

Iterable<String> _positional(List<String> args) sync* {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      i++;
      continue;
    }
    yield args[i];
  }
}

Future<int> _waitDone(_Api api, String id) async {
  for (;;) {
    final j = await api.get('message?id=$id');
    final m = j['message'] as Map<String, dynamic>;
    final s = m['status'] as String;
    if ({'done', 'declined', 'cancelled', 'failed'}.contains(s)) {
      stdout.writeln('最终状态: $s${m['error'] != null ? ' (${m['error']})' : ''}');
      return s == 'done' ? 0 : 1;
    }
    stdout.writeln('… ${(m['progress'] ?? s)}');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

int _err(String m) {
  stderr.writeln(m);
  return 1;
}

void _print(Object? o) => stdout
    .writeln(const JsonEncoder.withIndent('  ').convert(o));

Future<int?> _findPort() async {
  try {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    final f = File('$home/.amy/endpoint.json');
    if (await f.exists()) {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final p = (j['port'] as num).toInt();
      if (await _alive(p)) return p;
    }
  } catch (_) {}
  for (var p = 47777; p < 47787; p++) {
    if (await _alive(p)) return p;
  }
  return null;
}

Future<bool> _alive(int port) async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final r = await c
        .getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/agent/identity'))
        .timeout(const Duration(seconds: 1));
    final res = await r.close().timeout(const Duration(seconds: 1));
    await res.drain<void>();
    c.close();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

class _ApiError implements Exception {
  _ApiError(this.status, this.body);
  final int status;
  final String body;
}

class _Api {
  _Api(this.port);
  final int port;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Uri _u(String path) => Uri.parse('http://127.0.0.1:$port/api/v1/agent/$path');

  Future<Map<String, dynamic>> _req(
      String method, String path, Map<String, dynamic>? body) async {
    final req = await client.openUrl(method, _u(path));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final j = jsonDecode(text.isEmpty ? '{}' : text);
    if (res.statusCode >= 300) {
      throw _ApiError(res.statusCode, text);
    }
    return (j as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> get(String p) => _req('GET', p, null);
  Future<Map<String, dynamic>> post(String p, Map<String, dynamic> b) =>
      _req('POST', p, b);
  Future<Map<String, dynamic>> delete(String p) => _req('DELETE', p, null);

  Future<Map<String, dynamic>> postStream(String p, File f) async {
    final req = await client.openUrl('POST', _u(p));
    req.headers.contentType = ContentType.binary;
    req.contentLength = await f.length();
    await req.addStream(f.openRead());
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final j = jsonDecode(text.isEmpty ? '{}' : text);
    if (res.statusCode >= 300) throw _ApiError(res.statusCode, text);
    return (j as Map).cast<String, dynamic>();
  }
}
