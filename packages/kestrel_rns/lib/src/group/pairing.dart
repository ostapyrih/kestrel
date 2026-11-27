import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hashes.dart';
import '../crypto/random.dart';
import '../crypto/token.dart';
import '../destination.dart';
import '../identity.dart';
import '../link/link.dart';
import '../msgpack/msgpack.dart';
import '../reticulum.dart';
import '../util.dart';
import 'group_models.dart';
import 'group_state.dart';

/// Direct device pairing without the bridge (docs/device-sync.md part 2).
///
/// The existing device ("host") shows a QR with its device key, a one-time
/// secret and an expiry. The new device scans it, links directly over RNS
/// (TCP or LoRa, whatever reaches) to the host's pairing destination,
/// identifies with its own device key and proves knowledge of the secret.
/// Both screens show the same 6 digit code. After the host user approved, the
/// host answers with the [PairingBundle] encrypted under a key derived from
/// the secret and the link id; the new device user confirms the code too,
/// and only then does the host add the device to the group.
const List<String> pairingAspects = ['group', 'pair'];
const String pairingApp = 'kestrel';

enum PairingError {
  invalidInvite,
  expired,
  noPath,
  linkFailed,
  badProof,
  rejected,
  timeout,
  badBundle,
  cancelled,
}

class PairingException implements Exception {
  PairingException(this.error, [this.detail]);
  final PairingError error;
  final String? detail;
  @override
  String toString() =>
      'PairingException(${error.name}${detail == null ? '' : ': $detail'})';
}

/// The content of the pairing QR code.
class PairingInvite {
  PairingInvite({
    required this.hostPublicKey,
    required this.secret,
    required this.expiresAt,
    required this.hostName,
  });

  static const String prefix = 'kestrel-group:v1:';

  /// The host's device key (public, 64 bytes).
  final Uint8List hostPublicKey;

  /// One-time secret (32 bytes): only ever in the QR code.
  final Uint8List secret;

  /// Unix seconds.
  final int expiresAt;
  final String hostName;

  bool expired({int? nowSeconds}) =>
      (nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000) >=
      expiresAt;

  String encode() {
    final b = packb({
      'pub': hostPublicKey,
      'secret': secret,
      'exp': expiresAt,
      'name': hostName,
    });
    return '$prefix${base64Url.encode(b).replaceAll('=', '')}';
  }

  /// Parses the QR text; null if it is not a valid invite. Unknown payload
  /// keys are ignored.
  static PairingInvite? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    try {
      var s = t.substring(prefix.length);
      s += '=' * ((4 - s.length % 4) % 4);
      final o = unpackb(base64Url.decode(s));
      if (o is! Map) return null;
      final pub = o['pub'];
      final secret = o['secret'];
      final exp = o['exp'];
      final name = o['name'];
      if (pub is! Uint8List ||
          pub.length != Identity.keySize ||
          secret is! Uint8List ||
          secret.length != 32 ||
          exp is! int) {
        return null;
      }
      return PairingInvite(
        hostPublicKey: pub,
        secret: secret,
        expiresAt: exp,
        hostName: name is String ? name : '',
      );
    } on Object {
      return null;
    }
  }
}

final Uint8List _proofTag =
    Uint8List.fromList(utf8.encode('kestrel-group-pair-proof'));
final Uint8List _doneTag =
    Uint8List.fromList(utf8.encode('kestrel-group-pair-done'));

Uint8List _proof(
        List<int> secret, List<int> linkId, List<int> pub, List<int> nonce) =>
    hmacSha256(secret, [..._proofTag, ...linkId, ...pub, ...nonce]);

Uint8List _bundleKey(List<int> secret, List<int> linkId) => hkdf(
      length: 64,
      deriveFrom: secret,
      salt: linkId,
      context: utf8.encode('kestrel-group-pair-bundle'),
    );

/// The 6 digit comparison code both screens show for this link.
String pairingCode(List<int> secret, List<int> linkId) {
  final b = hkdf(
    length: 4,
    deriveFrom: secret,
    salt: linkId,
    context: utf8.encode('kestrel-group-pair-code'),
  );
  final n = (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) % 1000000;
  return n.toString().padLeft(6, '0');
}

/// A pairing request as the host user sees it.
class PairingRequest {
  PairingRequest({
    required this.name,
    required this.platform,
    required this.code,
    required this.device,
  });
  final String name;
  final String platform;

  /// Must equal the code on the new device's screen.
  final String code;
  final GroupDevice device;
}

/// Pairing, existing-device side.
class PairingHost {
  PairingHost._(this._rns, this.destination, this.invite, this._secret,
      this._hostId, this._opts);

  final Reticulum _rns;
  final Destination destination;
  final PairingInvite invite;
  final Uint8List _secret;
  final String _hostId;
  final _HostOpts _opts;

