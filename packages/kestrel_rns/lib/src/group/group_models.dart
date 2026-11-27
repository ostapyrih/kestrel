import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../identity.dart';
import '../lxmf/lx_message.dart';
import '../util.dart';

/// One device of the user's device group (docs/device-sync.md).
///
/// [id] is the hex identity hash of the hidden device key (the same value the
/// bridge uses as its device id). The device key is never shown to the user
/// and never used for chats; the user-visible address is the group identity G.
class GroupDevice {
  GroupDevice({
    required this.id,
    required this.publicKey,
    required this.name,
    required this.platform,
    required this.addedAt,
    this.rev = 1,
    this.removed = false,
  });

  /// Builds a record for [deviceKey] (public part is enough).
  factory GroupDevice.of(
    Identity deviceKey, {
    required String name,
    required String platform,
    int? addedAt,
  }) =>
      GroupDevice(
        id: toHex(deviceKey.hash),
        publicKey: Uint8List.fromList(deviceKey.publicKey),
        name: name,
        platform: platform,
        addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
      );

  final String id;
  final Uint8List publicKey;
  String name;
  final String platform;

  /// Unix milliseconds.
  final int addedAt;

  /// Monotonic revision of this record; the higher one wins on merge.
  int rev;

  /// Tombstone: the device was removed from the group.
  bool removed;

  /// LXMF delivery address of the device key (the sync channel address).
  Uint8List get lxmfAddress =>
      LXMessage.deliveryHash(Identity.fromPublicKey(publicKey));

  GroupDevice copy() => GroupDevice(
        id: id,
        publicKey: publicKey,
        name: name,
        platform: platform,
        addedAt: addedAt,
        rev: rev,
        removed: removed,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'pub': publicKey,
        'name': name,
        'platform': platform,
        'added': addedAt,
        'rev': rev,
        'removed': removed,
      };

  /// Null if malformed or if [id] is not the hash of the public key (a
  /// sibling cannot smuggle a record under another device id).
  static GroupDevice? fromMap(Object? o) {
    if (o is! Map) return null;
    final id = o['id'];
    final pub = o['pub'];
    final name = o['name'];
    final platform = o['platform'];
    final added = o['added'];
    final rev = o['rev'];
    if (id is! String ||
        pub is! Uint8List ||
        pub.length != Identity.keySize ||
        name is! String ||
        platform is! String ||
        added is! int ||
        rev is! int ||
        rev < 1) {
      return null;
    }
    if (toHex(truncatedHash(pub)) != id) return null;
    return GroupDevice(
      id: id,
      publicKey: Uint8List.fromList(pub),
      name: name.length > 64 ? name.substring(0, 64) : name,
      platform: platform.length > 32 ? platform.substring(0, 32) : platform,
      addedAt: added,
      rev: rev,
      removed: o['removed'] == true,
    );
  }
}

/// The device list: a map by device id merged per record by [GroupDevice.rev]
/// (higher wins; at equal revisions a tombstone wins, then the larger name).
/// Merging is order independent and repeatable.
class DeviceList {
  DeviceList([Iterable<GroupDevice> devices = const []]) {
    for (final d in devices) {
      _m[d.id] = d;
    }
  }

  final Map<String, GroupDevice> _m = {};

  Iterable<GroupDevice> get all => _m.values;
  Iterable<GroupDevice> get active => _m.values.where((d) => !d.removed);
  GroupDevice? operator [](String id) => _m[id];
  bool isActive(String id) => _m[id]?.removed == false;

  /// Adds or replaces a record learned locally (e.g. a freshly paired
  /// device); the revision continues above an existing one.
  void put(GroupDevice d) {
    final cur = _m[d.id];
    if (cur != null && d.rev <= cur.rev) d.rev = cur.rev + 1;
    _m[d.id] = d;
  }

  /// Renames [id]; returns the updated record or null.
  GroupDevice? rename(String id, String name) {
    final d = _m[id];
    if (d == null || d.removed) return null;
    d
      ..name = name
      ..rev += 1;
    return d;
  }

  /// Marks [id] as removed (durable tombstone). Null if unknown or already
  /// removed.
  GroupDevice? remove(String id) {
    final d = _m[id];
    if (d == null || d.removed) return null;
    d
      ..removed = true
      ..rev += 1;
    return d;
  }

  /// Merges [incoming]; returns true if anything changed.
  bool merge(Iterable<GroupDevice> incoming) {
    var changed = false;
    for (final n in incoming) {
      final cur = _m[n.id];
      if (cur == null) {
        _m[n.id] = n.copy();
        changed = true;
        continue;
      }
      final win = n.rev > cur.rev ||
          (n.rev == cur.rev &&
              ((n.removed && !cur.removed) ||
                  (n.removed == cur.removed &&
                      n.name.compareTo(cur.name) > 0)));
      if (win) {
        _m[n.id] = n.copy();
        changed = true;
      }
    }
    return changed;
  }

  List<Object?> toList() => [for (final d in _m.values) d.toMap()];

  static DeviceList fromList(Object? o) {
    final l = DeviceList();
    if (o is List) {
      for (final e in o) {
        final d = GroupDevice.fromMap(e);
        if (d != null) l._m[d.id] = d;
      }
    }
    return l;
  }
}
