# Spike: device group mode without the bridge (phase S)

Status: research spike, 2026-11-27. Validates the design in `docs/PLAN.md` -> "Device group mode without the bridge"
against real RNS 1.6.1 + LXMF 1.3.1 (the versions pinned in `tools/requirements.txt`). No app or library code was
changed; everything here is experiment scripts plus this report.

**Scope note.** An earlier brief asked for a "bridge as a group member" scenario (MeshChatX identity shared with the
devices). The owner dropped it: MeshChatX keeps its own identity and the group identity A is separate. That scenario
was not investigated and is not covered here.

## 0. Method and limits

* Everything runs on `127.0.0.1` with throw-away config dirs, `share_instance = no`, no AutoInterface, no public
  network. A "network" is: one transport node (`enable_transport = yes`, TCP server interface) and N other RNS
  instances connected to it by TCP clients. Each instance is a separate OS process (`agent.py`), so every device has
  its own RNS storage, ratchet files and LXMF store, exactly like separate phones.
* Actors: **transport** T, **peer** P (an ordinary LXMF client with its own identity), **devices** X, Y, Z that all
  load the *same* private key for A (and optionally their own B). A **propagation node** (PN) is a plain
  `LXMRouter.enable_propagation()` in its own process.
* Because it is all on loopback, absolute latencies are lower than on the internet; what matters are the *protocol*
  timers (retry intervals, path-table rules), which are the same.
* The Python reference implementation is tested, not the Dart core. Where Dart is free to behave differently (and we
  recommend it should) this is called out.
* Announce stamps: RNS 1.6.1 makes every destination announce carry a proof of work (cost 25 by default; see 8). The
  harness lowers it to 8 for speed except in `exp8_stamp.py`.
* "Peer was offline / missed Y's announce" is simulated by `freeze_ratchet`: the peer stops updating its ratchet cache
  after it heard X, while the transport already routes A to Y. Clock skew is simulated by patching `time.time` in
  `RNS.Destination`.
* Line numbers are from the pinned releases (`RNS/...` and `LXMF/...` in `site-packages`).

Scripts (all in `tools/spikes/device_group/`, run from the repo root with the pinned requirements installed,
`pip install -r tools/requirements.txt`):

| Script | Question |
|---|---|
| `harness.py`, `agent.py` | shared infrastructure (not run directly) |
| `exp1_paths.py [--mode gateway]` | Q1 paths, announcer tie-breaks, clock skew, path requests |
| `exp2_handover.py` | Q2 handover timing, in-flight messages |
| `exp3_ratchets.py` | Q3 ratchets: failure, sharing, merging, disabling |
| `exp4_propagation.py` | Q4 multi-device propagation inbox |
| `exp5_dupes.py` | Q5 proofs and duplicates |
| `exp6_name.py` | Q6 display name |
| `exp7_sibling.py` | Q7 B <-> B sibling channel on a node that also holds A |
| `exp8_stamp.py` | announce stamp cost and portability (found during setup) |

Typical runtimes: exp1 about 3-4 min, exp2 about 4 min, exp3 about 4 min, exp4 about 2.5 min, exp5/6/7 about 1-2 min
each, exp8 about 1-3 min (real PoW).

## 1. Paths: who receives messages for A?

**Setup.** T, P, X, Y, Z. All three devices hold A (ratchets disabled here to isolate routing, see Q3). Interface
mode of T's server interface: `full` (default) and `gateway`.

**Observed.**

| Situation | Result |
|---|---|
| Only X announced; Y and Z online, silent | 6/6 opportunistic and 3/3 direct (link) messages reached X; Y and Z received 0. Identical in `full` and `gateway` mode. |
| Y announces after X (different second) | T's path table flips to Y; next 4/4 messages go to Y, X gets 0. X announces again -> flips back, 4/4 to X. "Last emission wins", deterministic. |
| X and Y announce in the same second | Neither replaces the other deterministically: whichever announce reaches T first wins (6 rounds: incumbent kept 3, challenger won 3). |
| Z with a clock 120 s ahead announces, then X (correct clock) announces | T keeps Z: Z's announce has the later emission time, X's announce is *rejected* (3/3 messages to Z, 0 to X). |
| Path request while T has no path, `full` mode | Nobody answers: P gets no path, 0/3 messages delivered. Silent devices are never reached because T does not forward path requests for unknown destinations on a `full`-mode interface. |
| Same, T interface in `gateway` mode, 5 repeats with no announces | The silent devices *do* answer the forwarded path request with a path-response announce. Holder after the 5 repeats: X 4 times, Z once. **Non-deterministic.** |

