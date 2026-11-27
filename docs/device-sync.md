# Device group sync (phase S)

Protocol and primitives for several Kestrel devices sharing one main identity (G) without the MeshChatX
bridge. Design and rationale: `docs/PLAN.md` ("Device group mode without the bridge") and
`docs/spikes/device-group.md`. This document is versioned by `kDeviceSyncVersion` (currently 1).

## Part 1 - `kestrel_rns` primitives (S1)

All of these live in the pure-Dart core; they change nothing for a single-device install.

| Primitive | API | Purpose |
|---|---|---|
| Silent destination | `Destination.silent`, `LxmRouter.silent` | A silent destination is never announced (`Transport.announce` returns false, no stamp work) and never answers a path request. Only the elected announcer is audible; stock RNS answers every path request for a registered destination (Transport.py:4018), so non-announcers must be held silent. Inbound traffic that reaches a silent device is still decrypted and delivered. |
| Monotonic timebase | `AnnounceTimebase`, `Destination.announceTimebase`, `Transport.clockSeconds` | Announce emission time is `max(now, last + 1)`; `observe(t)` merges the value synced from siblings. Without it a device with a slow clock cannot take the path over (peers reject announces that are not newer). |
| Stamp copy | `Transport.exportStamp`, `Transport.importStamp` | The announce stamp depends only on `hash + public key + name hash`, so it is identical on every device holding G. Export never generates; import validates against the destination and the configured target value. |
| Ratchet merge | `Destination.exportRatchets`, `mergeRatchets`, `ratchetRotationAllowed`, `RatchetEntry` | Union by key value, newest first by creation time (unknown time = 0 sorts last, local order kept, ties favour local keys), capped at `retainedRatchets` (512). Never overwrites. Creation times persist next to the keys (`ratchets/<hash>` storage key, `times` list). A merged recent ratchet postpones local rotation; a device with `ratchetRotationAllowed = false` announces the shared newest ratchet unchanged (spike case C7). |
| Inbox hook | `LxmRouter.inboxSyncEnabled` | Only the announcer syncs G's propagation inbox (take-once). Honoured by `syncInbox` and by auto/periodic sync. |
| Dedupe | `LxmStore.claimInbound` | Every inbound path (opportunistic, link packet, resource, propagation download) goes through the same claim by LXMF message hash; a message seen on one path is a duplicate on the others. |

Tests: `test/device_group_test.dart` (unit), `test/integration/device_group_test.dart` (against Python RNS 1.6.1:
path-request suppression, slow-clock takeover through a Python transport node, stamp reuse accepted by Python,
merged-ratchet decrypt of a Python-encrypted message), plus cross-path dedupe and `inboxSyncEnabled` tests in
`test/propagation_test.dart`.

## Part 2 - identities, group state, pairing

* **G** (the group identity, "my address") is the only identity used for chats on every device. On an existing install it is the old
  identity B (same key, same address, same chats). **Device key**: one hidden identity per device, never shown, never used for chats;
  used between the user's devices and to authenticate to the bridge. Both live in the secret store
  (`kestrel.identity_b.private_key` = G, `kestrel.device.private_key`); `kestrel.legacy_b.private_key` is a copy of the old B kept
  only while the bridge still knows the device under it.
* **Bridge key migration.** When the bridge connects and a legacy key exists, the device approves its own device key with the legacy
  key (`/devices/approve`, wrapping the vault key chain to it as usual), switches to the device key, reconnects and revokes the legacy
  registration, so no other holder of G stays trusted by the bridge. A failed revoke leaves the old entry in "Bridge devices".
* **GroupState** (msgpack, stored in the secret store): `gid`, key `epoch` + the key chain (`VaultCrypto` chain, envelope of bridge
  protocol 9.4), the device list, the shared name (`name` + `name_rev`), the announce `timebase`. `DeviceList` is merged per device
  by `rev` (higher wins, a tombstone wins a tie); a record whose id is not the hash of its public key is dropped.
