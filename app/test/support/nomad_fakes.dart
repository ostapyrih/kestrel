import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel/nomadnet/browser_controller.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

class FakeFetch implements NomadFetch {
  FakeFetch(this.path, this.data, this.identify);
  final String path;
  final Map<String, String>? data;
  final bool identify;
  final done = Completer<NomadResult>();
  final progressC = StreamController<NomadProgress>.broadcast();
  bool cancelled = false;

  @override
  Stream<NomadProgress> get progress => progressC.stream;
  @override
  Future<NomadResult> get result => done.future;
  @override
  bool get isDone => done.isCompleted;
  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!done.isCompleted) {
      done.completeError(NomadException(NomadFailure.cancelled));
      unawaited(done.future.then<void>((_) {}, onError: (_) {}));
    }
  }

  void respond(String text, {int hops = 2}) => done.complete(
    NomadResult(
      data: Uint8List.fromList(utf8.encode(text)),
      elapsed: const Duration(milliseconds: 1500),
      transferSize: 100,
      hops: hops,
    ),
  );

  void respondFile(String name, List<int> bytes) => done.complete(
    NomadResult(
      data: Uint8List.fromList(bytes),
      fileName: name,
      elapsed: const Duration(seconds: 1),
    ),
  );

  void fail(NomadFailure f) {
    done.completeError(NomadException(f));
    unawaited(done.future.then<void>((_) {}, onError: (_) {}));
  }
}

class FakeSaver implements FileSaver {
  final saved = <(String, Uint8List)>[];
  bool cancel = false;
  @override
  Future<String?> save(String fileName, Uint8List bytes) async {
    if (cancel) return null;
    saved.add((fileName, bytes));
    return '/downloads/$fileName';
  }
}