**Why (source).**

* An announce replaces a path-table entry only if it was *emitted* later: `RNS/Transport.py:2631`
  (`not random_blob in random_blobs and announce_emitted > path_timebase`); an equal emission time does not replace
  (`Transport.py:2638`); a larger hop count needs a later emission or an expired path (`Transport.py:2651-2668`).
  The emission time is `int(time.time())` written into the announce's random blob, i.e. the **announcing device's own
  wall clock, with one-second resolution** (`RNS/Destination.py:333`).
* A device that holds destination A in its `destinations_map` answers *any* path request that reaches it with a fresh
  announce (`Transport.py:4018-4022`), whether or not it ever announced. Path requests for unknown destinations are
  only forwarded by transports on interfaces whose mode is in `DISCOVER_PATHS_FOR`
  (access point, gateway, roaming, internal): `Transport.py:3994-3996`, `RNS/Interfaces/Interface.py:54`.
* Paths live 7 days after the last verifiable announce: `Transport.py:227` (`PATH_TIMEOUT`).

**Conclusion.**

1. "One announcer" gives deterministic routing for opportunistic and direct messages: all traffic follows T's
   path-table entry, which follows the latest emitted announce. Silent devices receive nothing, as long as nobody
   triggers a path response from them.
2. A silent device that is registered as destination A in an RNS-style transport will break this the moment a
   path request reaches it (gateway/AP/roaming interfaces, or shared media such as LoRa and AutoInterface where
   path requests are broadcast). **Non-announcing devices must not answer path requests for A with an announce.**
   In the reference RNS this is not configurable; the Dart `Transport` is ours, so this is a one-line
   policy ("only the current announcer answers for A").
3. **Clock skew is a real hazard.** The ordering key is the sender's wall clock. A device whose clock runs ahead by
   delta "wins" for delta; a device whose clock runs behind cannot take over from a sibling that announced later
   (the transport and peers reject its announce) until real time passes. Worst case is bounded by the 7-day path timeout.
   See the recommendation in section 9 (monotonic group announce timebase).
4. Same-second announces are a coin flip (first to arrive at the transport wins).

## 2. Handover: announcer X goes offline, Y announces

**Setup.** T, P, X, Y. Ratchets of X merged into Y beforehand (so decryption does not confound the timing; see Q3).
X is hard-killed at t0. P sends m1 at t0 (in flight), m2 at t0+3 s (before Y announces), Y announces at t0+6 s, P sends
m3 at t0+7 s. P's LXMF router uses its default retry logic with `try_propagation_on_fail = False` (no fallback).

**Observed.**

