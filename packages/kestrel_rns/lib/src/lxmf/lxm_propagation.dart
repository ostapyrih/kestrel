import 'dart:convert';
import 'dart:typed_data';

import '../msgpack/msgpack.dart';
import '../stamps.dart';
import '../util.dart';

/// LXMF propagation node announce metadata keys (LXMF.py:132-139).
abstract final class PnMeta {
  static const int version = 0x00;
  static const int name = 0x01;
  static const int implName = 0xFE;
}

/// Parsed `lxmf.propagation` announce app_data (LXMF.pn_announce_data_is_valid
/// and the accessors in LXMF.py:216-262, LXMF 1.3.1).
///
/// Wire format: `msgpack([legacy_flag, timebase, enabled,
/// per_transfer_limit_kb, per_sync_limit_kb, [ceil costs...], metadata{},
/// [fractional costs...]?])`.
class PropagationNodeData {
  const PropagationNodeData({
    required this.timebase,
    required this.enabled,
    required this.transferLimitKb,
    required this.syncLimitKb,
    required this.stampCost,
    required this.stampCostFlexibility,
    required this.peeringCost,
    this.metadata = const {},
  });

  /// Node clock at announce time (unix seconds).
  final int timebase;

  /// Node state flag: false = the node does not accept/serve messages.
  final bool enabled;

  /// Largest single message (kilobytes) the node propagates.
  final int transferLimitKb;

  /// Largest incoming transfer (kilobytes) the node accepts in one sync.
  final int syncLimitKb;

  /// Target stamp cost for messages submitted to the node.
  final double stampCost;

  /// The node accepts stamps down to `stampCost - stampCostFlexibility`.
  final double stampCostFlexibility;
  final double peeringCost;
  final Map<Object?, Object?> metadata;

  /// Lowest stamp cost the node still accepts
  /// (`max(0, cost - flexibility)`, LXMRouter.propagation_packet).
  double get minAcceptedCost =>
      (stampCost - stampCostFlexibility).clamp(0, Stamps.costCap).toDouble();

  /// Node display name from the metadata, if any.
  String? get name {
    final n = metadata[PnMeta.name];
    if (n is Uint8List) {
      try {
        final s = utf8.decode(n).trim();
        return s.isEmpty ? null : s;
      } on Object {
        return null;
      }
    }
    return null;
  }

  /// Parses [appData]; null if it is not a valid propagation announce.
  static PropagationNodeData? parse(List<int>? appData) {
    if (appData == null || appData.isEmpty) return null;
    Object? d;
    try {
      d = unpackb(Uint8List.fromList(appData));
    } on Object {
      return null;
    }
    if (d is! List<Object?> || d.length < 7) return null;
    final tb = _asInt(d[1]);
    final en = d[2];
    final tl = _asInt(d[3]);
    final sl = _asInt(d[4]);
    final c5 = d[5];
    final md = d[6];
    if (tb == null || en is! bool || tl == null || sl == null) return null;
    if (c5 is! List<Object?> || c5.length < 3 || md is! Map<Object?, Object?>) {
      return null;
    }
    var costs = c5.map(_asDouble).toList();
    if (d.length > 7) {
      // Transitional mechanism: fractional costs (removed after RNS 1.6.2).
      final c7 = d[7];
      if (c7 is! List<Object?> || c7.length < 3) return null;
      costs = c7.map(_asDouble).toList();
    }
    if (costs.take(3).any((c) => c == null)) return null;
    return PropagationNodeData(
      timebase: tb,
      enabled: en,
      transferLimitKb: tl,
      syncLimitKb: sl,
      stampCost: costs[0]!,
      stampCostFlexibility: costs[1]!,
      peeringCost: costs[2]!,
      metadata: md,
    );
  }

  /// Builds announce app_data like `LXMRouter.get_propagation_node_app_data`
  /// (used by tests and tooling).
  static Uint8List pack({
    int? timebase,
    bool enabled = true,
    int transferLimitKb = 256,
    int syncLimitKb = 256 * 40,
    double stampCost = 16,
    double stampCostFlexibility = 3,
    double peeringCost = 18,
    String? name,
  }) {
    final md = <Object?, Object?>{
      PnMeta.implName: Uint8List.fromList(utf8.encode('lxmd')),
      PnMeta.version: Uint8List.fromList(utf8.encode('0.0.0')),
      if (name != null) PnMeta.name: Uint8List.fromList(utf8.encode(name)),
    };
    return packb(<Object?>[
      false,
      timebase ?? unixNow().floor(),
      enabled,
      transferLimitKb,
      syncLimitKb,
      <Object?>[
        stampCost.ceil(),
        stampCostFlexibility.ceil(),
        peeringCost.ceil(),
      ],
      md,
      <Object?>[stampCost, stampCostFlexibility, peeringCost],
    ]);
  }

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;
  static double? _asDouble(Object? v) => v is num ? v.toDouble() : null;
}

