import 'package:flutter/material.dart';

import '../core/models.dart';

IconData iconForPlatform(DevicePlatform p) => switch (p) {
      DevicePlatform.ios => Icons.phone_iphone,
      DevicePlatform.ipados => Icons.tablet_mac,
      DevicePlatform.macos => Icons.laptop_mac,
      DevicePlatform.windows => Icons.desktop_windows,
      DevicePlatform.android => Icons.phone_android,
      DevicePlatform.linux || DevicePlatform.unknown => Icons.devices_other,
    };

IconData iconForFileKind(FileKind k) => switch (k) {
      FileKind.image => Icons.image_outlined,
      FileKind.video => Icons.videocam_outlined,
      FileKind.doc => Icons.description_outlined,
      FileKind.archive => Icons.folder_zip_outlined,
      FileKind.audio => Icons.audio_file_outlined,
      FileKind.other => Icons.insert_drive_file_outlined,
    };

/// Avatar emoji for a device: the user's custom [Peer.iconEmoji] when set,
/// otherwise a platform glyph. Emoji render consistently across platforms
/// and give the list an AirDrop-like friendly face.
String deviceGlyph(Peer p) {
  final custom = p.iconEmoji;
  if (custom != null && custom.isNotEmpty) return custom;
  return switch (p.platform) {
    DevicePlatform.macos => '💻',
    DevicePlatform.ios => '📱',
    DevicePlatform.ipados => '📱',
    DevicePlatform.android => '🤖',
    DevicePlatform.windows => '🖥️',
    DevicePlatform.linux => '🐧',
    DevicePlatform.unknown => '📟',
  };
}

/// Brand accent color inferred from the advertised model name — generic
/// Android phones stay green, known vendors get their brand tint.
Color deviceTint(Peer p) {
  final m = '${p.model} ${p.alias}'.toLowerCase();
  if (p.platform == DevicePlatform.macos ||
      p.platform == DevicePlatform.ios ||
      p.platform == DevicePlatform.ipados) {
    return const Color(0xFF555B63); // Apple graphite
  }
  const brands = <(String, Color)>[
    ('huawei', Color(0xFFC7000B)),
    ('honor', Color(0xFF27B1E4)),
    ('xiaomi', Color(0xFFFF6900)),
    ('redmi', Color(0xFFFF6900)),
    ('samsung', Color(0xFF1428A0)),
    ('galaxy', Color(0xFF1428A0)),
    ('pixel', Color(0xFF3CAB5B)),
    ('google', Color(0xFF3CAB5B)),
    ('oppo', Color(0xFF1EA366)),
    ('vivo', Color(0xFF2B5DE7)),
    ('oneplus', Color(0xFFEB0028)),
    ('realme', Color(0xFFF8C415)),
    ('meizu', Color(0xFF04A6E1)),
    ('nothing', Color(0xFFD71920)),
    ('sony', Color(0xFF000000)),
    ('motorola', Color(0xFF5C92FA)),
    ('surface', Color(0xFF737373)),
  ];
  for (final (name, color) in brands) {
    if (m.contains(name)) return color;
  }
  return switch (p.platform) {
    DevicePlatform.android => const Color(0xFF3DDC84), // Android green
    DevicePlatform.windows => const Color(0xFF0078D4),
    DevicePlatform.linux => const Color(0xFFDD4814),
    _ => const Color(0xFF8A8F98),
  };
}

/// Circular device avatar: emoji glyph on a brand-tinted disc.
Widget deviceAvatar(Peer p, {double radius = 20, bool selected = false}) {
  return CircleAvatar(
    radius: radius,
    backgroundColor: selected ? deviceTint(p) : deviceTint(p).withValues(alpha: 0.15),
    child: Text(deviceGlyph(p), style: TextStyle(fontSize: radius * 0.95)),
  );
}