| Scenario | m1 (sent at kill) | m2 (before announce) | m3 (after announce) |
|---|---|---|---|
| Opportunistic, Y announces at +6 s | received by Y at +11.8 s (5.8 s after Y's announce) | +15.8 s (9.8 s after) | +7.0 s (1.0 s after) |
| Opportunistic, Y never announces | sender **FAILED after 56 s** (6 attempts) | FAILED after 60 s | FAILED after 64 s |
| Direct (link), Y announces at +6 s | received at +21.3 s (15.3 s after announce) | +21.3 s | +21.3 s |

In all "Y announces" cases the sender ended in state `DELIVERED` (one proof, from Y) and no message was lost.

**Why.**

* Opportunistic retries: `DELIVERY_RETRY_WAIT = 10 s`, `MAX_DELIVERY_ATTEMPTS = 5` (`LXMF/LXMRouter.py:37-39`,
  `schedule_attempt` `:2018-2032`). Each retry is encrypted anew and sent along the transport's *current* path, so the
  first retry after Y's announce reaches Y. A message sent while X was already dead simply sits in the retry loop:
  worst case ~10 s after the announce (we saw 5.8 and 9.8 s), and the sender never needs to do anything.
* The new announce also re-triggers a message that is waiting for a path (`LXMF/Handlers.py:11-27`, only for
  messages with `awaiting_path`).
* If Y does not announce, the transport keeps the stale path to X (it did not drop it when X's TCP connection died,
  and a path request from the peer is answered from T's cache with the same stale path), so the peer exhausts its attempts
  in about 1 minute and fails the message. In `full` mode a path request does not reach Y; in `gateway` mode Y would
  answer (Q1) but that is the non-deterministic case.
* Direct messages are slower: the link request toward the dead path must time out before LXMF re-requests the path
  and rebuilds the link, 15 s after the announce in our run.

**Conclusion.** Handover latency is: failure detection (our design, B-channel heartbeat) + announce propagation (about
1 s on loopback; the stamp must be pre-computed, see 8) + up to ~10 s for opportunistic retries, ~15 s for direct
links. Messages in flight are not lost as long as Y announces within the retry window (about 50-60 s); after that the
peer's LXMF marks the message FAILED (an app that sets `try_propagation_on_fail` would instead hand it to the PN,
where Y can sync it later, see Q4). So: handover should happen well inside 30 s, and the app should announce
immediately on takeover rather than wait for the next periodic announce.

## 3. Ratchets

LXMF 1.3.1 enables ratchets on every delivery destination unconditionally:
`LXMF/LXMRouter.py:424` (`delivery_destination.enable_ratchets(f"{self.ratchetpath}/<desthash>.ratchets")`), with
`enforce_ratchets` an opt-in router flag (`:429-430`). Ratchets are rotated at most every 30 minutes
(`RNS/Destination.py:92`, `rotate_ratchets` `:250-262`; the first announce after startup always rotates because
`latest_ratchet_time = 0`, `:591`), the newest private key is announced (`:335-338`), and the last 512 are retained
(`:87`). Senders cache the latest announced ratchet for 30 days (`RNS/Identity.py:72`, `get_ratchet` `:626`) and
`Destination.encrypt` uses it (`Destination.py:705-708`).

**File layout.** `<lxmf storage>/lxmf/ratchets/<hex lxmf.delivery hash>.ratchets` = msgpack
`{"signature": sign_A(packed), "ratchets": packed}` where `packed` is a msgpack list of 32-byte X25519 *private*
keys, **newest first** (`Destination.py:233-248`, `:535-573`). The signature is by identity A, so every device
holding A can verify and re-sign it. The LXMF store is `state.db`; ratchets are not in it.

**Decrypt order.** `Identity.decrypt` (`RNS/Identity.py:1248-1274`) tries every retained ratchet, then, unless
enforcement is on, the base identity key. Ciphertext made for a ratchet cannot be opened with the base key.
`Destination.decrypt` additionally **reloads the ratchet file from disk on a failed decrypt and retries**
(`Destination.py:731-749`), which means an external update of the file is picked up without restart.

**Cases** (`exp3_ratchets.py`):

| Case | Result |
|---|---|
| C0 control: peer hears Y's own announce | OK (peer encrypts to R_y) |
| **C1 no sharing**, peer holds R_x, route goes to Y | **FAIL.** Y logs "Decryption with ratchets failed"; the packet is dropped silently (no proof); peer retries 4-5 times and gives up. A single missed announce at the peer is enough. |
| C2 X's file merged into Y's before Y announces | OK; Y's list is `[R_y, R_x]`, the peer (frozen on R_x) is decrypted via the retained R_x |
| C3 live **overwrite** of Y's file with X's | Y keeps working until the first failed decrypt, then RNS reloads the file and **R_y is gone**: a peer that cached R_y can no longer reach Y (0 of 1 delivered). Never overwrite; always merge. |
| C4 live **merge** (Y's list first, then X's) on a running Y | OK: the next failed decrypt triggers RNS's own reload; the previously failed message arrives on the peer's next retry (state DELIVERED after 4 attempts) |
| C5 ratchets switched off on X and Y *after* the peer cached R_x | **FAIL**: the peer keeps encrypting to the cached R_x for up to 30 days; an announce without ratchet does not erase it |
| C6 ratchets disabled from the start, fresh peer | OK (base-key encryption; `ratchet_id = none`) |
| C7 Y adopts X's list verbatim, does not rotate, announces | OK: peer sees the *same* R_x, nothing changes for anyone |

**Is merging safe?** Yes, for ratchets specifically: they are opaque private keys, order matters only for which one
is announced (index 0) and for retention (512, oldest dropped), there are no counters or per-key state, and any key in
the set is only ever *tried* for decryption. A union by key value is a G-set. Practical rules:

1. Share the list over the B channel whenever it changes, and at handover. Transmit private keys only inside the
   encrypted B channel; they carry the same confidentiality weight as A's key for past traffic.
2. Merge, do not replace. On the announcer, keep rotation exclusive to that device (otherwise two devices can announce
   different "newest" ratchets); the non-announcers just keep the appended history.
3. The best handover is C7: the new announcer loads the shared list and announces the *current* ratchet unchanged
   (suppress rotation until 30 min after the last rotation of any device).
4. Order the merged list newest first using a group-wide counter or timestamp per key (the RNS file has none, the
   Dart store can add one); cap at 512.

**Alternatives.**

| Option | Trade-off |
|---|---|
| Share ratchets (recommended) | keeps forward secrecy per ratchet; needs the sync channel to be up before the handover, otherwise the C1 window exists for messages encrypted to a ratchet Y does not have |
| Disable ratchets on A | simplest, removes the whole class of failure, but loses ratchet forward secrecy for opportunistic/propagated messages (the base key then decrypts everything ever sent to A). Only safe if done before A ever announced a ratchet: otherwise C5 (30-day tail). Dart-side this is easy (`announce` without ratchet, ratchet field empty). Also, per-message base-key encryption is what the original Reticulum did before ratchets, so interop is unaffected |
| `enforce_ratchets` | only makes sense together with sharing; with enforcement a device lacking the ratchet *never* decrypts, no fallback to the base key |
| Link (direct) delivery | unaffected by ratchets (links use ephemeral keys, RNS docstring `Destination.enable_ratchets`), so direct messages work on any device even in C1 |

**Conclusion.** Without ratchet sharing the design fails in exactly the scenarios it targets (handover to a device
that did not announce, peers with stale caches). With sharing the problem disappears. Ratchet sharing is feasible and
safe; disabling ratchets is a viable fallback for a group created from scratch.

## 4. Propagation (multi-device inbox)

**Code facts.**

* A client sync is: request list (`message_get_request` with `want=None, have=None`, `LXMRouter.py:1702-1725`), then
  request the wanted ones; the response handler **unconditionally** sends the list of what it received back as
  "haves" ("This deletes the messages on the propagation node", `LXMRouter.py:1841-1856`); the node purges every
  transient id it receives as a "have" for that identity (`:1727-1740`). `retain_synced_on_node` only influences the
  list step for messages the client already has (`:1802`); it is a router flag, not a protocol option that survives
  other devices syncing.
* Messages are tied to a destination (`propagation_entries[tid][0] == remote_destination.hash`) and any holder of A's
  identity can request them: the access check is the link identification with A's identity.
* The client first claims the transient id as "processed" (`:2846-2850`) and only then tries to decrypt
  (`:2860`); a message that cannot be decrypted is *not* marked delivered but has already been included in the
  "haves" and purged on the node.
* Expiry on the node: 30 days (`MESSAGE_EXPIRY`, `:48`; `clean_message_store` `:1323`).

**Observed** (`exp4_propagation.py`, PN + P + X + Y + Z; X and Y share ratchets, Z does not):

| Test | Result |
|---|---|
| P1: P sends propagated message; X syncs, then Y syncs | PN holds 1 entry; X receives it (`last_result 1`); **PN entry count drops to 0**; Y's sync returns 0 messages. First syncer wins, other devices never see it. |
| P2: X and Y sync at the same instant | **Both** receive the message (1 each), duplicates 0 reported on each side; PN ends at 0. A race gives duplicates across devices. |
| P3: Z (no shared ratchets) syncs first | Z downloads 1 message, cannot decrypt (0 rx), PN entry count drops to 0; X syncing afterwards gets nothing. **The message is destroyed.** |
| Sender view | the propagated message reaches state `SENT` (4) and the delivery callback fires at that moment (PN accepted it); there is never a delivery confirmation from A. |

**Conclusion / implications.**

1. A propagation inbox is **per-identity, take-once**: only one device should sync A's inbox, and it must forward
   what it fetched to its siblings over the B channel. Every other device syncing A's inbox either gets nothing or
   races. So: the announcer (or an explicitly elected "syncer") is the only device that syncs A's inbox; the rest of
   the group learns from the B channel.
2. A device that cannot decrypt must never sync A's inbox. In particular a freshly paired device that has not yet
   received the ratchet list must wait until it has the shared list.
3. Messages are not lost on the node if the single syncer crashes after downloading but before forwarding to the
   siblings: they are already purged. Mitigation: the syncer persists the received messages durably *before* the
   protocol sends the "haves"; the Dart sync should be written so the purge request is issued only after local
   persistence (and ideally after the B-channel forwarding was queued). The Python client does not offer this hook.
4. Dedupe is still required (P2, plus opportunistic copies, Q5).
5. Sending to B-channel siblings via the PN uses the same mechanism and the same one-consumer logic, which is fine
   because B is single-device (Q7).

## 5. Delivery proofs and duplicates

**Setup** (`exp5_dupes.py`): X holds the path and *loses its proofs* (`Packet.prove` patched to a no-op);
Y announces 3 s after the message arrived at X; the peer's first retry (10 s) is routed to Y. Ratchets shared.

**Observed.** X delivered the message at +0.0 s; Y delivered the *same* LXMF message at +11.8 s. The message hash
(`LXMessage.hash`) was identical on both devices; the sender got exactly one `delivered` callback (at +11.8 s, state
`DELIVERED`, 2 attempts). Each device's own LXMF router dedupes only against its own store (`LXMRouter.py:2239`,
`conditionally_claim_delivered`), so cross-device duplicates are delivered to the app on both.

