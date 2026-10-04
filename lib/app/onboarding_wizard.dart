import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/identity.dart';
import '../state/providers.dart';
import 'theme.dart';

/// Variant B — full-screen 3-page wizard: animated demo, personal setup,
/// usage tips. Shown once on first run.
Future<void> showWizardOnboarding(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.white,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, _, _) => const WizardOnboarding(),
  );
}

class WizardOnboarding extends ConsumerStatefulWidget {
  const WizardOnboarding({super.key});

  @override
  ConsumerState<WizardOnboarding> createState() => _WizardOnboardingState();
}

class _WizardOnboardingState extends ConsumerState<WizardOnboarding> {
  final _pager = PageController();
  int _page = 0;
  late final TextEditingController _aliasCtrl =
      TextEditingController(text: ref.read(identityProvider).alias);

  @override
  void dispose() {
    _pager.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final alias = _aliasCtrl.text.trim();
    if (alias.isNotEmpty) {
      ref.read(identityProvider).alias = alias;
      await saveAlias(alias);
    }
    await markOnboarded();
    if (mounted) Navigator.of(context).pop();
  }

  void _next() => _pager.nextPage(
      duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final last = _page == 2;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _finish,
                child: Text(last ? '' : '跳过',
                    style: const TextStyle(color: Colors.black38)),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pager,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  const _DemoPage(),
                  _SetupPage(aliasCtrl: _aliasCtrl),
                  const _TipsPage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Row(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < 3; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(right: 6),
                          width: i == _page ? 20 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == _page
                                ? AmyTheme.accent
                                : Colors.black12,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AmyTheme.accent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                    ),
                    onPressed: last ? _finish : _next,
                    child: Text(last ? '开始使用' : '下一步'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page 1: welcome + looping two-device transfer animation.
class _DemoPage extends StatefulWidget {
  const _DemoPage();

  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 140,
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                final t = Curves.easeInOut.transform(_c.value);
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    const Positioned(
                        left: 10,
                        child: Text('💻', style: TextStyle(fontSize: 64))),
                    const Positioned(
                        right: 10,
                        child: Text('📱', style: TextStyle(fontSize: 64))),
                    Positioned(
                      left: 90 + (160 * t) + (40 * (1 - (2 * t - 1).abs())),
                      child: Transform.translate(
                        offset: Offset(0, -30 * (1 - (2 * t - 1).abs())),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AmyTheme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AmyTheme.accent),
                          ),
                          child: const Icon(Icons.description_outlined,
                              size: 22, color: AmyTheme.accent),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          const Text('欢迎使用 amy',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(
            '同一局域网里，电脑和手机像隔空投送一样互发文件——\n不用数据线、不用上传云端',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// Page 2: personal setup — device name (the main per-device parameter).
class _SetupPage extends ConsumerWidget {
  const _SetupPage({required this.aliasCtrl});

  final TextEditingController aliasCtrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider);
    final engine = ref.watch(engineProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Center(
              child: Text('你的这台设备',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
          const SizedBox(height: 24),
          TextField(
            controller: aliasCtrl,
            decoration: InputDecoration(
              labelText: '设备名',
              helperText: '附近设备会以这个名字看到你，之后可在设置里改',
              prefixIcon: const Icon(Icons.badge_outlined),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),
          _param(Icons.devices, '识别码', identity.code),
          _param(Icons.folder_outlined, '接收目录',
              engine.ready ? engine.downloads.path : '…'),
          _param(Icons.wifi_tethering, '发现方式', '同一局域网自动发现 · 也可用 6 位码/扫码连接'),
        ],
      ),
    );
  }

  Widget _param(IconData icon, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AmyTheme.accent),
          const SizedBox(width: 10),
          Text('$k  ', style: const TextStyle(fontSize: 13, color: Colors.black45)),
          Expanded(
            child: Text(v,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Page 3: how to use — three illustrated tips.
class _TipsPage extends StatelessWidget {
  const _TipsPage();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('三步上手',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 24),
          _tip('📡', '设备自动出现',
              '同一 Wi-Fi 下的 amy 会出现在「附近设备」，不需要配对；找不到时用代码或扫码连接'),
          _tip('🫳', '拖文件就发',
              '桌面端把文件拖到设备名上立刻发送；或先选好文件，再点设备——像隔空投送一样'),
          _tip('✅', '对方点接受',
              '文件到达前对方会确认一次；收到的文件点气泡就能打开'),
        ],
      ),
    );
  }

  Widget _tip(String emoji, String title, String body) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(body,
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