  int _failures = 0;
  bool _busy = false;
  bool _consumed = false;
  bool _closed = false;
  Uint8List? _pendingLink;
  GroupDevice? _pendingDevice;
  Timer? _expiry;

  /// Maximum number of failed proofs before the invite is dropped.
  static const int maxFailures = 3;

  bool get isOpen => !_closed && !_consumed;

  /// Opens a pairing window. [confirm] asks the host user (showing the code),
  /// [buildBundle] is called after approval with the record of the new device
  /// and returns what to send, [onPaired] runs when the new device's user
  /// confirmed as well (add the device to the group there).
  static Future<PairingHost> open(
    Reticulum rns,
    Identity deviceKey, {
    required String hostName,
    required Future<bool> Function(PairingRequest) confirm,
    required Future<PairingBundle> Function(GroupDevice newDevice) buildBundle,
    required void Function(GroupDevice newDevice) onPaired,
    Duration ttl = const Duration(minutes: 10),
    RandomBytes? random,
    int Function()? clockSeconds,
  }) async {
    final rnd = random ?? secureRandomBytes;
    final clock =
        clockSeconds ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dest =
        await rns.createDestination(deviceKey, pairingApp, pairingAspects);
    final invite = PairingInvite(
      hostPublicKey: Uint8List.fromList(deviceKey.publicKey),
      secret: rnd(32),
      expiresAt: clock() + ttl.inSeconds,
      hostName: hostName,
    );
    final host = PairingHost._(
      rns,
      dest,
      invite,
      invite.secret,
      toHex(deviceKey.hash),
      _HostOpts(confirm, buildBundle, onPaired, clock),
    );
    dest.registerRequestHandler('/pair', host._onPair,
        policy: RequestPolicy.all);
    dest.registerRequestHandler('/pair/done', host._onDone,
        policy: RequestPolicy.all);
    host._expiry = Timer(ttl, host.close);
    return host;
  }

  /// Announces the pairing destination so the new device can find a path
  /// (call when the invite is shown and when the connection comes up).
  Future<bool> announce() => _rns.announce(destination);

  Future<Object?> _onPair(String path, Object? data, Uint8List requestId,
      Uint8List linkId, Identity? remote, double at) async {
    Map<String, Object?> fail(String e) => {'ok': false, 'err': e};
    if (_closed || _consumed) return fail('closed');
    if (invite.expired(nowSeconds: _opts.clock())) return fail('expired');
    if (_busy) return fail('busy');
    if (data is! Map || remote == null) return fail('bad_request');
    final pub = data['pub'];
    final name = data['name'];
    final platform = data['platform'];
    final nonce = data['nonce'];
    final proof = data['proof'];
    if (pub is! Uint8List ||
        pub.length != Identity.keySize ||
        name is! String ||
        platform is! String ||
        nonce is! Uint8List ||
        proof is! Uint8List ||
        !constantTimeEquals(remote.publicKey, pub)) {
      return _bad();
    }
    if (!constantTimeEquals(proof, _proof(_secret, linkId, pub, nonce))) {
      return _bad();
    }
    final dev = GroupDevice.of(Identity.fromPublicKey(pub),
        name: name.trim().isEmpty ? 'Device' : name.trim(), platform: platform);
    if (dev.id == _hostId) return fail('bad_request');
    _busy = true;
    try {
      final ok = await _opts.confirm(PairingRequest(
        name: dev.name,
        platform: dev.platform,
        code: pairingCode(_secret, linkId),
        device: dev,
      ));
      if (!ok || _closed) {
        await close();
        return fail('rejected');
      }
      final bundle = await _opts.buildBundle(dev);
      final sealed =
          await Token(_bundleKey(_secret, linkId)).encrypt(bundle.pack());
      _consumed = true;
      _pendingLink = Uint8List.fromList(linkId);
      _pendingDevice = dev;
      return {'ok': true, 'bundle': sealed};
    } finally {
      _busy = false;
    }
  }

  Map<String, Object?> _bad() {
    _failures += 1;
    if (_failures >= maxFailures) unawaited(close());
    return {'ok': false, 'err': 'bad_proof'};
  }

  Future<Object?> _onDone(String path, Object? data, Uint8List requestId,
      Uint8List linkId, Identity? remote, double at) async {
    final dev = _pendingDevice;
    final pl = _pendingLink;
    if (dev == null || pl == null || !constantTimeEquals(pl, linkId)) {
      return {'ok': false, 'err': 'no_pairing'};
    }
    if (data is! Map ||
        data['proof'] is! Uint8List ||
        !constantTimeEquals(data['proof']! as Uint8List,
            hmacSha256(_secret, [..._doneTag, ...linkId]))) {
      return {'ok': false, 'err': 'bad_proof'};
    }
    _pendingDevice = null;
    _pendingLink = null;
    _opts.onPaired(dev);
    unawaited(close());
    return {'ok': true};
  }