**Facts.**

* `delivery_packet` calls `packet.prove()` *before* any dedupe (`LXMRouter.py:2264-2265`): every device that
  receives a copy proves it, harmless for the sender (one `DELIVERED`, later proofs ignored).
* `LXMessage.hash = full_hash(destination_hash + source_hash + packed payload)` (`LXMessage.py:383`) is independent of
  encryption, route and retries (it stayed identical across the original send and the retry). The PN *transient id* is
  the hash of the encrypted blob and therefore differs per encryption; it must not be used as a dedupe key.
* For propagated messages the sender never sees a recipient proof (Q4).

**Conclusion.** Dedupe at the app layer by LXMF message hash; the group-wide set of seen hashes is part of the synced
state (tombstone-like, cheap: 32 bytes per message). Every device must be able to receive and store a message that a
sibling already delivered, and should store it once. It is acceptable for the sender to see "delivered" because a
sibling (not necessarily the one the user is looking at) received it: that is a property of "multi-device with one
address".

## 6. Display name

**Observed** (`exp6_name.py`): X and Y configured with different names; four announces alternating X, Y, X, Y. The
peer's `announce` handler saw exactly the announcing device's name each time (`Alice (laptop)`, `Alice (phone)`, ...),
raw app_data `[b'Alice (laptop)', None, [0], None]` = `[display_name, stamp_cost, supported_functionality,
stamp_cost_fractional]` (`LXMRouter.py:1165-1184`). The name is carried in no message (`LXMessage` has no such field;
only the sender hash) and not in the propagation node.

