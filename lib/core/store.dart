import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Persists transfer threads and pinned/remembered peers to a JSON file in
/// app-support, so sessions and device list survive restarts.
class HistoryStore {
  HistoryStore(this._file);

  final File _file;

  /// peerFingerprint -> messages, oldest first.
  final Map<String, List<TransferMessage>> threads = {};

  /// Peers worth remembering (pinned or previously connected).
  final List<Peer> peers = [];

  /// Scheduled sends that have not completed yet.
  final List<SendPlan> plans = [];

  Timer? _saveTimer;

  static Future<HistoryStore> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/history.json');
    final store = HistoryStore(file);
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final p in (j['peers'] as List? ?? const [])) {
          store.peers.add(Peer.fromJson(p as Map<String, dynamic>));
        }
        for (final e in (j['threads'] as Map<String, dynamic>? ?? {}).entries) {
          final msgs = (e.value as List)
              .map((m) => TransferMessage.fromJson(m as Map<String, dynamic>))
              .toList();
          // Anything that was mid-flight when the app died is dead.
          for (final m in msgs) {
            if (!m.terminal) {
              m.status = m.outgoing
                  ? MessageStatus.failed
                  : MessageStatus.cancelled;
              m.error ??= '应用重启，传输中断';
            }
          }
          store.threads[e.key] = msgs;
        }
        for (final p in (j['plans'] as List? ?? const [])) {
          final plan = SendPlan.fromJson(p as Map<String, dynamic>);
          // A dispatch never survives a restart either; re-arm it.
          if (plan.status == PlanStatus.running) {
            plan.status = PlanStatus.pending;
            plan.messageId = null;
          }
          if (plan.status == PlanStatus.pending) {
            store.plans.add(plan);
          }
        }
      }
    } catch (_) {
      // Corrupt history should never block startup.
    }
    return store;
  }

  void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveNow);
  }

  Future<void> _saveNow() async {
    try {
      await _file.create(recursive: true);
      await _file.writeAsString(jsonEncode({
        'peers': peers.map((p) => p.toJson()).toList(),
        'threads': threads.map(
          (k, v) => MapEntry(k, v.map((m) => m.toJson()).toList()),
        ),
        'plans': plans.map((p) => p.toJson()).toList(),
      }));
    } catch (_) {}
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    await _saveNow();
  }
}
