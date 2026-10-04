import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_picker/file_picker.dart';

import '../core/identity.dart';
import '../core/llm.dart';
import '../core/models.dart';
import '../state/providers.dart';
import 'theme.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const SettingsSheet(),
  );
}

/// Device alias + receive directory + housekeeping.
class SettingsSheet extends ConsumerStatefulWidget {
  const SettingsSheet({super.key});

  @override
  ConsumerState<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<SettingsSheet> {
  late final TextEditingController _aliasCtrl;

  @override
  void initState() {
    super.initState();
    _aliasCtrl = TextEditingController(text: ref.read(identityProvider).alias);
  }

  @override
  void dispose() {
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAlias() async {
    final alias = _aliasCtrl.text.trim();
    if (alias.isEmpty) return;
    final identity = ref.read(identityProvider);
    identity.alias = alias;
    await saveAlias(alias);
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称已保存，重启后对其他设备生效')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider);
    final engine = ref.watch(engineProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('本机设置',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(
              controller: _aliasCtrl,
              decoration: InputDecoration(
                labelText: '设备名（其他设备看到的名字）',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _saveAlias(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AmyTheme.accent),
              onPressed: _saveAlias,
              child: const Text('保存名称'),
            ),
            const SizedBox(height: 20),
            _infoRow('接收目录', engine.ready ? engine.downloads.path : '…'),
            _infoRow('监听端口', '${identity.port}'),
            _infoRow('协议版本', 'v1 · 局域网明文传输'),
            const SizedBox(height: 20),
            _AiSection(),
            const SizedBox(height: 20),
            _BrainSection(),
            const SizedBox(height: 20),
            _ScopeSection(),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(k, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// AI/agent controls: how much automation this device permits, and whether
/// a leader device may instruct it remotely.
class _AiSection extends ConsumerWidget {
  static const _thresholds = [8, 32, 128, 512];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final p = engine.aiPolicy;
    final mb = (p.autoApproveBytes / (1024 * 1024)).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('AI 助手',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('控制 agent / 主控设备 可以代做的动作',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        SegmentedButton<AiMode>(
          segments: const [
            ButtonSegment(value: AiMode.off, label: Text('关闭')),
            ButtonSegment(value: AiMode.ask, label: Text('需确认')),
            ButtonSegment(value: AiMode.auto, label: Text('自动')),
          ],
          selected: {p.mode},
          onSelectionChanged: (s) {
            p.mode = s.first;
            engine.setAiPolicy(p);
          },
        ),
        if (p.mode == AiMode.auto) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('超过此大小的发送仍需确认',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              ),
              DropdownButton<int>(
                value: _thresholds.contains(mb) ? mb : 32,
                items: [
                  for (final t in _thresholds)
                    DropdownMenuItem(value: t, child: Text('$t MB')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  p.autoApproveBytes = v * 1024 * 1024;
                  engine.setAiPolicy(p);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许主控设备指挥本机', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '开启后其他设备可用 token 远程发起发送，仍需本机逐次确认',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          value: p.allowRemoteControl,
          onChanged: (v) {
            p.allowRemoteControl = v;
            engine.setAiPolicy(p);
          },
        ),
        if (p.allowRemoteControl) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    p.remoteToken,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制 token',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: p.remoteToken));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('token 已复制')));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '轮换 token（旧的立即失效）',
                  onPressed: () => engine.rotateRemoteToken(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '把这个 token 发给主控设备一次，之后它才可指挥本机',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ],
    );
  }
}

/// AI 大脑: the OpenAI-compatible endpoint the in-app assistant talks to.
class _BrainSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_BrainSection> createState() => _BrainSectionState();
}

class _BrainSectionState extends ConsumerState<_BrainSection> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  String? _probe;

  @override
  void initState() {
    super.initState();
    final c = ref.read(engineProvider).llmConfig;
    _url = TextEditingController(text: c.baseUrl);
    _key = TextEditingController(text: c.apiKey);
    _model = TextEditingController(text: c.model);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  LlmConfig _collect() => LlmConfig(
        baseUrl: _url.text.trim().isEmpty
            ? 'https://apihub.agnes-ai.com'
            : _url.text.trim(),
        apiKey: _key.text.trim(),
        model: _model.text.trim().isEmpty
            ? 'agnes-3.0-flash'
            : _model.text.trim(),
      );

  Future<void> _save({bool probe = false}) async {
    final c = _collect();
    await ref.read(engineProvider).setLlmConfig(c);
    if (probe) {
      setState(() => _probe = '测试中…');
      final result = await LlmClient(c).probe();
      if (mounted) setState(() => _probe = result);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('AI 大脑配置已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('AI 大脑',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('应用内 AI 助手使用的 OpenAI 兼容接口（密钥只保存在本机）',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        TextField(
          controller: _url,
          decoration: InputDecoration(
            labelText: 'base_url',
            isDense: true,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _key,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'api_key',
            isDense: true,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _model,
          decoration: InputDecoration(
            labelText: 'model',
            isDense: true,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final m in kLlmModelSuggestions)
              ActionChip(
                label: Text(m, style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                onPressed: () => _model.text = m,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AmyTheme.accent),
              onPressed: () => _save(),
              child: const Text('保存'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _save(probe: true),
              child: const Text('保存并测试连接'),
            ),
          ],
        ),
        if (_probe != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_probe!,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ),
      ],
    );
  }
}

/// Filesystem isolation: which directories agent-initiated sends may
/// read from, and whether out-of-scope files are denied outright.
class _ScopeSection extends ConsumerWidget {
  Future<void> _pickDir(WidgetRef ref) async {
    final engine = ref.read(engineProvider);
    final dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择允许的目录');
    if (dir == null) return;
    final s = engine.securityScope;
    if (!s.dirs.contains(dir)) {
      s.dirs.add(dir);
      await engine.setSecurityScope(s);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final s = engine.securityScope;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('安全隔离',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('agent 只能发送白名单目录里的文件（应用暂存目录始终允许）',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 10),
        if (s.dirs.isEmpty)
          Text('尚未添加目录 — 仅允许应用自己的文件',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
        for (final d in s.dirs)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(d,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '移除',
                  onPressed: () {
                    s.dirs.remove(d);
                    engine.setSecurityScope(s);
                  },
                ),
              ],
            ),
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加允许目录'),
          onPressed: () => _pickDir(ref),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('严格模式', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            '关闭：目录外文件可逐次批准；开启：目录外一律拒绝',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          value: s.strict,
          onChanged: (v) {
            s.strict = v;
            engine.setSecurityScope(s);
          },
        ),
      ],
    );
  }
}