**Conclusion.** The name lives only in A's announce `app_data`; whichever device announces defines what peers show.
Syncing the name is therefore just "all devices hold the same string, the announcer's value is what goes out". Because
`app_data` also carries `stamp_cost` and capability flags, the shared group config must make these identical on all
devices too, otherwise a handover changes more than the name.

## 7. Sibling channel B <-> B on a node that also holds A

**Setup** (`exp7_sibling.py`): X and Y each run one RNS instance with two LXMF routers (A and B), plus a PN.

**Observed.**

* LXMF 1.3.1 **allows only one delivery identity per router** ("Currently only one delivery identity is supported per
  LXMF router instance", `LXMRouter.py:413-416`). A node that holds A and B needs two `LXMRouter` instances in one RNS
  instance (separate storage dirs). It works: both routers came up, received on their own destination only (`via` =
  `A` or `B`), no handler interference. The Dart `LxmRouter` has no such limit.
* B -> B delivery between siblings: direct (link) and opportunistic both ways OK (< 0.1 s on loopback), propagated via
  the PN OK (Y synced `last_result 1`, entry purged). Propagated delivery needed more than 15 s to be stored on the
  PN in our runs (propagation stamp + link), so allow for ~30 s.
* Bootstrapping from a QR/pairing exchange: if Y knows X_B only from a public key (`RNS.Identity.remember`) and X_B
  has **never announced**, a direct message fails (5 attempts, `FAILED`) because the transport (default `full`
  interface mode) does not forward the path request to an unknown destination. After X announced B once, delivery
  worked. A device registered for B would answer a path request itself if it reached it, but it does not in `full` mode.
  So B must announce at least once (and again after network changes), or the hidden channel must use a gateway-mode
  uplink.
* No identity/known-destination clash: A and B are different destination hashes; a device that holds A ignores announces
  for A (it is a local destination, `Transport.py` announce handling skips `destinations_map` entries), which is what
  we want. Nothing ever needs to be *sent as A* between siblings.

**Conclusion.** Feasible with separate routers (Python) or a single router with two destinations (Dart). Caveats: B must
announce (it is hidden in the UI, not on the network), and it should announce on every connection change so siblings
find each other; sibling traffic must never use A as source (it would also confuse the "announcer receives" logic).

## 8. Announce stamps (found while setting up)

RNS 1.6.1 requires a proof-of-work stamp on destination announces (`Transport.py:194-201`: `STAMP_DESTINATIONS = True`,
`DESTINATION_VALUE = 25`); the stamp is generated once per destination and persisted
(`Destination.py:266-283`, `RNS/Stamps.py:975-1018`, file `<rns storage>/stamps/<hash>.dstamp`, 60 bytes). Not enforced
by receivers by default (`STAMPS_ENFORCED = False`) but nodes may enforce it.

**Observed** (`exp8_stamp.py`, real cost 25, Python, one core): X's first announce reached the peer after **32.1 s**
(on-demand stamp; the expected value is about 70 s at ~470 kH/s); after copying X's stamp file to Y, Y's announce
reached the peer after **0.9 s**. The stamp material is `hash + public_key + name_hash` (`Destination.py:381`), so it
is the same on every device holding A.

**Conclusion.** The stamp is part of the shared group state: generate it once (on the creating device) and sync it with
A's key at pairing. A device that has to generate its own stamp before it can announce makes handover take
tens of seconds to minutes (Dart's 3a already generates it in an isolate; on a phone this is far slower than the
Python figure above).

## 9. Recommended adjustments to the PLAN section

1. **Announcer election.**
   * Only the elected announcer registers/answers for A on the network. Non-announcers stay *completely* silent for A:
     no periodic announces and **no path-response announces** (section 1). They may still decrypt/accept A traffic that
     reaches them directly (e.g. a shared LoRa channel) and forward/dedupe it.
   * Election inputs as planned (internet beats LoRa-only, deterministic tie-break by device id) plus: a device with a
     bad clock must not win. Devices should exchange wall-clock readings on the B channel and exclude a device whose
     clock differs from the group median by more than a few seconds.
   * **Monotonic announce timebase.** Because peers and transports order announces by the emission time inside the
     announce (`Transport.py:2631-2638`), the announce timestamp must be `max(local_time, group_last_emitted + 1)`. The
     group's last emitted timebase is part of the synced state. This is in the Dart announcer's control (the
     timestamp is just a field in the signed random blob). *This specific mitigation was not experimentally verified
     (only the failure with skew was); it needs a test with the Dart core and a Python transport.*
   * Make-before-break handover: the new announcer announces first (X still alive, now forwards what it still
     receives), then X steps down. Never allow two announces in the same second (tie = coin flip).
2. **Handover timing.** Detect failure by B-channel heartbeat; target takeover within 10-15 s. Add on top: announce
   propagation (about 1 s), up to ~10 s for opportunistic retries, ~15 s for direct links. Messages in flight are safe
   up to ~50-60 s (peer's 5 attempts); beyond that the sender marks them FAILED. Re-announce immediately on takeover
   (it also retriggers waiting senders, `Handlers.py:11-27`) and on every network change.
3. **Ratchet strategy.** Share the full ratchet list (private keys, newest first, as a merged set, capped at 512) as
   part of the group state over the B channel, continuously and at handover; the announcer alone rotates. Pairing must
   transfer A's key, the ratchet list and the announce stamp *before* the new device can be announcer or syncer. If
   the owner prefers fewer moving parts, disable ratchets on A *from day one* (fresh identity only; C5 shows a tail
   of 30 days if switched on-then-off).
4. **Propagation strategy.** Exactly one device (the announcer) syncs A's inbox from the PN, persists durably, then
   forwards to the siblings over B, and only then acknowledges to the PN (delete). Never run a second consumer of A's
   inbox; a device without the ratchets never syncs. For B (hidden channel) each device syncs its own B inbox
   normally.
5. **Dedupe.** Key = LXMF message hash (`LXMessage.hash`), group-wide seen-set synced between devices; process a
   message exactly once at the app level; never use the PN transient id.
6. **Display name.** Treat name + stamp cost + capability flags as one replicated "announce profile"; the announcer
   publishes it.
7. **Announce stamp.** Replicate the destination stamp with A's key.
8. **B channel.** B must announce at least once on each connection (hidden from UI, but on the network); expect ~30 s
   for propagated B messages.

## 10. Risks and open items

* **Lost sibling sync window (critical).** Any time the announcer receives a message that its siblings have not been told
  about, and then dies, the siblings never see it (inbox purge on the PN, or just no copy). Accept as "the announcer is
  the inbox" and make sure forwarding is eager and acknowledged.
* **Ratchet gap.** If a ratchet is announced and the sync to siblings has not completed when the announcer dies, the
  first messages after takeover encrypted to that ratchet are dropped silently (C1). Mitigation: announce a new
  ratchet only after it was replicated (or rotate only with a "replicated" ack from the siblings).
* **Clock skew** (section 1) can strand A's path for up to 7 days if one device announces with a far-future clock.
* **Path-response behaviour of other implementations** (MeshChatX, Sideband, `rnsd`) is the RNS one: any silent device
  that is a registered A *must* not exist on the same interface as the announcer unless it suppresses path responses. This
  is only controllable inside our own Dart stack, so non-Kestrel clients holding A are out of scope.
* **Lost/stolen device** keeps A's private key and the ratchet history (honest limit already in the PLAN). The shared
  ratchet history also exposes past ratcheted traffic captured by an attacker.
* **LoRa**: transmitting the ratchet list and stamp over a constrained link is cheap (32 bytes per ratchet, 60 bytes
  stamp) but the announce cadence and the B-channel heartbeat must respect airtime. Not measured here (TCP loopback only).
* **Not tested**: Dart core behaviour, real network latencies, shared-medium broadcast (LoRa, AutoInterface) where several
  devices hear the same packet and each proves/delivers it (duplicates then happen without any handover; covered only by
  the dedupe requirement), Resource-sized messages, IFAC networks, announce rate limiting by real transports,
  PN stamp/peering policy differences.

## 11. Is anything infeasible?

No. The design is feasible with the following non-negotiables, none of which exist in stock RNS/LXMF and all of which are
inside our Dart stack: (1) non-announcers never answer path requests for A; (2) a group-wide monotonic announce
timebase; (3) shared ratchet list and announce stamp replicated before a device may announce or sync; (4) exactly one
consumer of A's PN inbox, with persist-before-purge and eager forwarding; (5) app-level dedupe by message hash.
Everything else (handover in ~15 s, B channel direct/opportunistic/propagated) works as the PLAN describes.
