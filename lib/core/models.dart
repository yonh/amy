import 'dart:math';

String randomId([int bytes = 8]) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

enum DevicePlatform { ios, ipados, macos, android, windows, linux, unknown }

DevicePlatform platformFromName(String? name) => switch (name) {
      'ios' => DevicePlatform.ios,
      'ipados' => DevicePlatform.ipados,
      'macos' => DevicePlatform.macos,
      'android' => DevicePlatform.android,
      'windows' => DevicePlatform.windows,
      'linux' => DevicePlatform.linux,
      _ => DevicePlatform.unknown,
    };

String platformName(DevicePlatform p) => switch (p) {
      DevicePlatform.ios => 'ios',
      DevicePlatform.ipados => 'ipados',
      DevicePlatform.macos => 'macos',
      DevicePlatform.android => 'android',
      DevicePlatform.windows => 'windows',
      DevicePlatform.linux => 'linux',
      DevicePlatform.unknown => 'unknown',
    };

/// A device on the network, keyed by its stable [fingerprint] so sessions
/// survive IP/port changes.
class Peer {
  Peer({
    required this.fingerprint,
    required this.alias,
    required this.platform,
    required this.model,
    required this.host,
    required this.port,
    this.code,
    this.pinned = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String fingerprint;
  String alias;
  DevicePlatform platform;
  String model;
  String host;
  int port;

  /// Ephemeral 6-digit pairing code, if learned via mDNS TXT or /info.
  String? code;

  /// Manually paired (code/QR/IP) — kept in the device list when offline.
  bool pinned;
  DateTime lastSeen;

  bool get online => DateTime.now().difference(lastSeen).inMinutes < 5;

  Uri get baseUri =>
      Uri.parse('http://${host.contains(':') ? '[$host]' : host}:$port');

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'alias': alias,
        'platform': platformName(platform),
        'model': model,
        'host': host,
        'port': port,
        'pinned': pinned,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
        fingerprint: j['fingerprint'] as String,
        alias: (j['alias'] as String?) ?? '设备',
        platform: platformFromName(j['platform'] as String?),
        model: (j['model'] as String?) ?? '',
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        pinned: j['pinned'] as bool? ?? false,
        lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? ''),
      );
}

enum FileKind { image, video, doc, archive, audio, other }

FileKind fileKindFor(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const images = {
    'jpg', 'jpeg', 'png', 'gif', 'heic', 'heif', 'webp', 'bmp', 'tiff', 'svg'
  };
  const videos = {'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', '3gp'};
  const docs = {
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv',
    'rtf', 'pages', 'numbers', 'key', 'epub'
  };
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'dmg'};
  const audio = {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'aiff'};
  if (images.contains(ext)) return FileKind.image;
  if (videos.contains(ext)) return FileKind.video;
  if (docs.contains(ext)) return FileKind.doc;
  if (archives.contains(ext)) return FileKind.archive;
  if (audio.contains(ext)) return FileKind.audio;
  return FileKind.other;
}

enum FileStatus { queued, sending, receiving, done, failed, skipped }

class TransferFile {
  TransferFile({
    required this.id,
    required this.name,
    required this.size,
    this.mime,
    this.path,
    this.status = FileStatus.queued,
    this.progress = 0,
  });

  final String id;
  final String name;
  final int size;
  String? mime;

  /// Local path: source file (outgoing) or saved destination (incoming).
  String? path;
  FileStatus status;
  double progress;

  FileKind get kind => fileKindFor(name);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        if (mime != null) 'mime': mime,
        if (path != null) 'path': path,
        'status': status.name,
      };

  factory TransferFile.fromJson(Map<String, dynamic> j) => TransferFile(
        id: j['id'] as String,
        name: j['name'] as String,
        size: (j['size'] as num).toInt(),
        mime: j['mime'] as String?,
        path: j['path'] as String?,
        status: FileStatus.values
            .firstWhere((s) => s.name == j['status'], orElse: () => FileStatus.queued),
      );
}

