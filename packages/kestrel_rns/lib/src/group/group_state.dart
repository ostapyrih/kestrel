import 'dart:typed_data';

import '../crypto/random.dart';
import '../destination.dart';
import '../msgpack/msgpack.dart';
import '../util.dart';
import '../vault_crypto.dart';
import 'group_models.dart';

/// Replicated state of a device group (everything except the keys of G and of
/// the device itself): group id, the sync key chain, the device list, the
/// shared display name and the announce timebase.
///
/// The key chain reuses the vault envelope crypto (`VaultCrypto`, bridge
/// protocol 9.4): epochs start at 1 and a removal rotates to a fresh random
/// key; all sync records are encrypted/decrypted only through
/// `VaultCrypto.encryptBlob` / `decryptBlob`.
class GroupState {
  GroupState({
    required this.groupId,
    required this.epoch,
    required Map<int, Uint8List> chain,
    required this.devices,
    this.displayName = '',
    this.nameRev = 0,
    this.timebase = 0,
  }) : chain = {...chain};

  /// A brand new group with this device as the only member.
  factory GroupState.create(
    GroupDevice self, {
    String displayName = '',
    RandomBytes? random,
  }) =>
      GroupState(
        groupId: toHex((random ?? secureRandomBytes)(16)),
        epoch: 1,
        chain: {1: VaultCrypto.generateGroupKey(random: random)},
        devices: DeviceList([self]),
        displayName: displayName,
        nameRev: displayName.isEmpty ? 0 : 1,
      );

  final String groupId;

  /// Current key epoch.
  int epoch;

  /// Group keys of every epoch this device knows (old ones read old blobs).
  final Map<int, Uint8List> chain;
  final DeviceList devices;

  /// The one display name of G, used in its announces.
  String displayName;
  int nameRev;

  /// Last announce emission time used by the group (monotonic timebase).
  int timebase;

  Uint8List get currentKey => chain[epoch]!;

  /// Sets the shared name locally (revision continues).
  void setName(String name) {
    displayName = name;
    nameRev += 1;
  }

  /// Merges a name from a sibling: the higher revision wins, at equal
  /// revisions the larger string (deterministic). Returns true if changed.
  bool mergeName(String name, int rev) {
    if (rev > nameRev || (rev == nameRev && name.compareTo(displayName) > 0)) {
      displayName = name;
      nameRev = rev;
      return true;
    }
    return false;
  }

  /// Merges the timebase value of a sibling (only forward).
  bool mergeTimebase(int t) {
    if (t <= timebase) return false;
    timebase = t;
    return true;
  }

  /// Merges a received chain (never drops a key). Returns true if changed.
  bool mergeChain(Map<int, Uint8List> incoming) {
    var changed = false;
    for (final e in incoming.entries) {
      if (!chain.containsKey(e.key)) {
        chain[e.key] = Uint8List.fromList(e.value);
        changed = true;
      }
    }
    final top = chain.keys.fold<int>(0, (a, b) => a > b ? a : b);
    if (top > epoch) {
      epoch = top;
      changed = true;
    }
    return changed;
  }

  /// Removes a device: stops syncing to it and rotates the sync key (new
  /// random epoch, never derived). Returns the removed record or null.
  ///
  /// Honest limit: the removed device still holds G (its private key), the
  /// old chain and the ratchets; only "Change address" helps against that.
  GroupDevice? removeDevice(String id, {RandomBytes? random}) {
    final d = devices.remove(id);
    if (d == null) return null;
    epoch += 1;
    chain[epoch] = VaultCrypto.generateGroupKey(random: random);
    return d;
  }

  Map<String, Object?> toMap() => {
        'v': 1,
        'gid': groupId,
        'epoch': epoch,
        'chain': VaultCrypto.packChain(chain),
        'devices': devices.toList(),
        'name': displayName,
        'name_rev': nameRev,
        'timebase': timebase,
      };

  Uint8List encode() => packb(toMap());

  static GroupState? fromMap(Object? o) {
    if (o is! Map || o['v'] != 1) return null;
    final gid = o['gid'];
    final epoch = o['epoch'];
    final chain = o['chain'];
    if (gid is! String || epoch is! int || chain is! Uint8List) return null;
    final Map<int, Uint8List> keys;
    try {
      keys = VaultCrypto.unpackChain(chain);
    } on VaultCryptoException {
      return null;
    }
    if (!keys.containsKey(epoch)) return null;
    return GroupState(
      groupId: gid,
      epoch: epoch,
      chain: keys,
      devices: DeviceList.fromList(o['devices']),
      displayName: o['name'] is String ? o['name']! as String : '',
      nameRev: o['name_rev'] is int ? o['name_rev']! as int : 0,
      timebase: o['timebase'] is int ? o['timebase']! as int : 0,
    );
  }

  static GroupState? decode(List<int> bytes) {
    try {
      return fromMap(unpackb(bytes));
    } on Object {
      return null;
    }
  }
}

/// What a joining device receives from the device that paired it (encrypted,
/// see `PairingHost`): the group identity G, the replicated state, the merged
/// ratchets of G and G's announce stamp.
class PairingBundle {
  PairingBundle({
    required this.groupPrivateKey,
    required this.state,
    this.ratchets = const [],
    this.stamp,
  });

  /// G's private key (64 bytes, `Identity.privateKey`).
  final Uint8List groupPrivateKey;
  final GroupState state;
  final List<RatchetEntry> ratchets;
  final Uint8List? stamp;

  Uint8List pack() => packb({
        'v': 1,
        'g': groupPrivateKey,
        'state': state.toMap(),
        'ratchets': [
          for (final r in ratchets) {'k': r.key, 't': r.createdAt}
        ],
        if (stamp != null) 'stamp': stamp,
      });

  static PairingBundle? unpack(List<int> bytes) {
    try {
      final o = unpackb(bytes);
      if (o is! Map || o['v'] != 1) return null;
      final g = o['g'];
      final state = GroupState.fromMap(o['state']);
      if (g is! Uint8List || g.length != 64 || state == null) return null;
      final rs = <RatchetEntry>[];
      for (final e in (o['ratchets'] as List? ?? const [])) {
        if (e is Map && e['k'] is Uint8List && e['t'] is int) {
          rs.add(RatchetEntry(e['k']! as Uint8List, e['t']! as int));
        }
      }
      final stamp = o['stamp'];
      return PairingBundle(
        groupPrivateKey: g,
        state: state,
        ratchets: rs,
        stamp: stamp is Uint8List ? stamp : null,
      );
    } on Object {
      return null;
    }
  }
}
