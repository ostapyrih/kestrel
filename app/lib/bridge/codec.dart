import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

/// Wire shapes of the Kestrel bridge protocol v2 (docs/bridge-protocol.md).
///
/// Everything here is pure (no I/O) so it can be unit-tested against the
/// examples of the spec. Payloads are msgpack maps with string keys; hashes
/// are lower-case hex strings; binary fields are `Uint8List` (msgpack bin).

const int bridgeProtocolVersion = 2;

/// Prefix of the pairing QR text (spec 5.1).
const String pairingPrefix = 'kestrel-pair:v1:';

/// Domain separation of the approval signature (spec 5.2).
final Uint8List pairSigDomain = Uint8List.fromList(
  utf8.encode('kestrel-pair-approve:v1:'),
);

/// Lifetime of a pairing code (`limits.pairing_window`: default and maximum).
const int pairingWindowSeconds = 600;

final RegExp _platformRe = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');
final RegExp _hex128 = RegExp(r'[0-9a-fA-F]{128}');
final RegExp cmdIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

// ------------------------------------------------------------------- errors

/// An `{"ok": false, "error": ...}` response of the bridge.
class BridgeError implements Exception {
  BridgeError(this.code, [this.message = '', this.details = const {}]);

  factory BridgeError.fromMap(Object? o) {
    final m = o is Map ? asMap(o) : const <String, Object?>{};
    return BridgeError(
      (m['code'] as String?) ?? 'internal',
      (m['message'] as String?) ?? '',
      m['details'] is Map ? asMap(m['details']) : const {},
    );
  }

  final String code;
  final String message;
  final Map<String, Object?> details;

  /// Failures before anything was executed upstream: the `cmd_id` is released
  /// and the same command may be sent again later (spec 7.1).
  bool get retryable =>
      code == 'upstream_unavailable' ||
      code == 'upstream_auth' ||
      code == 'rate_limited';

  /// Seconds to wait for `rate_limited`.
  double? get retryAfter {
    final v = details['retry_after'];
    return v is num ? v.toDouble() : null;
  }

  @override
  String toString() => 'BridgeError($code: $message)';
}

/// No response at all (timeout, link closed, no route).
class BridgeTransportError implements Exception {
  BridgeTransportError(this.message, {this.rejected = false});
  final String message;

  /// The bridge closed the Link right after `identify()`: the key is unknown
  /// or revoked (spec 2.1).
  final bool rejected;

  @override
  String toString() => 'BridgeTransportError($message)';
}

// ------------------------------------------------------------------ helpers

Map<String, Object?> asMap(Object? o) {
  if (o is! Map) throw FormatException('expected a map, got ${o.runtimeType}');
  return {for (final e in o.entries) e.key! as String: e.value};
}

double? asDouble(Object? o) => o is num ? o.toDouble() : null;

int? asInt(Object? o) => o is num ? o.toInt() : null;

List<Map<String, Object?>> asMapList(Object? o) => [
  if (o is List)
    for (final e in o)
      if (e is Map) asMap(e),
];

