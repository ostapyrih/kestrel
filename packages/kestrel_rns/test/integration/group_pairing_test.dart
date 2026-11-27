@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import '../support/it_support.dart';
import '../support/python_peer.dart';

/// Direct device pairing (no bridge) between two Dart nodes that only meet
/// through a Python transport node.
void main() {
  if (findPython() == null) {
    test('python reference not available', () {}, skip: 'no tools/.venv');
    return;
  }

  late PythonPeer t;
  late Reticulum hostRns, newRns;
  late Identity hostKey, newKey, g;
  late GroupState state;
  late GroupDevice hostDev;
  PairingHost? host;
  var paired = <GroupDevice>[];
  String? hostCode;

  Future<PairingHost> openHost({
    bool approve = true,
    int Function()? clock,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    final h = await PairingHost.open(
      hostRns,
      hostKey,
      hostName: 'Host phone',
      ttl: ttl,
      clockSeconds: clock,
      confirm: (r) async {
        hostCode = r.code;
        return approve;
      },
      buildBundle: (dev) async {
        final s = GroupState.decode(state.encode())!..devices.put(dev.copy());
        return PairingBundle(
          groupPrivateKey: g.privateKey!,
          state: s,
          ratchets: [RatchetEntry(Identity.generateRatchet(), 42)],
          stamp: Uint8List(14),
        );
      },
      onPaired: paired.add,
    );
    host = h;
    await h.announce();
    return h;
  }

  setUp(() async {
    t = await PythonPeer.start(transport: true);
    hostRns = await node(t.port);
    newRns = await node(t.port);
    hostKey = await Identity.generate();
    newKey = await Identity.generate();
    g = await Identity.generate();
    hostDev = GroupDevice.of(hostKey, name: 'Host phone', platform: 'android');
    state = GroupState.create(hostDev, displayName: 'Alice');
    paired = [];
    hostCode = null;
  });

  tearDown(() async {
    await host?.close();
    host = null;
    await newRns.stop();
    await hostRns.stop();
    await t.stop();
  });

  Future<PairingResult> join(PairingInvite inv,
          {bool confirm = true, void Function(String)? onCode}) =>
      PairingClient.join(
        newRns,
        newKey,
        inv,
        name: 'New laptop',
        platform: 'windows',
        onCode: onCode ?? (_) {},
        confirm: (_) async => confirm,
        pathTimeout: const Duration(seconds: 15),
      );

  test('pairs, both sides see the same code, bundle arrives intact', () async {
    final h = await openHost();
    String? clientCode;
    final r = await join(
      PairingInvite.parse(h.invite.encode())!,
      onCode: (c) => clientCode = c,
    );
    expect(clientCode, isNotNull);
    expect(clientCode, hostCode);
    expect(r.bundle.groupPrivateKey, g.privateKey);
    expect(r.bundle.state.groupId, state.groupId);
    expect(r.bundle.state.currentKey, state.currentKey);
    expect(r.bundle.state.displayName, 'Alice');
    expect(r.bundle.ratchets.single.createdAt, 42);
    expect(r.host!.id, hostDev.id);
    expect(r.bundle.state.devices.isActive(toHex(newKey.hash)), isTrue);
    await until(() => paired.isNotEmpty);
    expect(paired.single.id, toHex(newKey.hash));
    expect(paired.single.name, 'New laptop');
    expect(paired.single.platform, 'windows');
    await until(() => !h.isOpen);
  });

  test('host rejects: client fails, nothing is added', () async {
    final h = await openHost(approve: false);
    await expectLater(
      join(h.invite),
      throwsA(isA<PairingException>()
          .having((e) => e.error, 'error', PairingError.rejected)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(paired, isEmpty);
    expect(h.isOpen, isFalse);
  });

  test('client user says the codes differ: the host never adds the device',
      () async {
    final h = await openHost();
    await expectLater(
      join(h.invite, confirm: false),
      throwsA(isA<PairingException>()
          .having((e) => e.error, 'error', PairingError.cancelled)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(paired, isEmpty);
  });

  test('a wrong secret is refused (bad proof); three failures close it',
      () async {
    final h = await openHost();
    final bad = PairingInvite(
      hostPublicKey: h.invite.hostPublicKey,
      secret: Uint8List(32),
      expiresAt: h.invite.expiresAt,
      hostName: 'x',
    );
    await expectLater(
      join(bad),
      throwsA(isA<PairingException>()
          .having((e) => e.error, 'error', PairingError.badProof)),
    );
    expect(hostCode, isNull, reason: 'the host user is never asked');
    expect(h.isOpen, isTrue);
    for (var i = 0; i < PairingHost.maxFailures - 1; i++) {
      await join(bad).then((_) {}, onError: (_) {});
    }
    await until(() => !h.isOpen);
  });

  test('an expired invite is refused locally without touching the network',
      () async {
    final h = await openHost();
    final old = PairingInvite(
      hostPublicKey: h.invite.hostPublicKey,
      secret: h.invite.secret,
      expiresAt: 1,
      hostName: 'x',
    );
    await expectLater(
      join(old),
      throwsA(isA<PairingException>()
          .having((e) => e.error, 'error', PairingError.expired)),
    );
  });

  test('the host refuses once its own window expired', () async {
    var now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final h = await openHost(clock: () => now, ttl: const Duration(minutes: 5));
    now += 3600; // the host clock moved on, the client still thinks it is valid
    await expectLater(
      join(h.invite),
      throwsA(isA<PairingException>()
          .having((e) => e.error, 'error', PairingError.expired)),
    );
    expect(hostCode, isNull);
  });
}
