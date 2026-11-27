import 'dart:async';
import 'dart:convert';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../node/identity_store.dart';
import '../platform.dart';
import '../storage/database.dart';
import '../storage/repo.dart';

/// The user's device group on this device (docs/device-sync.md).
///
/// Holds the three keys ([IdentityStore]: group identity G, hidden device key,
/// legacy B) and the replicated [GroupState] (device list, sync key chain,
/// shared display name, announce timebase). Every install is a group, of one
/// device until another one pairs. Pairing, removal and "Change address" live
/// here; running the network (announces, sending notices) is [NodeService].
class GroupService {
  GroupService({required this.repo, required this.secrets})
    : ids = IdentityStore(secrets);

  final Repo repo;
  final SecretStore secrets;
  final IdentityStore ids;

  static const stateKey = 'kestrel.group.state';

  late Identity _g;
  late Identity _device;
  late GroupState _state;
  Identity? _legacy;
  bool _ready = false;
  final _changes = StreamController<void>.broadcast();

  bool get isReady => _ready;

  /// Fires whenever the group state or the keys changed.
  Stream<void> get changes => _changes.stream;

  /// The group identity G ("my address").
  Identity get groupIdentity => _g;

  /// The hidden device key.
  Identity get deviceIdentity => _device;

  /// The old identity B while this device is still registered with the bridge
  /// under it; null once the bridge knows the device key.
  Identity? get legacyIdentity => _legacy;

  GroupState get state => _state;

  /// This device's record (id = hex hash of the device key).
  GroupDevice get self => _state.devices[_ownId]!;
  String get _ownId => toHex(_device.hash);
  String get ownId => _ownId;

  /// Devices of the group that were not removed, own device first.
  List<GroupDevice> get devices {
    final l = _state.devices.active.toList()
      ..sort((a, b) {
        if (a.id == _ownId) return -1;
        if (b.id == _ownId) return 1;
        return a.addedAt.compareTo(b.addedAt);
      });
    return l;
  }

  /// More than one device is in the group.
  bool get isGroup => _state.devices.active.length > 1;

  /// Loads or creates the keys and the group state. On an existing install G
  /// is the old identity B (same key, same address) and the old B also stays
  /// as the legacy bridge key.
  Future<void> init() async {
    final hadB =
        (await secrets.read('kestrel.identity_b.private_key'))?.isNotEmpty ??
        false;
    _g = await ids.loadOrCreate();
    _device = await ids.loadOrCreateDeviceKey();
    _legacy = await ids.loadLegacy();
    final raw = await secrets.read(stateKey);
    GroupState? s;
    if (raw != null && raw.isNotEmpty) {
      try {
        s = GroupState.decode(base64.decode(raw));
      } on Object {
        s = null;
      }
    }
    if (s == null) {
      // First start of a version with device groups. An install that already
      // had identity B keeps it as G; the bridge (if it was paired) still
      // knows the device under B, so B is kept as the legacy bridge key.
      final paired =
          (await repo.getSetting(SettingKeys.bridgePubkey))?.isNotEmpty ??
          false;
      if (hadB && paired && _legacy == null) {
        _legacy = _g;
        await ids.saveLegacy(_g);
      }
      final name = await _deviceName();
      final dn = (await repo.getSetting(SettingKeys.displayName)) ?? '';
      s = GroupState.create(
        GroupDevice.of(_device, name: name, platform: platformId()),
        displayName: dn.trim(),
      );
      _state = s;
      await _save();
    } else {
      _state = s;
      // our own record must exist (e.g. state restored from a sibling)
      if (_state.devices[_ownId] == null) {
        _state.devices.put(
          GroupDevice.of(
            _device,
            name: await _deviceName(),
            platform: platformId(),
          ),
        );
        await _save();
      }
    }
    _ready = true;
  }

  Future<String> _deviceName() async {
    final n = (await repo.getSetting(SettingKeys.deviceName))?.trim();
    return (n == null || n.isEmpty) ? defaultDeviceName() : n;
  }