/// A propagation node heard in an `lxmf.propagation` announce.
class LxmPropagationNode {
  LxmPropagationNode({
    required this.hash,
    required this.data,
    required this.hops,
    required this.lastSeen,
  });

  final Uint8List hash;
  final PropagationNodeData data;
  final int hops;
  final DateTime lastSeen;

  String? get name => data.name;
  bool get enabled => data.enabled;
  String get hashHex => toHex(hash);

  LxmPropagationNode copyWith({int? hops, DateTime? lastSeen}) =>
      LxmPropagationNode(
        hash: hash,
        data: data,
        hops: hops ?? this.hops,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// Chooses the propagation node to use (pure, no I/O).
///
/// Order: a pinned node always wins. Otherwise the current node is kept while
/// it is still a candidate (enabled, recently heard, not marked unreachable);
/// else the candidate with the fewest hops, ties broken by most recently
/// heard, then by hash for determinism.
abstract final class PropagationNodeSelector {
  static List<LxmPropagationNode> candidates(
    Iterable<LxmPropagationNode> nodes, {
    required DateTime now,
    Duration maxAge = const Duration(days: 2),
    Set<String> unreachable = const {},
  }) =>
      [
        for (final n in nodes)
          if (n.enabled &&
              now.difference(n.lastSeen) <= maxAge &&
              !unreachable.contains(n.hashHex))
            n,
      ];

  static Uint8List? select(
    Iterable<LxmPropagationNode> nodes, {
    required DateTime now,
    Uint8List? pinned,
    Uint8List? current,
    Duration maxAge = const Duration(days: 2),
    Set<String> unreachable = const {},
  }) {
    if (pinned != null) return pinned;
    final c = candidates(
      nodes,
      now: now,
      maxAge: maxAge,
      unreachable: unreachable,
    );
    if (c.isEmpty) return null;
    if (current != null) {
      final cur = toHex(current);
      for (final n in c) {
        if (n.hashHex == cur) return n.hash;
      }
    }
    c.sort((a, b) {
      final h = a.hops.compareTo(b.hops);
      if (h != 0) return h;
      final t = b.lastSeen.compareTo(a.lastSeen);
      if (t != 0) return t;
      return a.hashHex.compareTo(b.hashHex);
    });
    return c.first.hash;
  }
}

/// Phase of an inbox sync (mirrors LXMRouter.PR_* plus our persist step).
enum LxmSyncPhase {
  idle,
  pathRequested,
  linkEstablishing,
  listing,
  receiving,
  persisting,
  confirming,
  complete,
  failed,
}

/// Why a sync did not complete.
enum LxmSyncError {
  none,
  noNode,
  nodeDisabled,
  noPath,
  linkFailed,
  noIdentity,
  noAccess,
  transferFailed,
  invalidResponse,
  timeout,
  disabled,
  stopped,
}

/// Progress snapshot of the running (or last) sync.
class LxmSyncProgress {
  const LxmSyncProgress({
    required this.phase,
    this.node,
    this.progress = 0,
    this.listed = 0,
    this.downloaded = 0,
  });

  final LxmSyncPhase phase;
  final Uint8List? node;
  final double progress;
  final int listed;
  final int downloaded;
}

/// Outcome of one inbox sync.
class LxmSyncResult {
  const LxmSyncResult({
    required this.error,
    required this.at,
    this.node,
    this.listed = 0,
    this.downloaded = 0,
    this.delivered = 0,
    this.duplicates = 0,
    this.undecryptable = 0,
    this.persistFailed = 0,
    this.purged = 0,
    this.remaining = 0,
    this.detail,
  });

  final LxmSyncError error;
  final DateTime at;
  final Uint8List? node;

  /// Messages the node listed for us.
  final int listed;

  /// Messages actually transferred.
  final int downloaded;

  /// New messages decrypted, persisted and delivered to the app.
  final int delivered;

  /// Messages we already had (also arrived directly or in an earlier sync).
  final int duplicates;

  /// Messages that could not be decrypted (kept on the node, not purged).
  final int undecryptable;

  /// Messages whose persistence failed (kept on the node, not purged).
  final int persistFailed;

  /// Messages the node was told to delete (the "haves").
  final int purged;

  /// Messages still left on the node (over the transfer limit, failures).
  final int remaining;
  final String? detail;

  bool get ok => error == LxmSyncError.none;

  @override
  String toString() =>
      'LxmSyncResult($error listed=$listed delivered=$delivered '
      'dup=$duplicates purged=$purged remaining=$remaining)';
}
