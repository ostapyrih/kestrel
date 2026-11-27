@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// NomadNet client against `tools/it/nomad_node.py`: a real RNS destination
/// with the request handlers of nomadnet/Node.py.
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer peer;
  late Reticulum dart;
  late NomadClient client;
  late Uint8List hash;

  setUp(() async {
    peer = await PythonPeer.start(script: 'nomad_node.py');
    dart = await node(peer.port);
    client = NomadClient(
      dart,
      idleTimeout: const Duration(seconds: 3),
      stallTimeout: const Duration(seconds: 30),
    );
    hash = fromHex(peer.destHash);
  });
  tearDown(() async {
    await client.close();
    await dart.stop();
    await peer.stop();
  });

  test('discovers the node from its announce (name decoded)', () async {
    final found = dart.announces
        .map(NomadNodeAnnounce.fromEvent)
        .where((n) => n != null)
        .first
        .timeout(const Duration(seconds: 15));
    peer.send({'cmd': 'announce'});
    final n = (await found)!;
    expect(n.hashHex, peer.destHash);
    expect(n.name, 'Kestrel Test Node');
  });

  test('fetches the index page and reuses the link', () async {
    peer.send({'cmd': 'announce'});
    final phases = <NomadPhase>[];
    final f = client.fetch(hash, '/page/index.mu');
    f.progress.listen((p) => phases.add(p.phase));
    final r = await f.result.timeout(const Duration(seconds: 30));
    expect(r.isFile, isFalse);
    expect(r.text, startsWith('#!c=0\n>Test Node'));
    expect(phases, contains(NomadPhase.connecting));
    expect(client.hasLink(hash), isTrue);

    final again = client.fetch(hash, '/page/index.mu');
    final reused = again.progress.firstWhere(
      (p) => p.phase == NomadPhase.requesting,
    );
    await again.result;
    expect((await reused).reusedLink, isTrue);
    // one link only
    expect(peer.has('link_established'), isTrue);
    await peer.waitFor('link_established');
    expect(peer.has('link_established'), isFalse);
  });

  test('submits a form: field_* and var_* arrive as NomadNet sends them',
      () async {
    peer.send({'cmd': 'announce'});
    final data = buildNomadRequestData(
      ['*', 'from=index'],
      {'name': 'Оля', 'color': 'blue'},
    );
    expect(data, {
      'var_from': 'index',
      'field_name': 'Оля',
      'field_color': 'blue',
    });
    final r = await client
        .fetch(hash, '/page/form.mu', data: data)
        .result
        .timeout(const Duration(seconds: 30));
    expect(
      r.text,
      '>Form result\nfield_color=blue\nfield_name=Оля\nvar_from=index',
    );
  });

  test('a large page (300 KB) arrives as a Resource with progress', () async {
    peer.send({'cmd': 'announce'});
    final progress = <double>[];
    final f = client.fetch(hash, '/page/big.mu');
    f.progress.listen((p) {
      if (p.phase == NomadPhase.receiving) progress.add(p.progress);
    });
    final r = await f.result.timeout(const Duration(seconds: 60));
    expect(r.data.length, peer.ready['big_page_size']);
    expect(r.text, endsWith('END-OF-BIG-PAGE'));
    expect(progress, isNotEmpty);
  });

  test('a small file: name from the metadata', () async {
    peer.send({'cmd': 'announce'});
    final r = await client
        .fetch(hash, '/file/small.txt')
        .result
        .timeout(const Duration(seconds: 30));
    expect(r.fileName, 'small.txt');
    expect(utf8.decode(r.data), 'hello from the node\n');
  });

  test('a 3 MiB file arrives as a multi-segment resource', () async {
    peer.send({'cmd': 'announce'});
    final progress = <double>[];
    final f = client.fetch(hash, '/file/big.bin');
    f.progress.listen((p) {
      if (p.phase == NomadPhase.receiving) progress.add(p.progress);
    });
    final r = await f.result.timeout(const Duration(seconds: 120));
    expect(r.fileName, 'big.bin');
    expect(r.data.length, peer.ready['big_file_size']);
    expect(toHex(sha256(r.data)), peer.ready['big_file_sha256']);
    // progress spans all segments and ends near 1
    expect(progress.last, greaterThan(0.6));
  });

  test('a file above the client limit is refused with tooLarge', () async {
    peer.send({'cmd': 'announce'});
    final small = NomadClient(dart, maxFileSize: 1000000);
    addTearDown(small.close);
    await expectLater(
      small.fetch(hash, '/file/big.bin').result.timeout(
            const Duration(seconds: 30),
          ),
      throwsA(
        isA<NomadException>().having(
          (e) => e.failure,
          'failure',
          NomadFailure.tooLarge,
        ),
      ),
    );
  });

  test('identify() is optional: off by default, reveals identity when on',
      () async {
    peer.send({'cmd': 'announce'});
    var r = await client
        .fetch(hash, '/page/whoami.mu')
        .result
        .timeout(const Duration(seconds: 30));
    expect(r.text, contains('identity=none'));
    client.disconnect(hash);
    final me = await Identity.generate();
    final seen = peer.waitFor('remote_identified');
    r = await client
        .fetch(hash, '/page/whoami.mu', identify: true, identity: me)
        .result
        .timeout(const Duration(seconds: 30));
    expect((await seen)['identity'], toHex(me.hash));
    expect(r.text, contains('identity=${toHex(me.hash)}'));
  });

  test('cancel aborts a transfer', () async {
    peer.send({'cmd': 'announce'});
    final f = client.fetch(hash, '/file/big.bin');
    final first = f.progress.firstWhere(
      (p) => p.phase == NomadPhase.receiving,
    );
    await first.timeout(const Duration(seconds: 60));
    await f.cancel();
    await expectLater(
      f.result,
      throwsA(
        isA<NomadException>().having(
          (e) => e.failure,
          'failure',
          NomadFailure.cancelled,
        ),
      ),
    );
  });

  test('an unknown page fails (node does not answer)', () async {
    peer.send({'cmd': 'announce'});
    final f = client.fetch(hash, '/page/nope.mu');
    await expectLater(
      f.result.timeout(const Duration(seconds: 90)),
      throwsA(isA<NomadException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('an idle link is torn down', () async {
    peer.send({'cmd': 'announce'});
    await client.fetch(hash, '/page/index.mu').result;
    expect(client.hasLink(hash), isTrue);
    final closed = peer.waitFor('link_closed');
    await closed.timeout(const Duration(seconds: 15));
    expect(client.hasLink(hash), isFalse);
  });
}
