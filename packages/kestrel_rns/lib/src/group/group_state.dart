import 'dart:typed_data';

import '../crypto/random.dart';
import '../destination.dart';
import '../identity.dart';
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
    this.identityGen = 0,
    this.identityHash = '',
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

  /// Generation of the group identity G: 0 until the first "Change address",
  /// then +1 for every change (an `identity` sync record carries it).
  int identityGen;

  /// Hex hash of the identity of generation [identityGen] ('' = unknown, the
  /// initial G of an old install).
  String identityHash;

  /// Whether an identity change of generation [gen] to [hash] supersedes the
  /// current one: higher generation wins, at equal generations the larger hash
  /// (deterministic, so two devices that changed at once converge). The same
  /// change twice is not newer.
  bool isNewerIdentity(int gen, String hash) =>
      gen > identityGen ||
      (gen == identityGen && hash.compareTo(identityHash) > 0);

  /// Records [gen]/[hash] as the current identity if it is newer; true if it
  /// was adopted.
  bool adoptIdentity(int gen, String hash) {
    if (!isNewerIdentity(gen, hash)) return false;
    identityGen = gen;
    identityHash = hash;
    return true;
  }

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
        'id_gen': identityGen,
        'id_hash': identityHash,
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
      identityGen: o['id_gen'] is int ? o['id_gen']! as int : 0,
      identityHash: o['id_hash'] is String ? o['id_hash']! as String : '',
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

/// The `identity` sync record: the whole group moves to a new main identity
/// G' ("Change address"). Travels like every record (encrypted with
/// `VaultCrypto.encryptBlob`); the private key never leaves the group.
class IdentityChange {
  IdentityChange({
    required this.privateKey,
    required this.gen,
    required this.replaces,
    this.name = '',
    this.nameRev = 0,
    this.ratchets = const [],
    this.stamp,
    this.timebase = 0,
  });

  /// Version of the record layout.
  static const version = 1;

  /// G' private key (64 bytes, `Identity.privateKey`).
  final Uint8List privateKey;

  /// Monotonic generation; the highest wins.
  final int gen;

  /// Hex hash of the identity this one replaces.
  final String replaces;
  final String name;
  final int nameRev;

  /// Fresh ratchet list of G' (newest first).
  final List<RatchetEntry> ratchets;

  /// Announce stamp of G', if the sender already has it.
  final Uint8List? stamp;

  /// Announce stamp time base ("announce stamp" of the group).
  final int timebase;

  /// Hex hash of the new identity (what [GroupState.identityHash] holds).
  Future<String> newHash() async =>
      toHex((await Identity.fromPrivateKey(privateKey)).hash);

  Map<String, Object?> toMap() => {
        'v': version,
        'priv': privateKey,
        'gen': gen,
        'replaces': replaces,
        'name': name,
        'name_rev': nameRev,
        'ratchets': [
          for (final r in ratchets) {'k': r.key, 't': r.createdAt}
        ],
        if (stamp != null) 'stamp': stamp,
        'tb': timebase,
      };

  static IdentityChange? fromMap(Object? o) {
    if (o is! Map || o['v'] != version) return null;
    final priv = o['priv'];
    final gen = o['gen'];
    final replaces = o['replaces'];
    if (priv is! Uint8List ||
        priv.length != 64 ||
        gen is! int ||
        gen < 1 ||
        replaces is! String) {
      return null;
    }
    final rs = <RatchetEntry>[];
    for (final e in (o['ratchets'] as List? ?? const [])) {
      if (e is Map && e['k'] is Uint8List && e['t'] is int) {
        rs.add(RatchetEntry(e['k']! as Uint8List, e['t']! as int));
      }
    }
    return IdentityChange(
      privateKey: priv,
      gen: gen,
      replaces: replaces,
      name: o['name'] is String ? o['name']! as String : '',
      nameRev: o['name_rev'] is int ? o['name_rev']! as int : 0,
      ratchets: rs,
      stamp: o['stamp'] is Uint8List ? o['stamp']! as Uint8List : null,
      timebase: o['tb'] is int ? o['tb']! as int : 0,
    );
  }
}