String base64UrlNoPad(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List base64UrlDecodeNoPad(String s) {
  final padded = s.padRight((s.length + 3) ~/ 4 * 4, '=');
  return base64Url.decode(padded);
}

/// A fresh idempotency key: 25 characters of `[A-Za-z0-9]`.
String newCmdId([RandomBytes? random]) =>
    'k${toHex((random ?? secureRandomBytes)(12))}';

/// First 128-hex-character run in [text] (the public key of the bridge in
/// the `--print-address` output, or a bare key), lower-cased; else null.
String? extractBridgePublicKey(String text) =>
    _hex128.firstMatch(text)?.group(0)?.toLowerCase();

/// Hash of `kestrel.bridge` for the public key of S (hex), as hex.
Uint8List bridgeDestinationHash(List<int> bridgePublicKey) =>
    Destination.hashFor(
      Identity.fromPublicKey(bridgePublicKey),
      'kestrel',
      const ['bridge'],
    );

/// `lxmf.delivery` hash of S (target of the LXMF fallback).
Uint8List bridgeLxmfHash(List<int> bridgePublicKey) => Destination.hashFor(
  Identity.fromPublicKey(bridgePublicKey),
  'lxmf',
  const ['delivery'],
);

// ------------------------------------------------------------------ devices

class DeviceRecord {
  DeviceRecord({
    required this.deviceId,
    required this.publicKey,
    required this.name,
    required this.platform,
    required this.roles,
    required this.bootstrap,
    this.addedBy,
    this.addedAt,
    this.lastSeen,
    this.revokedAt,
    this.online = false,
  });

  factory DeviceRecord.fromMap(Map<String, Object?> m) => DeviceRecord(
    deviceId: m['device_id']! as String,
    publicKey: (m['public_key'] as String?) ?? '',
    name: (m['name'] as String?) ?? '',
    platform: (m['platform'] as String?) ?? 'unknown',
    roles: [
      if (m['roles'] is List)
        for (final r in m['roles']! as List)
          if (r is String) r,
    ],
    bootstrap: m['bootstrap'] == true,
    addedBy: m['added_by'] as String?,
    addedAt: asDouble(m['added_at']),
    lastSeen: asDouble(m['last_seen']),
    revokedAt: asDouble(m['revoked_at']),
    online: m['online'] == true,
  );

  final String deviceId;
  final String publicKey;
  final String name;
  final String platform;
  final List<String> roles;
  final bool bootstrap;
  final String? addedBy;
  final double? addedAt;
  final double? lastSeen;
  final double? revokedAt;
  final bool online;

  bool get isField => roles.contains('field');
  bool get isRevoked => revokedAt != null;
}

// -------------------------------------------------------------------- hello

class HelloResult {
  HelloResult({
    required this.protocolVersion,
    required this.minVersion,
    required this.maxVersion,
    required this.server,
    required this.time,
    required this.stateId,
    required this.cursor,
    required this.device,
    required this.capabilities,
    required this.compatOk,
    required this.meshchatxVersion,
    required this.vaultKeyEpoch,
    required this.vaultInUse,
    required this.limits,
  });

  factory HelloResult.fromMap(Map<String, Object?> m) {
    final compat = m['compat'] is Map ? asMap(m['compat']) : const {};
    final vault = m['vault'] is Map ? asMap(m['vault']) : const {};
    return HelloResult(
      protocolVersion: asInt(m['protocol_version']) ?? 0,
      minVersion: asInt(m['min_protocol_version']) ?? 0,
      maxVersion: asInt(m['max_protocol_version']) ?? 0,
      server: (m['server'] as String?) ?? '',
      time: asDouble(m['time']) ?? 0,
      stateId: (m['state_id'] as String?) ?? '',
      cursor: asInt(m['cursor']) ?? 0,
      device: DeviceRecord.fromMap(asMap(m['device'])),
      capabilities: [
        if (m['capabilities'] is List)
          for (final c in m['capabilities']! as List) c.toString(),
      ],
      compatOk: compat['ok'] != false,
      meshchatxVersion: compat['meshchatx_version'] as String?,
      vaultKeyEpoch: asInt(vault['key_epoch']) ?? 1,
      vaultInUse: vault['in_use'] == true,
      limits: m['limits'] is Map ? asMap(m['limits']) : const {},
    );
  }

  final int protocolVersion;
  final int minVersion;
  final int maxVersion;
  final String server;

  /// Bridge clock (Unix seconds) at the time of the answer.
  final double time;
  final String stateId;
  final int cursor;
  final DeviceRecord device;
  final List<String> capabilities;
  final bool compatOk;
  final String? meshchatxVersion;
  final int vaultKeyEpoch;
  final bool vaultInUse;
  final Map<String, Object?> limits;
}

// --------------------------------------------------------------------- sync

class ConvSummary {
  ConvSummary({
    required this.peer,
    required this.name,
    required this.unread,
    required this.failed,
    required this.preview,
    required this.lastId,
    this.lastTs,
  });

  factory ConvSummary.fromMap(Map<String, Object?> m) => ConvSummary(
    peer: m['peer']! as String,
    name: (m['name'] as String?) ?? '',
    unread: m['unread'] == true,
    failed: asInt(m['failed']) ?? 0,
    preview: (m['preview'] as String?) ?? '',
    lastId: asInt(m['last_id']),
    lastTs: m['last_ts'],
  );

  final String peer;
  final String name;
  final bool unread;
  final int failed;
  final String preview;
  final int? lastId;

  /// MeshChatX's value passed through (format may change; never parsed).
  final Object? lastTs;
}

class RrcRoomSummary {
  RrcRoomSummary({
    required this.hub,
    required this.hubName,
    required this.room,
    required this.unread,
    required this.mention,
  });

  factory RrcRoomSummary.fromMap(Map<String, Object?> m) => RrcRoomSummary(
    hub: m['hub']! as String,
    hubName: (m['hub_name'] as String?) ?? '',
    room: m['room']! as String,
    unread: asInt(m['unread']) ?? 0,
    mention: m['mention'] == true,
  );

  final String hub;
  final String hubName;
  final String room;
  final int unread;
  final bool mention;
}

class SyncResult {
  SyncResult({
    required this.stateId,
    required this.cursor,
    required this.reset,
    required this.more,
    required this.lxmf,
    required this.rrc,
  });

  factory SyncResult.fromMap(Map<String, Object?> m) => SyncResult(
    stateId: (m['state_id'] as String?) ?? '',
    cursor: asInt(m['cursor']) ?? 0,
    reset: m['reset'] == true,
    more: m['more'] == true,
    lxmf: [for (final c in asMapList(m['lxmf'])) ConvSummary.fromMap(c)],
    rrc: [for (final r in asMapList(m['rrc'])) RrcRoomSummary.fromMap(r)],
  );

  final String stateId;
  final int cursor;
  final bool reset;
  final bool more;
  final List<ConvSummary> lxmf;
  final List<RrcRoomSummary> rrc;
}

// ----------------------------------------------------------------- messages

/// States of MeshChatX that will not change any more.
const Set<String> terminalMessageStates = {
  'delivered',
  'rejected',
  'cancelled',
  'failed',
};

class BridgeMessage {
  BridgeMessage({
    required this.id,
    required this.hash,
    required this.incoming,
    required this.state,
    required this.method,
    required this.title,
    required this.text,
    required this.ts,
    required this.originDevice,
    required this.cmdId,
    this.name,
  });

  /// From `/get_messages` (with `id`) and `lxmf.message` pushes (no `id`).
  factory BridgeMessage.fromMap(Map<String, Object?> m) => BridgeMessage(
    id: asInt(m['id']),
    hash: m['hash']! as String,
    incoming: m['incoming'] == true,
    state: (m['state'] as String?) ?? '',
    method: m['method'] as String?,
    title: (m['title'] as String?) ?? '',
    text: (m['text'] as String?) ?? '',
    ts: asDouble(m['ts']) ?? 0,
    originDevice: m['origin_device'] as String?,
    cmdId: m['cmd_id'] as String?,
    name: m['name'] as String?,
  );

  final int? id;
  final String hash;
  final bool incoming;
  final String state;
  final String? method;
  final String title;
  final String text;

  /// Seconds since epoch.
  final double ts;
  final String? originDevice;
  final String? cmdId;

  /// Peer display name (incoming pushes only).
  final String? name;

  bool get terminal => terminalMessageStates.contains(state);
}

class MessagesResult {
  MessagesResult({
    required this.peer,
    required this.hasMore,
    required this.gap,
    required this.messages,
  });

  factory MessagesResult.fromMap(Map<String, Object?> m) => MessagesResult(
    peer: (m['peer'] as String?) ?? '',
    hasMore: m['has_more'] == true,
    gap: m['gap'] == true,
    messages: [
      for (final x in asMapList(m['messages'])) BridgeMessage.fromMap(x),
    ],
  );

  final String peer;
  final bool hasMore;
  final bool gap;
  final List<BridgeMessage> messages;
}

class RrcMessage {
  RrcMessage({
    required this.seq,
    required this.kind,
    required this.nick,
    required this.text,
    required this.tsMs,
    required this.mention,
    required this.src,
  });

  factory RrcMessage.fromMap(Map<String, Object?> m) => RrcMessage(
    seq: asInt(m['seq']) ?? 0,
    kind: (m['kind'] as String?) ?? '',
    nick: (m['nick'] as String?) ?? '',
    text: (m['text'] as String?) ?? '',
    tsMs: asInt(m['ts']) ?? 0,
    mention: m['mention'] == true,
    src: m['src'] as String?,
  );

  final int seq;
  final String kind;
  final String nick;
  final String text;

  /// RRC timestamps are milliseconds (spec 6.6).
  final int tsMs;
  final bool mention;
  final String? src;
}

// --------------------------------------------------------------------- push

class PushEvent {
  PushEvent({
    required this.seq,
    required this.id,
    required this.ts,
    required this.event,
    required this.data,
  });

  /// Parses the envelope of spec 2.3; null if it is not a push envelope.
  static PushEvent? tryParse(Object? o) {
    if (o is! Map) return null;
    final m = asMap(o);
    if (m['t'] != 'push' || m['event'] is! String) return null;
    return PushEvent(
      seq: asInt(m['seq']) ?? 0,
      id: (m['id'] as String?) ?? '',
      ts: asDouble(m['ts']) ?? 0,
      event: m['event']! as String,
      data: m['data'] is Map ? asMap(m['data']) : const {},
    );
  }

  final int seq;
  final String id;
  final double ts;
  final String event;
  final Map<String, Object?> data;
}

// ------------------------------------------------------------------ pairing

/// The content of the pairing QR code (spec 5.1).
class PairingPayload {
  PairingPayload({
    required this.pubkey,
    required this.name,
    required this.platform,
    required this.nonce,
    required this.ts,
  });

  final Uint8List pubkey;
  final String name;
  final String platform;
  final Uint8List nonce;
  final double ts;

  /// The exact bytes `P` that are signed and sent to the bridge.
  Uint8List pack() => packb({
    'pubkey': pubkey,
    'name': name,
    'platform': platform,
    'nonce': nonce,
    'ts': ts,
  });

  /// RNS identity hash of the device that shows this code (its device id).
  String get deviceId => toHex(Identity.fromPublicKey(pubkey).hash);

  /// Human-checkable fingerprint: the device id in groups of four.
  String get fingerprint => formatFingerprint(deviceId);
}

String formatFingerprint(String hex) => [
  for (var i = 0; i < hex.length; i += 4)
    hex.substring(i, i + 4 > hex.length ? hex.length : i + 4),
].join(' ');

/// `kestrel-pair:v1:<base64url(msgpack payload)>` without padding.
String encodePairingQr(PairingPayload p) =>
    '$pairingPrefix${base64UrlNoPad(p.pack())}';

class DecodedPairing {
  DecodedPairing(this.payload, this.raw);
  final PairingPayload payload;

  /// The payload bytes exactly as they were in the QR code (never re-encoded).
  final Uint8List raw;
}

/// Parses the QR text. Throws [FormatException] for anything that is not a
/// valid pairing code (wrong prefix, bad base64/msgpack, bad field sizes).
DecodedPairing decodePairingQr(String text) {
  final t = text.trim();
  if (!t.startsWith(pairingPrefix)) {
    throw const FormatException('not a Kestrel pairing code');
  }
  final Uint8List raw;
  try {
    raw = base64UrlDecodeNoPad(t.substring(pairingPrefix.length));
  } on FormatException {
    throw const FormatException('pairing code is not base64url');
  }
  if (raw.length > 1024) throw const FormatException('pairing code too large');
  final Object? m;
  try {
    m = unpackb(raw);
  } on Object {
    throw const FormatException('pairing code is not valid msgpack');
  }
  if (m is! Map) throw const FormatException('pairing code must be a map');
  final pub = m['pubkey'];
  final nonce = m['nonce'];
  final name = m['name'];
  final platform = m['platform'];
  final ts = m['ts'];
  if (pub is! Uint8List || pub.length != 64) {
    throw const FormatException('pubkey must be 64 bytes');
  }
  if (nonce is! Uint8List || nonce.length < 16 || nonce.length > 32) {
    throw const FormatException('nonce must be 16-32 bytes');
  }
  if (name is! String ||
      name.isEmpty ||
      utf8.encode(name).length > 64 ||
      name.runes.any((r) => r < 0x20 || r == 0x7f)) {
    throw const FormatException('invalid device name');
  }
  if (platform is! String || !_platformRe.hasMatch(platform)) {
    throw const FormatException('invalid platform');
  }
  if (ts is! num) throw const FormatException('ts must be a number');
  return DecodedPairing(
    PairingPayload(
      pubkey: pub,
      name: name,
      platform: platform,
      nonce: nonce,
      ts: ts.toDouble(),
    ),
    raw,
  );
}

/// The bytes the approving device signs (spec 5.2):
/// `b"kestrel-pair-approve:v1:" || P || approver_device_id (16 raw bytes)`.
Uint8List pairingSignMessage(List<int> payload, String approverDeviceIdHex) =>
    Uint8List.fromList([
      ...pairSigDomain,
      ...payload,
      ...fromHex(approverDeviceIdHex),
    ]);

// ------------------------------------------------------------ LXMF fallback

final Uint8List lxmfTypeCmd = Uint8List.fromList(utf8.encode('kestrel.cmd'));
const String lxmfTypeResp = 'kestrel.resp';
const String lxmfTypePush = 'kestrel.push';

/// Msgpack body of a command (spec 3).
Uint8List encodeLxmfCommand({
  required String cmdId,
  required double ts,
  required String path,
  required Map<String, Object?> args,
}) => packb({
  'v': bridgeProtocolVersion,
  'cmd_id': cmdId,
  'ts': ts,
  'path': path,
  'args': args,
});

/// LXMF fields of a command message: custom type + custom data.
Map<Object?, Object?> lxmfCommandFields(Uint8List body) => {
  LxmfField.customType: lxmfTypeCmd,
  LxmfField.customData: body,
};

/// A decoded `kestrel.resp` / `kestrel.push` LXMF message.
class LxmfEnvelope {
  LxmfEnvelope(this.type, this.payload);
  final String type;
  final Map<String, Object?> payload;

  bool get isResponse => type == lxmfTypeResp;
  bool get isPush => type == lxmfTypePush;
}

/// Null if [fields] do not carry a kestrel envelope.
LxmfEnvelope? decodeLxmfEnvelope(Map<Object?, Object?> fields) {
  final t = fields[LxmfField.customType];
  final d = fields[LxmfField.customData];
  if (t is! List<int> || d is! List<int>) return null;
  final type = utf8.decode(t, allowMalformed: true);
  if (!type.startsWith('kestrel.')) return null;
  try {
    return LxmfEnvelope(type, asMap(unpackb(d)));
  } on Object {
    return null;
  }
}
