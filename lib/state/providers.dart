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

/// Peer ids that have at least one message, most-recent first.
final threadedPeersProvider = Provider<List<Peer>>((ref) {
  final engine = ref.watch(engineProvider);
  final map = ref.watch(peersProvider).value ?? const {};
  final ids = engine.threads.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => e.key)
      .toList()
    ..sort((a, b) {
      final la = engine.threads[a]!.last.createdAt;
      final lb = engine.threads[b]!.last.createdAt;
      return lb.compareTo(la);
    });
  return [
    for (final id in ids)
      map[id] ?? engine.storedPeer(id),
  ].whereType<Peer>().toList();
});
