# Plan: Kestrel — LXMF bridge + the phone's own identity

> Living document. Updated after every phase. Phase status is at the bottom.
> Division of roles: the **orchestrator** (Opus) — specs, briefs, review; **Sonnet writes the code** (subagents).

---

## 1. Goal

One Flutter app (Android now, iOS later) that works in **two modes**:

| Mode | Whose name I write under | Who knows about me |
|---|---|---|
| **Standalone** (bridge off) | the phone's identity `B` | those I gave the `B` address to |
| **Bridge** (bridge on) | `A` (MeshChatX on `amd1`) **via** `B`; and I can still write as `B` | friends know `A` |

The transport is the same in both modes: **TCP** → `rns.ostapyrih.com:4242` when online, **BLE → RNode (LoRa)** without internet.

`A` is never duplicated on the phone → zero routing conflicts.

---

## 2. Key requirement: modes never erase data, everything is transparent

1. **Switching Bridge ON/OFF deletes nothing.** The chats of `B` and the chats of `A` (from the bridge) live side by side in the local DB, each record marked with the identity it belongs to.
2. **`B` does not stop being `B` when the bridge is on.** Direct messages to `B` keep arriving and are shown (as a separate account).
3. **Every message shows how it was sent/received:**
   - **From:** `A (via bridge)` or `B (phone)`
   - **Route:** `direct` (Link) / `opportunistic` / `propagated` (via a propagation node) / `via bridge` (a command to `amd1`, then `A` sent it itself)
   - **Phone transport:** `TCP` / `LoRa (RNode)` / `queued (offline)`
   - **Status:** `queued → sent to bridge → bridge confirmed → delivered to recipient` (or `error` with a reason)
4. **UI:** an account switcher in the chat list header (`A`, `B`, `All`), an identity badge on every chat, and on every message a small icon row "from · route · transport · status". Tapping a message → details (message hash, time of each stage).
5. **The composer always shows who the message will be sent from.** In Bridge mode by default: in an `A` chat → from `A`, in a `B` chat → from `B`. No silent sender substitution.
6. **The offline queue preserves the chosen path.** If a message is queued "from `A` via bridge", it will not turn into "from `B`" when the bridge is turned off: it stays in the queue marked "bridge off" with the buttons *Send when the bridge is on / Cancel*.

> **Decision (recommended, may be revisited):** a single phone identity `B` plays both roles: its own LXMF address and the bridge control key. This does not weaken security, because the bridge verifies the full public key of `B` and the signature. The alternative is a separate hidden control identity `C` used only for the bridge, so that the `B` address is never exposed in connection with `A`. It adds complexity; to be decided before Phase 3.

---

7. **Bridge off = a normal messenger** (decided 2026-11-26). With the bridge disabled the app is a plain single-identity LXMF client: there is no account switcher and no A/B badges or labels, and the message line shows only route · transport · status. Account A's local data is only a cache of MeshChatX, so turning the bridge off **deletes it from the device** (chats, messages, rooms, cursors) after a confirmation, and turning the bridge back on resyncs it from scratch (decision updated 2026-11-26). The device keeps its pairing, so no re-pairing is needed. Unsent A messages exist only on the device: the confirmation names them and offers Cancel / send them from B instead / discard. The device's own data (B) is never deleted by a mode switch. With the bridge off its connection is fully stopped.

## 3. Architecture

> **Decision (2026-11-25, after Phase 0):** the bridge is the **`kestrel-bridge` sidecar container**, not a MeshChatX plugin.
> Reason: the official Plugin API does not pass LXMF/RRC events to the Python backend, cannot hide service messages
> and does not expose RNS objects; working around it through internals is fragile. Details — `docs/private/` (not in git).

```
Flutter UI ── SQLite (accounts, chats, messages, outbox, delivery_log)
   │
Mobile RNS + LXMF (pure Dart), identity B
   ├── TCPClient → rns.ostapyrih.com:4242   (HDLC)
   └── BLE → RNode → LoRa                    (KISS + radio config)
                 │
Reticulum on amd1 (transport + propagation node, shared instance)
   ├── MeshChatX (identity A)  ←── HTTP API + WebSocket ──┐
   └── kestrel-bridge sidecar (identity S, shared instance client) ┘
```