  Future<void> _save() async {
    await secrets.write(stateKey, base64.encode(_state.encode()));
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Persists after an external change of [state] (e.g. synced records).
  Future<void> persist() => _save();

  // ----------------------------------------------------------------- naming

  /// The one display name of G (synced to the other devices, used in
  /// announces).
  String get displayName => _state.displayName;

  Future<void> setDisplayName(String name) async {
    final n = name.trim();
    _state.setName(n);
    await repo.setSetting(SettingKeys.displayName, n);
    await _save();
  }

  /// Renames a device of the group (own or another one).
  Future<void> renameDevice(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    if (_state.devices.rename(id, n) == null) return;
    if (id == _ownId) await repo.setSetting(SettingKeys.deviceName, n);
    await _save();
  }

  // ---------------------------------------------------------------- pairing

  /// Opens a pairing window on this device: shows [PairingHost.invite] as QR.
  /// [confirm] asks the user whether the code on the new device matches.
  Future<PairingHost> startPairing(
    Reticulum rns, {
    required Destination groupDestination,
    required Future<bool> Function(PairingRequest) confirm,
    void Function(GroupDevice)? onPaired,
    Duration ttl = const Duration(minutes: 10),
  }) {
    return PairingHost.open(
      rns,
      _device,
      hostName: self.name,
      ttl: ttl,
      confirm: confirm,
      buildBundle: (dev) async {
        final snapshot = GroupState.decode(_state.encode())!;
        snapshot.devices.put(dev.copy());
        return PairingBundle(
          groupPrivateKey: _g.privateKey!,
          state: snapshot,
          ratchets: groupDestination.exportRatchets(),
          stamp: await rns.transport.exportStamp(groupDestination),
        );
      },
      onPaired: (dev) {
        _state.devices.put(dev);
        unawaited(_save());
        onPaired?.call(dev);
      },
    );
  }

  /// Applies the bundle of a successful join: G and the group state replace
  /// the local ones; the old identity B is kept as the legacy bridge key if
  /// the bridge knows this device by it. The caller retired the old chats
  /// first ([Repo.retireOwnHistory]) and restarts the router afterwards.
  Future<void> applyJoin(PairingBundle b, {required bool bridgePaired}) async {
    if (bridgePaired && _legacy == null) {
      _legacy = _g;
      await ids.saveLegacy(_g);
    }
    final newG = await Identity.fromPrivateKey(b.groupPrivateKey);
    await ids.saveGroupIdentity(newG);
    _g = newG;
    _state = b.state;
    if (_state.devices[_ownId] == null) {
      _state.devices.put(
        GroupDevice.of(
          _device,
          name: await _deviceName(),
          platform: platformId(),
        ),
      );
    }
    await repo.setSetting(SettingKeys.displayName, _state.displayName);
    await _save();
  }

  // ---------------------------------------------------------------- removal

  /// Removes another device: it is dropped from the list and the sync key
  /// rotates, so it can no longer read new records. It still holds G (the
  /// address key), so the UI offers "Change address" next. Returns the record
  /// or null (unknown, already removed, or this device).
  Future<GroupDevice?> removeDevice(String id) async {
    if (id == _ownId) return null;
    final d = _state.removeDevice(id);
    if (d != null) await _save();
    return d;
  }

  // ---------------------------------------------------------- change address

  /// Makes [fresh] the group identity G ("Change address"). The caller sent
  /// the notices from the old identity before and restarts the router after.
  Future<void> replaceGroupIdentity(Identity fresh) async {
    await ids.saveGroupIdentity(fresh);
    _state.adoptIdentity(_state.identityGen + 1, toHex(fresh.hash));
    _g = fresh;
    await _save();
  }

  /// Applies an `identity` record of a sibling (already adopted in [state] by
  /// [DeviceSync]): G' replaces G on this device.
  Future<Identity> applyIdentity(IdentityChange c) async {
    final fresh = await Identity.fromPrivateKey(c.privateKey);
    await ids.saveGroupIdentity(fresh);
    _g = fresh;
    if (c.name.isNotEmpty) {
      await repo.setSetting(SettingKeys.displayName, _state.displayName);
    }
    await _save();
    return fresh;
  }

  /// The bridge now knows this device by the device key: forget legacy B.
  Future<void> bridgeMigrated() async {
    _legacy = null;
    await ids.clearLegacy();
    await _save();
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}

/// The notice an address change sends to recent contacts.
String addressChangeNotice(String newAddressHex, {String? name}) {
  final who = (name == null || name.isEmpty) ? '' : ' ($name)';
  return 'Моя нова адреса Kestrel$who: $newAddressHex\n'
      'My new Kestrel address$who: $newAddressHex';
}

/// Parses a notice produced by [addressChangeNotice]; null if [text] is
/// something else. Lets the chat list offer "switch to the new address".
String? parseAddressChangeNotice(String text) {
  final m = RegExp(r'My new Kestrel address(?: \([^)]*\))?: ([0-9a-f]{32})')
      .firstMatch(text);
  return m?.group(1);
}
