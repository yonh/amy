import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where received files land. Prefers a user-visible folder:
///  * macOS — ~/Downloads/amy
///  * iOS   — Documents/Received (surfaced in Files via UIFileSharingEnabled)
///  * Android — app-specific external dir (visible in Files, no permission)
Future<Directory> downloadsDir() async {
  Directory base;
  if (Platform.isMacOS) {
    base = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
  } else if (Platform.isAndroid) {
    final ext = await getExternalStorageDirectories();
    base = (ext != null && ext.isNotEmpty)
        ? ext.first
        : await getApplicationDocumentsDirectory();
  } else {
    base = await getApplicationDocumentsDirectory();
  }
  final dir = Directory('${base.path}${Platform.isMacOS ? '/amy' : '/Received'}');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Scratch dir inside app-support where agent-staged uploads land. Unlike
/// user folders, the sandbox always lets us read these, so files an agent
/// (amy_cli/amy_mcp) pushes over loopback are guaranteed readable.
Future<Directory> stagingDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/staged');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Drops staged files older than a day (plan dead-ends, crashed sends).
Future<void> pruneStaging({Duration olderThan = const Duration(hours: 24)}) async {
  try {
    final dir = await stagingDir();
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final e in dir.list()) {
      if (e is File) {
        final st = await e.stat();
        if (st.modified.isBefore(cutoff)) await e.delete();
      }
    }
  } catch (_) {}
}

String sanitizeFileName(String name) {
  final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (clean.isEmpty || clean == '.' || clean == '..') return 'file';
  return clean;
}

/// Returns a path inside [dir] that does not collide with an existing file,
/// inserting " (n)" before the extension as needed.
String dedupePath(String dir, String name) {
  var candidate = '$dir/$name';
  if (!File(candidate).existsSync()) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; i < 1000; i++) {
    candidate = '$dir/$stem ($i)$ext';
    if (!File(candidate).existsSync()) return candidate;
  }
  return '$dir/${DateTime.now().millisecondsSinceEpoch}-$name';
}
