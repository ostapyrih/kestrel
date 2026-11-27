import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lora_service.dart';

/// Overridden in `main()` / tests with the real service or a fake.
final loraControllerProvider = Provider<LoraController>(
  (ref) => throw UnimplementedError(),
);

final loraViewProvider = StreamProvider<LoraView>((ref) async* {
  final c = ref.watch(loraControllerProvider);
  yield c.view;
  yield* c.changes;
});
