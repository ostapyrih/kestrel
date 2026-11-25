import 'dart:convert';
import 'dart:typed_data';

import '../msgpack/msgpack.dart';
import '../stamps.dart';

/// Parsed `lxmf.delivery` announce app_data.
class LxmAnnounceData {
  const LxmAnnounceData({
    this.displayName,
    this.stampCost,
    this.supportsCompression = true,
  });

  final String? displayName;

  /// Stamp value the peer requires on inbound messages (null = none).
  final double? stampCost;
  final bool supportsCompression;

  /// `LXMF.SF_COMPRESSION` (LXMF.py:143).
  static const int sfCompression = 0x00;

  /// App data exactly as LXMRouter.get_announce_app_data (LXMF 1.3.1,
  /// LXMRouter.py:1165): `msgpack([display_name bytes|nil, ceil(cost)|nil,
  /// [SF_COMPRESSION], cost|nil])` with the (transitional) fractional cost as
  /// element 3.
  static Uint8List pack({String? displayName, double? stampCost}) {
    double? cost;
    if (stampCost != null && stampCost > 0 && stampCost < Stamps.costCap) {
      cost = Stamps.quantizeCost(stampCost);
    }
    return packb(<Object?>[
      displayName == null ? null : Uint8List.fromList(utf8.encode(displayName)),
      cost?.ceil(),
      <Object?>[sfCompression],
      cost,
    ]);
  }

  static bool _isMsgpackArray(List<int> d) =>
      d.isNotEmpty && ((d[0] >= 0x90 && d[0] <= 0x9f) || d[0] == 0xdc);

  /// `display_name_from_app_data` + `stamp_cost_from_app_data` +
  /// `compression_support_from_app_data` (LXMF.py:152-212).
  static LxmAnnounceData parse(List<int>? appData) {
    if (appData == null || appData.isEmpty) return const LxmAnnounceData();
    if (!_isMsgpackArray(appData)) {
      // Legacy format: plain utf-8 display name.
      try {
        return LxmAnnounceData(displayName: utf8.decode(appData));
      } on Object {
        return const LxmAnnounceData();
      }
    }
    Object? d;
    try {
      d = unpackb(appData);
    } on Object {
      return const LxmAnnounceData();
    }
    if (d is! List<Object?>) return const LxmAnnounceData();

    String? name;
    if (d.isNotEmpty && d[0] is Uint8List) {
      try {
        name = utf8.decode(d[0]! as Uint8List).replaceAll('\x00', '').trim();
      } on Object {
        name = null;
      }
    }
    double? cost;
    if (d.length > 3 && d[3] is num) {
      cost = (d[3]! as num).toDouble();
    } else if (d.length > 1 && d[1] is num) {
      cost = (d[1]! as num).toDouble();
    }
    var compression = true;
    if (d.length >= 3 && d[2] is List<Object?>) {
      compression = (d[2]! as List<Object?>).contains(sfCompression);
    }
    return LxmAnnounceData(
      displayName: name,
      stampCost: cost,
      supportsCompression: compression,
    );
  }
}
