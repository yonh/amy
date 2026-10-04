// PROTOTYPE — shell that hosts the four transfer-UI variants.
// Different models for "send files between my devices",
// switchable via the floating bottom bar or ← / → keys:
//   A · 雷达发现   — LocalSend/AirDrop 式：同局域网自动列出设备
//   B · 配对码     — Send Anywhere 式：6 位码 / 扫码建立一次性连接
//   C · 设备会话   — 聊天式：每台设备是一条会话，传输记录即消息
//   D · 会话+发现  — C 为主结构 + A 的动态发现作设备引入层
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'switcher.dart';
import 'variant_a.dart';
import 'variant_b.dart';
import 'variant_c.dart';
import 'variant_d.dart';

class PrototypeApp extends StatefulWidget {
  const PrototypeApp({super.key});

  @override
  State<PrototypeApp> createState() => _PrototypeAppState();
}

class _PrototypeAppState extends State<PrototypeApp> {
  static const _labels = ['A · 雷达发现', 'B · 配对码', 'C · 设备会话', 'D · 会话+发现'];
  static const _variants = [VariantA(), VariantB(), VariantC(), VariantD()];

  int _index = 0;

  void _step(int delta) => setState(
        () => _index = (_index + delta + _variants.length) % _variants.length,
      );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    // Don't steal arrow keys while typing (e.g. the code input in variant B).
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    _step(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amy — UI 原型',
      debugShowCheckedModeBanner: false,
      home: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(child: _variants[_index]),
              PrototypeSwitcher(
                label: _labels[_index],
                onPrev: () => _step(-1),
                onNext: () => _step(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