  /// Closes the pairing window (the invite stops working).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    _unregister();
  }

  void _unregister() {
    _rns.transport.deregisterDestination(destination);
  }
}

class _HostOpts {
  _HostOpts(this.confirm, this.buildBundle, this.onPaired, this.clock);
  final Future<bool> Function(PairingRequest) confirm;
  final Future<PairingBundle> Function(GroupDevice) buildBundle;
  final void Function(GroupDevice) onPaired;
  final int Function() clock;
}

/// Result of a successful [PairingClient.join].
class PairingResult {
  PairingResult(this.bundle, this.host);
  final PairingBundle bundle;

  /// The host's device record (null if the host did not list itself).
  final GroupDevice? host;
}

/// Pairing, new-device side.
class PairingClient {
  PairingClient._();

  /// Joins the group of the device that showed [invite].
  ///
  /// [onCode] receives the comparison code as soon as it is known (show it);
  /// [confirm] is the final "the codes match" decision of this device's user.
  /// On any failure or a negative [confirm] nothing is kept and the host does
  /// not add the device.
  static Future<PairingResult> join(
    Reticulum rns,
    Identity deviceKey,
    PairingInvite invite, {
    required String name,
    required String platform,
    required void Function(String code) onCode,
    required Future<bool> Function(String code) confirm,
    Duration pathTimeout = const Duration(seconds: 30),
    Duration approvalTimeout = const Duration(minutes: 3),
    RandomBytes? random,
    int Function()? clockSeconds,
  }) async {
    final rnd = random ?? secureRandomBytes;
    final now =
        (clockSeconds ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000)();
    if (invite.expired(nowSeconds: now)) {
      throw PairingException(PairingError.expired);
    }
    final hash = rns.rememberDestination(
        invite.hostPublicKey, pairingApp, pairingAspects);
    final dest = rns.recallDestination(hash, pairingApp, pairingAspects);
    if (dest == null) throw PairingException(PairingError.invalidInvite);
    if (!await rns.transport.awaitPath(hash, timeout: pathTimeout)) {
      throw PairingException(PairingError.noPath);
    }
    final Link link;
    try {
      link = await rns.connect(dest, pathTimeout: pathTimeout);
    } on Object catch (e) {
      throw PairingException(PairingError.linkFailed, '$e');
    }
    try {
      await link.identify(deviceKey);
      final code = pairingCode(invite.secret, link.linkId);
      onCode(code);
      final nonce = rnd(16);
      final rr = await link.request(
        '/pair',
        data: {
          'pub': deviceKey.publicKey,
          'name': name,
          'platform': platform,
          'nonce': nonce,
          'proof':
              _proof(invite.secret, link.linkId, deviceKey.publicKey, nonce),
        },
        timeout: approvalTimeout.inMilliseconds / 1000,
      );
      if (rr == null) throw PairingException(PairingError.linkFailed);
      await rr.done;
      if (rr.status != RequestStatus.ready) {
        throw PairingException(PairingError.timeout);
      }
      final r = rr.response;
      if (r is! Map || r['ok'] != true) {
        final err = r is Map ? r['err'] : null;
        throw PairingException(
            switch (err) {
              'expired' => PairingError.expired,
              'rejected' => PairingError.rejected,
              'bad_proof' => PairingError.badProof,
              _ => PairingError.linkFailed,
            },
            err is String ? err : null);
      }
      final sealed = r['bundle'];
      if (sealed is! Uint8List) throw PairingException(PairingError.badBundle);
      PairingBundle? bundle;
      try {
        bundle = PairingBundle.unpack(
            await Token(_bundleKey(invite.secret, link.linkId))
                .decrypt(sealed));
      } on Object {
        bundle = null;
      }
      if (bundle == null) throw PairingException(PairingError.badBundle);
      if (!await confirm(code)) throw PairingException(PairingError.cancelled);
      final done = await link.request(
        '/pair/done',
        data: {
          'proof': hmacSha256(invite.secret, [..._doneTag, ...link.linkId])
        },
        timeout: 30,
      );
      if (done == null) throw PairingException(PairingError.linkFailed);
      await done.done;
      final d = done.response;
      if (done.status != RequestStatus.ready || d is! Map || d['ok'] != true) {
        throw PairingException(PairingError.linkFailed, 'host did not finish');
      }
      final hostId = toHex(truncatedHash(invite.hostPublicKey));
      return PairingResult(bundle, bundle.state.devices[hostId]);
    } finally {
      unawaited(link.teardown());
    }
  }
}
