import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nomad_service.dart';
import 'nomad_store.dart';

/// Overridden in `main()` / tests with the real instance.
final nomadServiceProvider = Provider<NomadService>(
  (ref) => throw UnimplementedError(),
);

final nomadNodesProvider = StreamProvider<List<NomadNodeRow>>((ref) {
  final s = ref.watch(nomadServiceProvider).store;
  return s.watch(s.nodes);
});

final nomadBookmarksProvider = StreamProvider<List<NomadBookmark>>((ref) {
  final s = ref.watch(nomadServiceProvider).store;
  return s.watch(s.bookmarks);
});

final nomadHistoryProvider = StreamProvider<List<NomadHistoryEntry>>((ref) {
  final s = ref.watch(nomadServiceProvider).store;
  return s.watch(s.history);
});
