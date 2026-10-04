import 'package:flutter/material.dart';

/// Visual language carried over from prototype variant D.
abstract final class AmyTheme {
  static const bg = Color(0xFFF3F5FA);
  static const accent = Color(0xFF4A5BB5);
  static const bubbleMe = Color(0xFFE4E8F8);
  static const bubblePeer = Colors.white;
  static const online = Color(0xFF5BA150);

  static ThemeData data() => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: accent, surface: bg),
        scaffoldBackgroundColor: bg,
        useMaterial3: true,
      );
}