enum MessageStatus {
  /// Incoming offer the local user has not answered yet.
  offered,

  /// Outgoing offer sent, waiting for the peer to accept or decline.
  waitingApproval,

  /// Accepted, bytes are flowing.
  active,
  done,
  declined,
  cancelled,
  failed,
}

class TransferMessage {
  TransferMessage({
    required this.id,
    required this.peerId,
    required this.outgoing,
    required this.files,
    required this.status,
    DateTime? createdAt,
    this.error,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;

  /// Fingerprint of the other side.
  final String peerId;
  final bool outgoing;
  final List<TransferFile> files;
  MessageStatus status;
  final DateTime createdAt;
  String? error;

  int get totalBytes => files.fold(0, (s, f) => s + f.size);
  int get doneBytes =>
      files.fold(0, (s, f) => s + (f.size * f.progress).round());

  /// Aggregate 0..1 progress across all files in the message.
  double get progress {
    final t = totalBytes;
    if (t == 0) return 1;
    return doneBytes / t;
  }

  bool get terminal => switch (status) {
        MessageStatus.done ||
        MessageStatus.declined ||
        MessageStatus.cancelled ||
        MessageStatus.failed =>
          true,
        _ => false,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerId': peerId,
        'outgoing': outgoing,
        'files': files.map((f) => f.toJson()).toList(),
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (error != null) 'error': error,
      };

  factory TransferMessage.fromJson(Map<String, dynamic> j) => TransferMessage(
        id: j['id'] as String,
        peerId: j['peerId'] as String,
        outgoing: j['outgoing'] as bool,
        files: (j['files'] as List)
            .map((f) => TransferFile.fromJson(f as Map<String, dynamic>))
            .toList(),
        status: MessageStatus.values
            .firstWhere((s) => s.name == j['status'], orElse: () => MessageStatus.failed),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        error: j['error'] as String?,
      );
}

enum PlanStatus {
  /// Waiting for its time and/or for the peer to come online.
  pending,

  /// Dispatch attempted; the resulting message is in flight.
  running,
  done,
  failed,
  cancelled,
}

/// A scheduled file send: fires at [runAt] (null = as soon as the peer is
/// seen online). If the peer is offline when due, the plan keeps waiting.
class SendPlan {
  SendPlan({
    required this.id,
    required this.peerFingerprint,
    required this.peerAlias,
    required this.filePaths,
    this.runAt,
    this.status = PlanStatus.pending,
    DateTime? createdAt,
    this.messageId,
    this.error,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String peerFingerprint;
  String peerAlias;
  final List<String> filePaths;

  /// Local time when the plan becomes eligible; null = on peer online.
  final DateTime? runAt;
  PlanStatus status;
  final DateTime createdAt;

  /// The transfer message spawned by this plan, once dispatched.
  String? messageId;
  String? error;

  bool get timed => runAt != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerFingerprint': peerFingerprint,
        'peerAlias': peerAlias,
        'filePaths': filePaths,
        if (runAt != null) 'runAt': runAt!.toIso8601String(),
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (messageId != null) 'messageId': messageId,
        if (error != null) 'error': error,
      };

  factory SendPlan.fromJson(Map<String, dynamic> j) => SendPlan(
        id: j['id'] as String,
        peerFingerprint: j['peerFingerprint'] as String,
        peerAlias: (j['peerAlias'] as String?) ?? '设备',
        filePaths:
            (j['filePaths'] as List).map((e) => e as String).toList(),
        runAt: DateTime.tryParse(j['runAt'] as String? ?? ''),
        status: PlanStatus.values
            .firstWhere((s) => s.name == j['status'], orElse: () => PlanStatus.failed),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        messageId: j['messageId'] as String?,
        error: j['error'] as String?,
      );
}

String fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}