- `S` is the bridge's server-side service identity. It is **not** an address for friends; friends know only `A`. There is no conflict, because `A` exists only in MeshChatX.
- Service traffic `B ↔ S` **never reaches `A`'s inbox**, so nothing needs to be hidden.
- `S` controls `A` only through MeshChatX's authenticated HTTP/WebSocket API. Credentials live only on the server.
- The MeshChatX image stays `latest-extra` (user's decision) → at startup the bridge checks the MeshChatX version and has contract tests for the endpoints it needs.

### Bridge protocol (B ↔ S)
- **Online (TCP):** an RNS **Link** to the `S` destination → `link.identify()` with the `B` key → request/response:
  `sync_chats(since_ts)`, `get_messages(chat, before, limit)`, `list_rooms`, `get_room_messages`, `send_lxmf`, `send_rrc`.
  Large responses use an RNS Resource (compressed). Push events go over the open Link.
- **Offline / LoRa:** the same commands as LXMF messages `B → S` (custom fields, msgpack); responses and push as LXMF `S → B` (with fallback via a propagation node).
- **Every command:** `cmd_id` (UUID) + `ts`. `S` replies with `ack(cmd_id, result, lxmf_hash_from_A)`, so the phone knows exactly which message `A` sent and then shows its delivery status.
- `protocol_version` in every handshake; incompatibility is shown in the UI.

### Bridge security
- Whitelist = the **full public key of `B`** in `S`'s config (on the server, not in the repo).
- Link: commands are accepted only after `identify()` with a key from the whitelist. LXMF: only if `signature_validated == True` and the key matches.
- Anti-replay for LXMF commands: a window on `ts` (e.g. ±24 h for propagated) + a log of executed `cmd_id`s.
- Push **depends on the transport**: if `B` is reachable over a LoRa interface (`Transport.next_hop_interface`), only personal LXMF messages and mentions are sent, with a size limit; the rest is picked up on the next TCP sync.

### Facts from Phase 1a (affect the bridge implementation)
- **Auth:** only a single MeshChatX web UI password, no API tokens and no service users → the sidecar holds that password (only in the server config, permissions 600). On a 401 it logs in again; it **never calls logout**, because that invalidates all sessions. Login is rate-limited, so backoff is needed.
- **WS** does not replay missed events → after every reconnect the sidecar resyncs over HTTP. Ping every 30 s; subscribe only to `lxmf` and `rrc`.
- **The conversation list** has no `since` and no unread counter → the sidecar keeps its own cursors (last `id` per conversation) in its own SQLite.
- **RRC:** text starting with `/` is executed as a hub command on behalf of `A` → in `send_rrc` such messages are **rejected** (or escaped). Reading history resets the active room in the desktop UI → call `POST /rrc/active/clear` afterwards.
- **Shared instance:** `network_mode: service:meshchatx`, `share_instance=Yes`, `require_shared_instance=True`, no interfaces. The path table (for transport-aware push) needs the `rpc_key`. If the MeshChatX container is recreated, the sidecar must be restarted (healthcheck + `restart: unless-stopped` + watchdog).
- **Compatibility:** `/status` → `version`; `/app/info` → `api_version`. The sidecar has a version allowlist, checks keys in API responses, and CI has contract tests.

### Mobile constraints
- iOS does not keep TCP alive in the background → the bridge sends an "empty" push (ntfy/APNs/FCM, no content) and the app syncs when opened. BLE to an RNode may work in the background on iOS.
- Android: a foreground service for a persistent connection.

---

### Transport decision (2026-11-26)
Reticulum everywhere stays: the app talks to the bridge only over RNS (TCP online, RNode offline). An HTTPS/WebSocket transport for online mode was considered (less fragile online, no announces/stamps/path discovery) and **rejected** to keep a single implementation in the app.

Consequences:
- The bridge disables RNS announce and path-request stamping by default (`[rns] stamps = false`). Its announces are reached through the owner's own transport node, and proof-of-work does not finish on small servers.
- Server capacity matters. MeshChatX keeps running as a public propagation node, so it needs enough CPU (stamp validation) and `/dev/shm` (multiprocessing). Tune the peering limits rather than disabling the node.

## Multi-device (decided 2026-11-26)

- Reticulum forbids running one identity on several devices at once (path flapping, random delivery). Therefore **every device has its own identity**: `B-pc`, `B-iphone`, `B-android`, … (generated locally, the key never leaves the device). Account `A` (via the bridge) is the shared account on all devices; MeshChatX on the server is the single source of truth for `A`'s history.
- The bridge serves many devices at once: the whitelist holds several keys; every device keeps its own sync cursor; push events fan out to all connected device Links; offline devices catch up via sync. Delivery state and read state propagate to all devices (read state via MeshChatX mark-as-read).
- Every message sent as `A` records the originating device (the bridge keeps an `lxmf_hash → device` mapping in its state and returns it in sync/push), so the UI shows e.g. "A · from iPhone · direct · delivered".
- LoRa/LXMF fallback push goes only to devices flagged as "field" devices; the others catch up over TCP.
- **Device pairing via QR (decided):** the new device shows a QR with its public key; an already-trusted device scans it and approves; the approval is a request signed by the trusted device's identity over its identified Link; the bridge stores the dynamic device list in its own state (the server config only bootstraps the first device). Settings → "My devices": name, platform, last seen, revoke. Revoked keys are rejected immediately and their Links closed.
- **Standalone history sync (decided: yes, via the bridge, end-to-end encrypted):** devices share a device-group key, distributed during pairing (the approving device encrypts it to the new device's public key). Each device uploads its Standalone (`B-x`) messages as encrypted append-only blobs to a bridge "vault"; other devices pull and decrypt them and show them read-only with a device badge ("B-android"). The bridge only stores opaque ciphertext and cannot read it. Revocation rotates the group key; new blobs use the new key.
- This requires **bridge protocol v2**: `/devices/list`, `/devices/approve`, `/devices/revoke`, `/devices/rename`, `/vault/put`, `/vault/list` (cursor), `/vault/get`, device id in `/hello`, per-device cursors, origin device in message records.
- **Desktop:** Flutter Windows, macOS and Linux builds from the same code. Releases ship a Windows .zip (or installer), a macOS .dmg (unsigned), a Linux AppImage/tar.gz. On desktop an RNode connects via USB serial (KISS), not BLE.

---

## Device group mode without the bridge (decided 2026-11-27, required before 1.0.0)
The main way to use Kestrel on several devices does not need MeshChatX or the bridge.
- **Layers, not modes.** Device group sync is the base and is always on. The MeshChatX bridge is an optional add-on: it adds the chats of the MeshChatX identity to the same list (marked "MeshChatX", replies go through the bridge). If the bridge is unavailable, everything else keeps working and only the MeshChatX chats stop updating.
- **MeshChatX keeps its own identity (decided 2026-11-27, option 2).** Its key never leaves the server; the group identity A is separate and never shared with MeshChatX. No announcer conflict between the server and the devices.
- **A = the one main identity of the device group**, created by the first device and shared with every paired device (key transferred encrypted during QR pairing). It is the only identity used to talk to people, on every device.
- **No chat identity B.** Each device has only a hidden internal device key, used between the user's own Kestrel clients (sync, coordination) and to authenticate to the bridge. Never shown in the UI, never used for chats. Existing B chats from earlier versions stay as read-only history.
- **One announcer at a time.** Online devices agree which one announces A (prefer internet over LoRa-only, then a deterministic tie-break by device id); handover with a fresh announce; a device that hears no sibling announces itself. The announcing device receives inbound messages and forwards them to the siblings over the B channel; ratchet keys of A are shared over the same channel so any device can decrypt messages already in flight.
- **Sync over LXMF between the devices' B destinations:** direct Link when both are online (bulk catch-up), via a propagation node otherwise (needs phase 5). Data format reuses the vault envelope (group key, per-device seq, tombstones). On LoRa only compact text events; history catch-up when on a fast link.
- **One display name** for A, synced across devices; renaming on any device renames everywhere and is used in A's announces.
- **Spike results (2026-11-27, `docs/spikes/device-group.md`, RNS 1.6.1 / LXMF 1.3.1): feasible**, with these rules:
  - exactly one announcer; non-announcers must never answer path requests for A (else they hijack the path);
  - group-wide monotonic announce timebase `max(now, last_group_timebase + 1)` plus a clock sanity check in the election (a device with a clock ahead blocks takeover);
  - before a device may announce or sync it receives A's key, the **merged** ratchet list (never overwrite) and A's announce stamp (generating a cost-25 stamp takes tens of seconds; copying it makes announces instant); only the announcer rotates ratchets;
  - a propagation node deletes a message after the first download, so exactly one device (the announcer) syncs A's propagation inbox, persists first, then forwards to siblings over the device channel;
  - make-before-break handover with an immediate announce: in-flight messages reach the new announcer within the sender's retry window (~10 s opportunistic, ~15 s direct);
  - dedupe by LXMF message hash, never by propagation transient id;
  - device channel keys must be announced at least once to be reachable.
- **Security invariants carried over from the vault:** every device-sync record is decrypted only through `VaultCrypto.decryptBlob` (Token has no associated data, so the inner `blob_id`/`device_id`/`seq`/`key_epoch` must equal the outer metadata — never bypass this check); per-device `seq` continuity detects missing records. Key re-sharing between devices (absent in the bridge vault: no `/vault/reshare`, a keyless device waits for a revocation or re-pairing) becomes a normal device-to-device message in phase S.
- **Honest limit:** a lost/stolen device keeps A's private key. Remedy: "change address" (new A, contacts notified), not revocation.

## 4. Data model on the phone (SQLite)

- `accounts` — `A` (bridge, remote) and `B` (local): hash, name, type.
- `chats` — `account_id`, `peer_hash` or `room_id`, `kind` (lxmf/rrc), `last_ts`.
- `messages` — `account_id`, `chat_id`, `direction`, `lxmf_hash`, `text`, `ts`,
  `sender_identity` (A/B), `route` (direct/opportunistic/propagated/via_bridge),
  `transport` (tcp/lora/none), `status`, `error`.
- `outbox` — the queue, with `sender_identity` + `route` **fixed** at creation time.
- `delivery_log` — delivery stages with timestamps (for the details screen).

Switching modes changes only `settings.bridge_enabled`; no DELETEs on data.

---

## 5. Phases

| # | Phase | Result / done criterion | Status |
|---|---|---|---|
| R | Repo + CI/CD | public `ostapyrih/kestrel`, monorepo `app/` + `bridge/`, `ci.yml`, releases (APK/AAB/IPA, bridge Docker image), release-please with changelog. Details — `CLAUDE.md` | ✅ |
| 0 | Reconnaissance of the MeshChatX Plugin API on `amd1` (read-only) | report in `docs/private/`. Conclusion: the official Plugin API is not enough → sidecar | ✅ |
| 1a | Reconnaissance of the MeshChatX HTTP/WebSocket API + connecting to the shared instance (read-only) | report in `docs/private/`: the API covers LXMF/RRC/WS; limitations — below (§3, "Facts from Phase 1a") | ✅ |
| 1 | `kestrel-bridge` sidecar + tests | PR #2 merged: protocol v1 (`docs/bridge-protocol.md`), Link RPC with `identify()`, LXMF commands with anti-replay, push, LoRa profile; 82 unit tests + an integration test in CI. **Remaining:** smoke test against a real MeshChatX and deploy to `amd1` — only with the user's "yes" | 🟡 code ready |
| 2 | Dart RNS core + golden tests (`packages/kestrel_rns`) | PR #1 merged: identity, token, packet, announce, HDLC/KISS, msgpack, LXMF — matches Python RNS 1.6.1 / LXMF 1.3.1 in both directions (271 tests + 80 cross-checks in Python) | ✅ |
| 3a | Network layer in `kestrel_rns` | PR #3 merged: TCP, Transport (endpoint), Link + identify + request/response, Resource (≤1 MiB), ratchets, announce stamps; 345 tests, 36 integration tests against Python RNS 1.6.1, including Dart↔Dart through a Python transport. Deferred: Resource >1 MiB, Channel/Buffer, IFAC | ✅ |
| 3b | LXMF + Standalone mode + UI | PR #5 merged: `LxmRouter` (opportunistic/direct/resource, receipts, retries, stamps) — interop with Python LXMF; app: identity B in secure storage, SQLite per §4 (triggers fix the outbox, a test that the switch deletes nothing), chats with "from · route · transport · status" badges, settings + QR; debug APK in CI. Deferred: tickets, QR scanner, background service | ✅ |
| 4 | Bridge mode in the app + multi-device (protocol v2: devices, per-device cursors, origin device, QR pairing) | switch, A/B accounts, sync, sending via the bridge, route/transport/status badges, queue | ✅ app 0.5.0 + bridge 0.4.1: bridge client, account A sync, send as A, devices/QR pairing, RRC, LXMF fallback (PR #12, #17, #19); deployed on amd1, first real device connected 2026-11-26. app 0.6.0 + bridge 0.5.0: reject reason for unapproved/revoked devices (PR #20), invite-QR pairing from the trusted device, app-owned device name, "B (this device)" / "B · <name>" labels, bridge off = plain messenger with account-A purge (PR #22) |
| 4b | Standalone history vault (E2E-encrypted sync of B-x chats via the bridge) | devices share a group key; encrypted append-only blobs in the bridge vault; read-only device-badged history on other devices | ✅ app 0.7.0 + bridge 0.6.0 (PR #24): vault-aware invites (`vault_invite`), crypto envelope + golden vectors, key management, uploader/downloader, read-only chats, sync status in Settings |
| U | Updates (decided 2026-11-26) | Desktop: built-in updater (GitHub Releases check, changelog, one-click install, SHA256 + Ed25519 release-signature verification with the public key embedded in the app; Windows Inno Setup installer, macOS app replace from dmg, Linux AppImage in-place). Android: Obtainium (stable release keystore in CI secrets, `obtainium://` link in README). iOS: AltStore source (done). Signing keys in GitHub Secrets; owner keeps offline backups | ✅ app 0.6.0 (first signed APK; existing Android installs need one reinstall) |
| N | NomadNet browser (decided 2026-11-26) | Browse NomadNet node pages directly from the device identity (B), without the bridge, so it also works over LoRa: Link + `/page/*.mu` requests, Micron markup renderer (colors, links, form fields), address bar/history/bookmarks, node list from announces, file downloads, form submission. Scheduled after 4b, before 6. No server changes, no new protocol | ✅ app 0.8.0 (PR #28): node list from announces, Micron renderer (tables/images/partials not yet), forms, files up to 16 MiB (multi-segment Resource), bookmarks/history/cache; works without the bridge |
| X | Chat deletion (owner request 2026-11-27) | delete own B chats, account A chats (in MeshChatX, all devices) and other devices' chats (everywhere, via vault tombstones); no resurrection on resync | ✅ app 0.8.0 + bridge 0.7.0 (PR #26) |
| N2 | Browser data sync (owner request 2026-11-27) | NomadNet bookmarks/favourite nodes, history and per-node settings (zoom, wrap, identify) sync across the user's devices over the device sync channel (vault blob kinds now; the same records move to phase S transport later); deletions as tombstones; history capped (e.g. last 500 entries) | ✅ app 0.9.0 (PR #38) |
| 5 | Propagation sync + offline queue | `B` fetches messages from a propagation node | ✅ app 0.9.1 (PR #43): client-only LXMF propagation — node discovery/selection (auto or pinned), PROPAGATED send with node stamps, fallback from failed direct delivery, inbox sync with persist-before-haves, dedupe by message hash; one node at a time, no tickets |
| 6 | RNode: BLE on mobile, USB serial on desktop | KISS + radio config (parameters = those of the LoRa gateway), `LoRa` transport badge. Radio defaults: common European preset (868 MHz band); every radio parameter (frequency, bandwidth, SF, CR, TX power) is editable in Settings (owner decision 2026-11-27) | 🟡 PR open |
| S | Device group sync without the bridge (decided 2026-11-27) | shared main identity A on all devices, hidden per-device B for sync, announcer election + handover, inbound forwarding, ratchet sharing, LXMF sync (direct + propagation), synced display name, change-address flow. Spike done (PR #36): feasible with the rules in the section above. Order (owner, 2026-11-27): 6 (+7) → release, S → release, V → release; 1.0.0 only with the owner's explicit approval | 🟡 in progress; released together with 6, 7 (owner, 2026-11-27). one PR (S1 primitives, S2 group/pairing/migration/UI, S3 sync/election/forwarding; `docs/device-sync.md`); known gaps listed there |
| V | Voice: LXST calls + voice messages (decided 2026-11-27) | Live calls over LXST (compatible with Sideband / MeshChatX Telephone) only on fast transports (TCP/internet), Opus; from identity B, never through the bridge. On LoRa: **voice messages only** (no live calls) — record, compress with Codec2 (low bitrate), send as an LXMF audio field compatible with Sideband, play back. Call UI, ringing, earpiece/speaker, echo cancellation; incoming calls in the background tie in with phase 7 (CallKit on iOS). Scheduled after 6 and 5 | ⬜ |
| 7 | Background operation + notifications (iOS builds already run in GitHub Actions; no local Mac build needed) | New-message notifications on all platforms (incl. desktop while hidden in the tray); Android foreground service keeps RNS running; iOS: no APNs (no Apple Developer account, AltStore sideload) — BGAppRefresh/background fetch checks the propagation inbox and shows local notifications, plus whatever the app can do while foregrounded/suspended | 🟡 PR open: local notifications everywhere (per-chat mute, hide content, no notification for the open chat, cleared when read elsewhere), Android foreground service (`remoteMessaging`) + battery prompt, iOS BGAppRefresh inbox check via `workmanager` (periodic, decided by iOS, no APNs), desktop toasts while hidden/unfocused |
| D | Desktop builds (Windows/macOS/Linux) + USB RNode on desktop | PR #9 merged: Windows .zip, macOS .dmg, Linux tar.gz + AppImage (all unsigned) in releases; two-pane layout ≥ 900 px; device name setting; Windows/Linux CI. Remaining: USB RNode (Phase 6), verify unsigned macOS keychain on a real Mac | 🟡 builds done |

**Environment:** development on Windows (`C:\Users\ostap\Projects\meshchatx-mobile`), Flutter is installed here. The iOS build is done on a Mac (x86_64) with git.

---

## 6. Open questions

> **LoRa gateway (answered 2026-11-26):** the owner relies on community-run LoRa transport nodes with internet uplinks to carry traffic between the field and the public Reticulum backbone that `amd1` is connected to. No own gateway is planned. Consequences for Phase 6:
> - RNode radio parameters must be user-configurable (frequency, BW, SF, CR, TX power), with presets for common community setups.
> - Path discovery over LoRa goes through path requests forwarded by community gateways (their interface mode and announce caps apply), so the app must tolerate slow discovery and stamp path requests if a gateway enforces stamps.
> - Bridge traffic over LoRa must stay minimal (the constrained push profile, small acks).
> - No delivery guarantee: if no community gateway is in range, only Standalone (`B`) to nearby peers works. The UI must make that visible.

1. Is there a physical LoRa gateway (an RNode attached to a transport with a path to `amd1`) and what are its radio parameters?
2. ~~One identity per device~~ — decided: every device has its own identity `B-x` (see Multi-device). Still open: whether `B-x` also serves as the bridge control key or a separate hidden control identity is used (see §2).
3. Background notification channel: ntfy (self-hosted) or APNs/FCM?
4. ~~Plugin API~~ — resolved: sidecar (§3).
6. **Announce stamps:** RNS 1.6 adds a PoW stamp to announces by default; Dart does not generate it yet. Stamps are not required on `amd1`, but other nodes of the network may require them — generation was implemented in 3a (cost 25, separate isolate, cached per destination). In 3b, measure the time on a real phone.
5. There is currently **no RNode interface** on the server: LoRa needs a gateway (an RNode on `amd1` or another transport node with LoRa and a network uplink).

---

## 7. Verification

- Bridge: `python -m unittest` (identify with a foreign key → rejected, LXMF without a valid signature → rejected, replay → rejected, MeshChatX HTTP API contract tests on mocks).
- Dart: `flutter analyze && flutter test` (golden vectors, DB: switching modes does not delete rows).
- Manual tests: TCP online in Standalone and Bridge; LoRa via an RNode; verify that every message has the correct "from / route / transport / status" badges.
