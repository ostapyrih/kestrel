# Device group sync (phase S)

Protocol and primitives for several Kestrel devices sharing one main identity (G) without the MeshChatX
bridge. Design and rationale: `docs/PLAN.md` ("Device group mode without the bridge") and
`docs/spikes/device-group.md`. This document is versioned by `kDeviceSyncVersion` (introduced in S3);
each PR of phase S appends its part.

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
