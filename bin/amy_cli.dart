// Command line client for a running amy app: `dart run bin/amy_cli.dart`.
// Talks to the loopback-only agent API on the app's HTTP port; the port and
// the per-run token come from ~/.amy/endpoint.json (chmod 600).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<int> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    _usage();
    return args.isEmpty ? 1 : 0;
  }
  final ep = await _findEndpoint();
  if (ep == null) {
    stderr.writeln('找不到运行中的 amy（~/.amy/endpoint.json 不存在或未在响应）');
    return 2;
  }
  final api = _Api(ep.$1, ep.$2);
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
        return await _waitDone(api, m['id']);
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
      case 'policy':
        if (rest.isEmpty) {
          _print(await api.get('policy'));
          break;
        }
        switch (rest.first) {
          case 'mode':
            if (rest.length < 2) return _err('用法: policy mode off|ask|auto');
            _print(await api.post('policy', {'mode': rest[1]}));
          case 'auto-mb':
            if (rest.length < 2) return _err('用法: policy auto-mb <MB>');
            _print(await api.post(
                'policy', {'autoApproveMB': int.parse(rest[1])}));
          case 'remote':
            if (rest.length < 2) return _err('用法: policy remote on|off');
            _print(await api.post(
                'policy', {'allowRemoteControl': rest[1] == 'on'}));
          case 'rotate':
            _print(await api.post('policy', {'rotate': true}));
          default:
            return _err('用法: policy [mode|auto-mb|remote|rotate] ...');
        }
      case 'scope':
        if (rest.isEmpty) {
          _print(await api.get('scope'));
          break;
        }
        switch (rest.first) {
          case 'add':
            if (rest.length < 2) return _err('用法: scope add <目录>');
            _print(await api.post('scope', {'add': _dirArg(rest[1])}));
          case 'remove':
            if (rest.length < 2) return _err('用法: scope remove <目录>');
            _print(await api.post('scope', {'remove': _dirArg(rest[1])}));
          case 'strict':
            if (rest.length < 2 || (rest[1] != 'on' && rest[1] != 'off')) {
              return _err('用法: scope strict on|off');
            }
            _print(await api.post('scope', {'strict': rest[1] == 'on'}));
          default:
            return _err('用法: scope [add|remove|strict] ...');
        }
      case 'actions':
        final j = await api.get('actions');
        for (final a in (j['actions'] as List).cast<Map<String, dynamic>>()) {
          stdout.writeln(
              '${a['id']}  ${a['remote'] == true ? '[主控] ' : ''}${a['label']}');
        }
        if ((j['actions'] as List).isEmpty) stdout.writeln('（无待审批 — 审批只能在 app 里点）');
      case 'remote-send':
        final token = _flag(rest, '--token');
        final pos = _positional(rest).toList();
        if (pos.length < 3) {
          return _err('用法: remote-send <成员设备> <目标设备> <成员上的文件路径...> [--token T]');
        }
        _print(await api.post('remote-send', {
          'member': pos[0],
          'peer': pos[1],
          'paths': pos.sublist(2),
          'token': ?token,
        }));
      case 'remote-files':
        final token = _flag(rest, '--token');
        final pos = _positional(rest).toList();
        if (pos.isEmpty) return _err('用法: remote-files <成员设备> [--token T]');
        _print(await api.post('remote-files', {
          'member': pos.first,
          'token': ?token,
        }));
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
  amy policy [mode off|ask|auto] [auto-mb N] [remote on|off] [rotate]  AI 策略
  amy actions                            待审批的 AI 操作（批准须在 app 里点）
  amy remote-send <成员> <目标> <成员上的路径...> [--token T]  指挥成员设备发送
  amy remote-files <成员> [--token T]    列出成员设备可发送的文件（需成员批准）
  amy scope [add <目录>|remove <目录>|strict on|off]  agent 可读目录白名单
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

/// Directory args keep a leading `~` (the app expands it server-side);
/// relative paths resolve against the cwd like files.
String _dirArg(String p) => p.startsWith('~') ? p : _abs(p);

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0) return i + 1 < args.length ? args[i + 1] : '';
  return null;
}

/// Flags that take no value — must not swallow the following argument.
const _boolFlags = {'--online'};

Iterable<String> _positional(List<String> args) sync* {
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (!_boolFlags.contains(args[i])) i++;
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

/// (port, token) from ~/.amy/endpoint.json; the token is required on every
/// call so port probing alone is no longer enough to drive the app. On macOS
/// a sandboxed amy writes inside its container, so we check both locations.
Future<(int, String)?> _findEndpoint() async {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null) return null;
  for (final f in [
    File('$home/.amy/endpoint.json'),
    File('$home/Library/Containers/com.yonh.amy/Data/.amy/endpoint.json'),
  ]) {
    try {
      if (await f.exists()) {
        final j =
            jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final port = (j['port'] as num).toInt();
        final token = (j['token'] as String?) ?? '';
        if (await _alive(port, token)) return (port, token);
      }
    } catch (_) {}
  }
  return null;
}

Future<bool> _alive(int port, String token) async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final r = await c
        .getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/agent/identity'))
        .timeout(const Duration(seconds: 1));
    if (token.isNotEmpty) r.headers.set('x-amy-token', token);
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
  _Api(this.port, this.token);
  final int port;
  final String token;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Uri _u(String path) => Uri.parse('http://127.0.0.1:$port/api/v1/agent/$path');

  Future<Map<String, dynamic>> _req(
      String method, String path, Map<String, dynamic>? body) async {
    final req = await client.openUrl(method, _u(path));
    if (token.isNotEmpty) req.headers.set('x-amy-token', token);
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
    if (token.isNotEmpty) req.headers.set('x-amy-token', token);
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
