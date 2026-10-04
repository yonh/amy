// MCP server (stdio transport, protocol 2025-06-18) exposing a running amy
// app to local agents. Run: `dart run bin/amy_mcp.dart`.
//
// Tools:
//   amy_list_peers                    已知/在线设备
//   amy_send_file {peer, paths[]}     立即发送（对端仍须接受）
//   amy_plan_send {peer, paths[], runAt?}  计划发送
//   amy_transfer_status {messageId}   查询一次传输
//   amy_list_plans / amy_cancel_plan {planId}
//   amy_list_offers                   待确认的传入文件
//   amy_answer_offer {messageId, accept}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _tools = [
  {
    'name': 'amy_list_peers',
    'description': '列出 amy 发现的局域网设备（别名、指纹、是否在线）',
    'inputSchema': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'amy_send_file',
    'description': '立即把本机文件发给一台设备（设备须在线且对方接受）',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'peer': {'type': 'string', 'description': '设备别名或指纹（可前缀）'},
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '本机文件绝对路径（会经 loopback 暂存到 amy 再发出）',
        },
      },
      'required': ['peer', 'paths'],
    },
  },
  {
    'name': 'amy_plan_send',
    'description': '计划发送：定时发出或等设备上线后自动发出',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'peer': {'type': 'string'},
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '本机文件绝对路径（会经 loopback 暂存到 amy 再发出）',
        },
        'runAt': {
          'type': 'string',
          'description': 'ISO8601 时间；缺省为对方上线即发',
        },
      },
      'required': ['peer', 'paths'],
    },
  },
  {
    'name': 'amy_transfer_status',
    'description': '查询一次传输的状态与进度',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'messageId': {'type': 'string'},
      },
      'required': ['messageId'],
    },
  },
  {
    'name': 'amy_list_plans',
    'description': '列出计划发送任务',
    'inputSchema': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'amy_cancel_plan',
    'description': '取消一个计划发送任务',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'planId': {'type': 'string'},
      },
      'required': ['planId'],
    },
  },
  {
    'name': 'amy_list_offers',
    'description': '列出等待本机用户确认的传入文件（发送方正在等待）',
    'inputSchema': {'type': 'object', 'properties': {}},
  },
  {
    'name': 'amy_answer_offer',
    'description': '接受或拒绝一个传入文件请求',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'messageId': {'type': 'string'},
        'accept': {'type': 'boolean'},
      },
      'required': ['messageId', 'accept'],
    },
  },
];

Future<void> main() async {
  final client = _AmyClient();
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final id = msg['id'];
    final method = msg['method'] as String?;
    final isNotification = id == null;
    Map<String, dynamic>? result;
    Map<String, dynamic>? error;
    try {
      result = await _dispatch(client, method, msg['params']);
    } on _RpcError catch (e) {
      error = {'code': e.code, 'message': e.message};
    } catch (e) {
      error = {'code': -32000, 'message': '$e'};
    }
    if (isNotification) continue;
    stdout.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      if (error != null) 'error': error else 'result': result,
    }));
  }
}

class _RpcError implements Exception {
  _RpcError(this.code, this.message);
  final int code;
  final String message;
}

Future<Map<String, dynamic>> _dispatch(
    _AmyClient c, String? method, Object? params) async {
  switch (method) {
    case 'initialize':
      return {
        'protocolVersion': '2025-06-18',
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': 'amy', 'version': '1.0.0'},
      };
    case 'ping':
      return {};
    case 'tools/list':
      return {'tools': _tools};
    case 'tools/call':
      final p = (params as Map).cast<String, dynamic>();
      final name = p['name'] as String;
      final args =
          (p['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
      final out = await _callTool(c, name, args);
      return {
        'content': [
          {'type': 'text', 'text': const JsonEncoder.withIndent('  ').convert(out)},
        ],
      };
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return {};
    default:
      throw _RpcError(-32601, 'method not found: $method');
  }
}

Future<Object?> _callTool(
    _AmyClient c, String name, Map<String, dynamic> a) async {
  switch (name) {
    case 'amy_list_peers':
      return c.get('peers');
    case 'amy_send_file':
      final staged = await c.stageAll(
          (a['paths'] as List).map((e) => e.toString()));
      return c.post('send', {
        'peer': a['peer'],
        'paths': staged,
      });
    case 'amy_plan_send':
      final staged = await c.stageAll(
          (a['paths'] as List).map((e) => e.toString()));
      return c.post('plans', {
        'peer': a['peer'],
        'paths': staged,
        if (a['runAt'] != null) 'runAt': a['runAt'],
      });
    case 'amy_transfer_status':
      return c.get('message?id=${a['messageId']}');
    case 'amy_list_plans':
      return c.get('plans');
    case 'amy_cancel_plan':
      return c.delete('plans?id=${a['planId']}');
    case 'amy_list_offers':
      return c.get('offers');
    case 'amy_answer_offer':
      return c.post(
          'answer?id=${a['messageId']}&accept=${a['accept'] == true}', {});
    default:
      throw _RpcError(-32602, 'unknown tool: $name');
  }
}

/// Talks to the app's loopback agent API; port from ~/.amy/endpoint.json
/// or by probing.
class _AmyClient {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  int? _port;

  Future<int> get port async => _port ??= await _findPort();

  Future<int> _findPort() async {
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
    throw StateError('找不到运行中的 amy（agent api 未响应）');
  }

  Future<bool> _alive(int port) async {
    try {
      final r = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/api/v1/agent/identity'))
          .timeout(const Duration(seconds: 2));
      final res = await r.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _req(
      String method, String path, Map<String, dynamic>? body) async {
    final req =
        await client.openUrl(method, _u(await port, path));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final j = jsonDecode(text.isEmpty ? '{}' : text);
    if (res.statusCode >= 300) {
      throw _RpcError(res.statusCode, text);
    }
    return (j as Map).cast<String, dynamic>();
  }

  Uri _u(int port, String path) =>
      Uri.parse('http://127.0.0.1:$port/api/v1/agent/$path');

  Future<Map<String, dynamic>> get(String p) => _req('GET', p, null);
  Future<Map<String, dynamic>> post(String p, Map<String, dynamic> b) =>
      _req('POST', p, b);
  Future<Map<String, dynamic>> delete(String p) => _req('DELETE', p, null);

  /// Pushes local file bytes into the app's staging dir (sandbox-safe).
  Future<List<String>> stageAll(Iterable<String> paths) async {
    final out = <String>[];
    for (final p in paths) {
      final f = File(p);
      if (!await f.exists()) throw _RpcError(-32602, '本机文件不存在: $p');
      final name = p.split(Platform.pathSeparator).last;
      final req = await client.openUrl(
          'POST', _u(await port, 'stage?name=${Uri.encodeComponent(name)}'));
      req.headers.contentType = ContentType.binary;
      req.contentLength = await f.length();
      await req.addStream(f.openRead());
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode >= 300) throw _RpcError(res.statusCode, text);
      out.add((jsonDecode(text) as Map)['path'] as String);
    }
    return out;
  }
}