* **Pairing without the bridge** (`PairingHost` / `PairingClient`, QR text `kestrel-group:v1:<base64url msgpack {pub, secret, exp,
  name}>`): the host opens `kestrel.group.pair` on its device key and announces it; the new device remembers it from the key in the QR,
  links over RNS (TCP or LoRa), identifies with its device key and sends `/pair` `{pub, name, platform, nonce, proof}` with
  `proof = HMAC-SHA256(secret, tag || link_id || pub || nonce)`. Three bad proofs close the window; the secret never travels. Both
  screens show the 6 digit code `HKDF(secret, salt=link_id, "kestrel-group-pair-code")`. After the host user approved, the answer carries the
  `PairingBundle` (G's private key, group state, merged ratchets, G's announce stamp) in a Token under
  `HKDF(secret, salt=link_id, "kestrel-group-pair-bundle")`. The new device user confirms the code, sends `/pair/done` (HMAC proof) and only then
  does the host add the device. One window = one pairing, 10 minute expiry.
* **Joining**: the new device cancels unsent messages, moves its old chats to the read-only histories under its old device id
  (labelled with its name, `group_legacy_devices`; kept when the bridge is turned off), adopts G and the state, and restarts its router.
  Existing vault histories of other devices stay.
* **Remove device**: tombstone + new random key epoch; each remaining device receives the new chain wrapped to its device key in a
  targeted (`seq` 0) `rekey` record encrypted under the old epoch (the removed device is not a recipient), then the device list.
  The removed device still holds G: the UI offers **Change address**.
* **Change address**: new G; an LXMF notice ("My new Kestrel address: <hex>") goes from the old G to the 50 most recent contacts, then
  the router restarts on the new G and announces. Old chats stay. The device that ran it then publishes an `identity` record (below), so
  the whole group follows; the notice is sent once, by that device only.

## Part 3 - sync, election, forwarding

**Envelope** (one per record per sibling, in an LXMF message between the device keys' `lxmf.delivery` destinations; fields
`0xFB = "kestrel.sync.v1"`, `0xFC = msgpack(envelope)`):
`{v: 1, blob_id, device_id, seq, key_epoch, ct}`; `ct` = `VaultCrypto.encryptBlob` of `{kind, ts, data}` with the group key of
`key_epoch`. Decryption only through `VaultCrypto.decryptBlob` (inner `blob_id`, `device_id`, `seq`, `key_epoch` must equal the envelope).
`blob_id = hex(truncated_hash("<device>:<seq>"))` (deterministic, so a repeat is the same blob).

* **Transport**: one LXMF per active sibling (a propagation node deletes a message after the first download); direct when the
  sibling is online (large records upgrade to a link/resource), the router falls back to the propagation node otherwise.
  `DeviceSync.extraTransports` (`SyncTransport`) carries the same envelopes elsewhere (the bridge vault); both feed `DeviceSync.ingest`.
* **Continuity**: per origin `seq` (1, 2, ...; 0 = targeted, outside the sequence). Duplicates (`seq <= seen`) are ignored, out-of-order
  records wait, a gap sends `kestrel.sync.gap.v1 {from, to}` and the origin re-sends from its log (up to 200 per request).
* **Kinds**: built in: `devices` (device list), `name` (`{name, rev}`), `ratchets` (`{list: [{k, t}], tb}`, merged into G's destination,
  `tb` observed by the announce timebase), `rekey`. App kinds: `messages` (`{hash, peer, peer_name?, incoming, text, title?, ts (ms),
  route?, state?}`, upsert by LXMF hash, state only moves forward), `delete_chat` (`{peer, before_ts}`; tombstone under device id
  `group`), `read` (`{peer}`), `browser` (`{ops}` as in bridge protocol 9.5; the group sync consumes the dirty marks when a group is
  active).
