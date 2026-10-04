// PROTOTYPE — throwaway fake data for the transfer UI prototype.
import 'dart:async';

import 'package:flutter/material.dart';

enum ProtoPlatform { iphone, ipad, mac, windows, android }

enum ProtoFileKind { image, video, doc, archive, audio }

class ProtoDevice {
  const ProtoDevice(this.name, this.platform);
  final String name;
  final ProtoPlatform platform;
}

class ProtoFile {
  const ProtoFile(this.name, this.bytes, {this.kind = ProtoFileKind.doc});
  final String name;
  final int bytes;
  final ProtoFileKind kind;
}

const kSelf = ProtoDevice('Amy 的 Mac mini', ProtoPlatform.mac);

const kNearby = <ProtoDevice>[
  ProtoDevice('houmu 的 iPhone', ProtoPlatform.iphone),
  ProtoDevice('iPad Pro', ProtoPlatform.ipad),
  ProtoDevice('客厅 Windows PC', ProtoPlatform.windows),
  ProtoDevice('Pixel 8', ProtoPlatform.android),
];

const kPickableFiles = <ProtoFile>[
  ProtoFile('IMG_2041.heic', 4200000, kind: ProtoFileKind.image),
  ProtoFile('IMG_2042.heic', 3900000, kind: ProtoFileKind.image),
  ProtoFile('季度报告.pdf', 2300000),
  ProtoFile('会议录屏.mp4', 48000000, kind: ProtoFileKind.video),
  ProtoFile('设计稿归档.zip', 12600000, kind: ProtoFileKind.archive),
  ProtoFile('voice-memo.m4a', 1100000, kind: ProtoFileKind.audio),
];

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

int totalBytes(List<ProtoFile> files) =>
    files.fold(0, (sum, f) => sum + f.bytes);

IconData iconForPlatform(ProtoPlatform p) => switch (p) {
      ProtoPlatform.iphone => Icons.phone_iphone,
      ProtoPlatform.ipad => Icons.tablet_mac,
      ProtoPlatform.mac => Icons.laptop_mac,
      ProtoPlatform.windows => Icons.desktop_windows,
      ProtoPlatform.android => Icons.phone_android,
    };

IconData iconForFileKind(ProtoFileKind k) => switch (k) {
      ProtoFileKind.image => Icons.image_outlined,
      ProtoFileKind.video => Icons.videocam_outlined,
      ProtoFileKind.doc => Icons.description_outlined,
      ProtoFileKind.archive => Icons.folder_zip_outlined,
      ProtoFileKind.audio => Icons.audio_file_outlined,
    };

/// Ticks [onProgress] from 0 → 1 over ~3s, then calls [onDone].
/// Caller owns the returned [Timer] and must cancel it in dispose.
Timer fakeTransfer({
  required void Function(double progress) onProgress,
  required void Function() onDone,
}) {
  var p = 0.0;
  return Timer.periodic(const Duration(milliseconds: 90), (t) {
    p += 0.02 + (1 - p) * 0.035;
    if (p >= 1) {
      t.cancel();
      onProgress(1);
      onDone();
    } else {
      onProgress(p);
    }
  });
}
