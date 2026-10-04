import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine.dart';
import 'llm.dart';
import 'models.dart';

/// The in-app AI assistant: translates a natural-language instruction
/// into one structured action, then executes it through the SAME gates
/// the agent API uses (AI policy mode + security scope), so a sentence
/// typed in the app can never do more than an external agent could.
class AiBrain {
  AiBrain(this.engine);

  final TransferEngine engine;

  /// Runs one instruction end-to-end and returns the assistant-visible
  /// answer. Approval cards surface on the home screen as usual while
  /// this awaits the user's tap.
  Future<String> run(String instruction) async {
    if (engine.aiPolicy.mode == AiMode.off) {
      return 'AI 助手已关闭 — 在本机设置里把 AI 模式调成「需确认」或「自动」。';
    }
    final cfg = engine.llmConfig;
    if (!cfg.configured) {
      return '还没配置模型 — 在本机设置 → AI 大脑里填 base_url / api_key / model。';
    }
    String raw;
    try {
      raw = await LlmClient(cfg).chat([
        {'role': 'system', 'content': await _systemPrompt()},
        {'role': 'user', 'content': instruction},
      ]);
    } on LlmException catch (e) {
      return '模型调用失败: ${e.message}';
    }
    final action = parseBrainAction(raw);
    if (action == null) {
      // The model didn't emit the action JSON — show its prose instead.
      return raw;
    }
    return _execute(action);
  }

  Future<String> _systemPrompt() async {
    final peers = engine.peers.values.toList()
      ..sort((a, b) => (b.online ? 1 : 0).compareTo(a.online ? 1 : 0));
    final roots = await engine.allowedRoots();
    final s = StringBuffer()
      ..writeln('你是文件传输应用 amy 的内置助手，把用户的中文/英文指令翻译成')
      ..writeln('一个 JSON 动作。只输出 JSON 对象，不要输出其他文字或代码块。')
      ..writeln('本机: ${engine.identity.alias} (${platformName(engine.identity.platform)})')
      ..writeln('设备列表:');
    for (final p in peers) {
      s.writeln(
          '- ${p.alias} (${platformName(p.platform)} ${p.model}) id=${p.fingerprint.substring(0, 8)} ${p.online ? "在线" : "离线"}');
    }
    s
      ..writeln('动作(只选一个):')
      ..writeln('{"action":"send","peer":"<设备名或id>","files":["<绝对路径>",...],"at":"<可选: ISO8601 定时>"}')
      ..writeln('{"action":"peers"}   列出设备')
      ..writeln('{"action":"files"}   列出接收目录最近文件')
      ..writeln('{"action":"reply","text":"<回答>"}   闲聊/与文件无关的问题')
      ..writeln('{"action":"clarify","question":"<追问>"}   信息不足')
      ..writeln('规则: 发送文件只允许使用这些目录内的文件: ${roots.join(' | ')}。')
      ..writeln('用户没给出明确文件名时不要猜路径，用 clarify 追问。');
    return s.toString();
  }

  Future<String> _execute(Map<String, dynamic> a) async {
    switch (a['action']) {
      case 'peers':
        final peers = engine.peers.values.where((p) => p.online).toList();
        if (peers.isEmpty) return '附近没有在线设备。';
        return '在线设备: ${peers.map((p) => p.alias).join('、')}';
      case 'files':
        return _filesReply();
      case 'send':
        return _send(a);
      case 'reply':
        return (a['text'] as String?) ?? '…';
      case 'clarify':
        return (a['question'] as String?) ?? '需要更多信息。';
      default:
        return '模型返回了我不认识的动作: ${a['action']}';
    }
  }

  Future<String> _filesReply() async {
    final names = <String>[];
    try {
      await for (final e in engine.downloads.list()) {
        if (e is File) names.add(e.path);
      }
    } catch (_) {}
    if (names.isEmpty) return '接收目录是空的。';
    names.sort();
    return '接收目录最近文件:\n${names.reversed.take(10).join('\n')}';
  }

  Future<String> _send(Map<String, dynamic> a) async {
    final key = a['peer'] as String?;
    if (key == null || key.trim().isEmpty) return '没说发给哪台设备。';
    final peer = engine.resolvePeer(key);
    if (peer == null) {
      final known = engine.peers.values.map((p) => p.alias).join('、');
      return '找不到设备「$key」。当前设备: ${known.isEmpty ? '无' : known}';
    }
    final paths = (a['files'] as List? ?? const [])
        .map((e) => e.toString())
        .where((x) => x.isNotEmpty)
        .toList();
    if (paths.isEmpty) return '没说发哪个文件。';
    for (final p in paths) {
      if (!File(p).existsSync()) return '文件不存在: $p';
    }
    final at = a['at'] as String?;
    DateTime? runAt;
    if (at != null) {
      runAt = DateTime.tryParse(at);
      if (runAt == null) return '时间格式看不懂: $at';
    }

    final fs = <TransferFile>[];
    for (final p in paths) {
      fs.add(TransferFile(
        id: randomId(),
        name: p.split(Platform.pathSeparator).last,
        size: File(p).lengthSync(),
        path: p,
      ));
    }
    final total = fs.fold(0, (s, f) => s + f.size);

    // Same security-scope check as the agent API: unresolvable or
    // out-of-scope paths fail closed; strict mode denies outright,
    // otherwise the card forces a human tap.
    final denied = <String>[];
    for (final f in fs) {
      if (!await engine.pathInScope(f.path ?? '')) denied.add(f.name);
    }
    if (denied.isNotEmpty && engine.securityScope.strict) {
      return '已拒绝: ${denied.join(', ')} 不在允许目录内（安全隔离为严格模式）。';
    }

    final names = fs.map((f) => f.name).join(', ');
    final kind = runAt != null ? 'plan' : 'send';
    final label = runAt != null
        ? 'AI 助手 请求定时发送 $names 给 ${peer.alias}'
        : 'AI 助手 请求发送 $names 给 ${peer.alias}';
    final ok = await engine.agentApprove(kind, label, total,
        remote: false, forceConfirm: denied.isNotEmpty);
    // TOCTOU: policy may have been switched off while the card waited.
    if (!ok || engine.aiPolicy.mode == AiMode.off) {
      return '未批准 — 已取消（用户拒绝、超时或 AI 模式已关闭）。';
    }
    if (runAt != null) {
      engine.createPlan(peer, paths, runAt: runAt.toLocal(), agent: true);
      return '已创建计划: $names → ${peer.alias}，到点自动发出。';
    }
    if (!peer.online) {
      engine.createPlan(peer, paths, agent: true);
      return '${peer.alias} 不在线 — 已建计划，对方上线后自动发出。';
    }
    final msg = await engine.sendFiles(peer, fs);
    return '已发给 ${peer.alias}: $names（${fmtBytes(total)}）· 等待对方接受 [${msg.id.substring(0, 6)}]';
  }
}

/// Extracts the action JSON object from a model reply, tolerating prose
/// and markdown fences around it. Returns null when nothing parses.
Map<String, dynamic>? parseBrainAction(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final j = jsonDecode(raw.substring(start, end + 1));
    return j is Map<String, dynamic> && j['action'] is String ? j : null;
  } catch (_) {
    return null;
  }
}
