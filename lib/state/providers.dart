import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/engine.dart';
import '../core/identity.dart';
import '../core/models.dart';

/// Overridden in main() with the loaded instances.
final identityProvider = Provider<SelfIdentity>(
  (ref) => throw UnimplementedError('bootstrap in main'),
);

final engineProvider = ChangeNotifierProvider<TransferEngine>(
  (ref) => throw UnimplementedError('bootstrap in main'),
);

/// Live map of known peers (discovered + remembered), keyed by fingerprint.
final peersProvider = StreamProvider<Map<String, Peer>>(
  (ref) => ref.watch(engineProvider).peersStream,
);

/// Peers currently online, sorted by alias.
final nearbyProvider = Provider<List<Peer>>((ref) {
  final map = ref.watch(peersProvider).value ?? const {};
  final list = map.values.where((p) => p.online).toList()
    ..sort((a, b) => a.alias.compareTo(b.alias));
  return list;
});

/// Peer ids that have at least one message or a pending plan,
/// most-recent first. Plans count too — otherwise a peer with only a
/// queued send (no thread yet) would be unreachable while offline.
final threadedPeersProvider = Provider<List<Peer>>((ref) {
  final engine = ref.watch(engineProvider);
  final map = ref.watch(peersProvider).value ?? const {};
  DateTime latestOf(String id) {
    var t = DateTime(1970);
    final thread = engine.threads[id];
    if (thread != null && thread.isNotEmpty) {
      t = thread.last.createdAt;
    }
    for (final p in engine.plans) {
      if (p.peerFingerprint == id &&
          p.status == PlanStatus.pending &&
          p.createdAt.isAfter(t)) {
        t = p.createdAt;
      }
    }
    return t;
  }

  final ids = <String>{
    ...engine.threads.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key),
    ...engine.plans
        .where((p) => p.status == PlanStatus.pending)
        .map((p) => p.peerFingerprint),
  }.toList()
    ..sort((a, b) => latestOf(b).compareTo(latestOf(a)));
  return [
    for (final id in ids)
      map[id] ?? engine.storedPeer(id),
  ].whereType<Peer>().toList();
});
