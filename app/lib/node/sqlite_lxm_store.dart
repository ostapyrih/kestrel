import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';

import '../storage/repo.dart';

/// [LxmStore] backed by the `outbox` table (queue) and `messages` (dedup).
///
/// Rows are created by `NodeService` (with the frozen sender identity and
/// route); the router only fills in the packed bytes and progress, addressing
/// the row through the `tag` it was given.
class SqliteLxmStore implements LxmStore {
  SqliteLxmStore(this.repo, {this.identity = 'B'});

  final Repo repo;
  final String identity;
  final Set<String> _claimed = {};

  @override
  Future<List<LxmOutboundRecord>> loadOutbound() async {
    final rows = await repo.outboxPending();
    return [
      for (final r in rows)
        if (r['lxmf_hash'] != null)
          LxmOutboundRecord(
            hash: fromHex(r['lxmf_hash']! as String),
            destinationHash: fromHex(r['destination_hash']! as String),
            packed: Uint8List.fromList(r['packed']! as List<int>),
            desiredMethod: r['route'] == 'direct'
                ? LxmfMethod.direct
                : LxmfMethod.opportunistic,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_ts']! as int,
            ),
            attempts: r['attempts']! as int,
            state: r['state']! as int,
            tag: '${r['id']}',
          ),
    ];
  }

  @override
  Future<void> saveOutbound(LxmOutboundRecord r) async {
    final id = int.tryParse(r.tag ?? '');
    if (id == null) return;
    await repo.outboxSave(
      id: id,
      lxmfHash: toHex(r.hash),
      packed: r.packed,
      attempts: r.attempts,
      state: r.state,
    );
  }

  @override
  Future<void> removeOutbound(Uint8List hash) => repo.outboxDone(toHex(hash));

  @override
  Future<bool> claimInbound(Uint8List hash) async {
    final h = toHex(hash);
    if (!_claimed.add(h)) return false;
    if (await repo.hasMessageHash(identity, h)) return false;
    return true;
  }
}
