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