* **`identity`** (versioned, `IdentityChange`): `{v: 1, priv (G' private key), gen, replaces (hash of the old G), name, name_rev,
  ratchets: [{k, t}], stamp?, tb}`. `gen` is a monotonic generation kept in `GroupState` (`id_gen`, `id_hash`; it also travels in the
  pairing bundle): the highest generation wins, at equal generations the larger identity hash, the same change twice is ignored.
  A sibling that adopts it (`DeviceSync.onIdentity`) stores G', switches its LxmRouter to it (merging the ratchets, importing the
  stamp, taking name and timebase), restarts the election so the announcer announces G' at once while the others stay silent, stops
  answering for the old G (destination deregistered) and keeps the old-G chats as history (chats are keyed by the account, so new
  messages to contacts simply go from G'). Sent to every sibling over the normal channel (direct, propagation fallback). The
  record is an ordinary encrypted record, so a removed device (new key epoch) never receives it. No new vault blob kind:
  `kSyncSemanticsVersion` stays 2.
* **History backfill** (`DeviceBackfill`, app: `history_backfill.dart`): after pairing the new device pulls the group's history from
  the pairing host (rotating to another sibling when it does not answer). Targeted records (seq 0): `backfill_req {p, c}` (phase,
  cursor) answered by `backfill {rp, rc, sp, items, np, nc, total}`. Phases in order: `tomb` (group deletion tombstones, first so
  deleted chats stay deleted), `msg` (messages of the main identity, cursor = local message id, batches of 40 / ~48 kB, upserted by
  LXMF hash, incoming ones do not raise unread), `read` (unread counters), `bsync` / `bhist` (browser ops and history, as in 9.5).
  MeshChatX chats are not included (they come from the bridge). The new device persists `(phase, cursor)` after each applied batch
  (restart resumes), ignores answers for positions it has passed, re-asks after 20 s and shows "Syncing history..." on the chat
  list. Batches travel directly when the sibling is online (large ones upgrade to a link/resource), otherwise via the propagation node.
* **Presence and election** (`GroupAnnouncer`): every 10 s each device sends every sibling a signed presence packet
  `[body, sig]` (`body = {v, dev, t (wall clock), net (TCP path), ann (is announcing), ep}`) to `kestrel.group.presence`, announced once
  per connection. A sibling not heard for 35 s is out. `electAnnouncer`: candidates are the live siblings plus this device; a candidate
  whose clock is more than 30 s ahead of the group median is excluded (a clock far behind is harmless with the timebase); devices with
  a TCP path precede LoRa-only ones; then the lowest device id. The elected device starts announcing at once (immediate announce,
  after sharing a due ratchet rotation); the previous announcer steps down only after it hears the new one announcing
  (make-before-break), and an announcer that hears another announcing re-announces so the monotonic timebase makes its announce
  the newest. A device that knows siblings but has heard nobody waits 2 intervals before it announces itself.
* **Roles**: only the announcer announces G, answers path requests for it, rotates ratchets (`ratchetRotationAllowed`) and syncs G's
  propagation inbox (`inboxSyncEnabled`, persist first, then the haves). Every message a device receives is forwarded as a `messages`
  record; every message typed on any device is sent as G and published, delivery state follows as later records. All devices dedupe by
  LXMF message hash.
* **Announce spacing**: a young interface that bursts announces gets them held by transports (RNS ingress control, observed in the
  tests: the 4th announce within a second stays unseen for about a minute). The app spaces the device-key announces by 2 s.

Tests: `test/group_test.dart`, `test/group_election_test.dart`, `test/integration/group_pairing_test.dart`,
`test/group_identity_test.dart` (identity record, generations, sibling switch), `app/test/history_backfill_test.dart`,
`test/integration/group_sync_test.dart` (Python transport node + Python LXMF peer + three Dart devices: pairing, one announcer,
forwarding to siblings, a message sent on a sibling, `delete_chat` and `browser` records, handover with an in-flight message, key rotation
cutting off a removed device, no duplicates, change address on one device moving all, backfill to a newly paired device).

### Known gaps
* The bridge vault is not yet wired as a `SyncTransport` (the interface and `ingest` dedupe exist); the vault keeps uploading the
  old per-device history semantics (`kSyncSemanticsVersion` stays 2: no new vault blob kind).
* A sibling that is offline during "Change address" receives the `identity` record when it is next reachable (propagation node or
  gap request); until then it still announces nothing for G (silent) but answers for the old G.
* Backfill is pulled from one device at a time; the history is a snapshot per phase (a message arriving meanwhile arrives as a
  normal `messages` record). Old histories of retired devices (`group_legacy_devices`) are not backfilled.
* A propagation-node multi-device test (inbox consumed once) is not part of the integration suite; `inboxSyncEnabled` is covered by unit
  tests and asserted on the non-announcers.
