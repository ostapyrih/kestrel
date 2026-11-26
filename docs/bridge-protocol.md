# Kestrel bridge protocol

`protocol_version`: **2** (supported range: min 2, max 2)

Any wire-visible change must bump `protocol_version` and update this file. A client can be
written from this document alone; where it says MUST / MUST NOT it is normative.

Parties: **D** = a device of the user (phone, desktop; each has its own RNS identity), **S** = sidecar
identity (`kestrel-bridge`), **A** = MeshChatX identity (controlled by S through the MeshChatX
HTTP/WebSocket API). See [PLAN.md](PLAN.md) section 3. Traffic between a device and S never reaches
A's inbox.

## Changes from v1

v1 had a flat whitelist of phone keys and one global view. v2 (breaking, no v1 compatibility):

- **Devices**: a registry of devices (bootstrap devices from the server config, dynamic devices added by QR
  pairing), roles, per-device `last_seen`, revocation (section 4).
- **Pairing via QR** (`/devices/approve`) and `/devices/list|rename|set_role|revoke` (section 5).
- **Origin device**: outgoing messages carry `origin_device` and `cmd_id` (section 6.4).
- **Read state**: `/mark_read` and the `read_state` push (section 6.5).
- **Cursors**: `/hello` and `/sync_chats` return `state_id`; a state change of an outgoing message now makes its
  conversation reappear in `/sync_chats` (section 6).
- **Push**: every push has an event `id`; new events `read_state`, `device_added`, `device_updated`,
  `device_revoked`, `vault.blob`; topic `vault`; fan-out and LXMF-fallback rules (section 7).
- **Vault** (`/vault/*`): opaque E2E-encrypted blob storage and group-key epochs (section 9).
- `/hello`: min/max supported versions, own device record, `state_id`, vault info. `protocol_mismatch`
  carries the supported range.
- LXMF commands use `"v": 2`; `/devices/*` and `/vault/*` exist only on the Link transport.
- Config: `[[devices]]` replaces `[whitelist]` (the old key is still read as bootstrap devices, with a warning).

A v1 client calling `/hello` with `protocol_version: 1` gets `protocol_mismatch` with
`details: {server_version: 2, min_version: 2, max_version: 2, client_version: 1}` and MUST tell the user
to upgrade. Its LXMF commands (`"v": 1`) are answered with the same error. Nothing else works for it.

## 1. Conventions

- All payloads are **msgpack** maps with **string keys**. Hashes are **lowercase hex strings**,
  timestamps are numbers (Unix seconds, UTC; floats), counters are integers. **Binary fields**
  (explicitly marked `bin` below: public keys inside the QR payload, signatures, ciphertexts, wrapped
  keys) are msgpack `bin`, not hex. Unknown keys in requests and responses MUST be ignored.
- "hash32" is a 32-character lowercase hex string (16-byte RNS hash). A **device_id** is the RNS identity
  hash of the device (`Identity.hash` = first 16 bytes of SHA-256 of the 64-byte public key), as hash32.
- A **public key** (`public_key`) is 64 bytes (X25519 32 + Ed25519 32), as 128 hex chars, = `Identity.get_public_key()`.
- D is configured out of band with S's **destination hash** (aspect `kestrel`, `bridge`) and S's **public key**
  (`kestrel-bridge --print-address`). S's identity is a service identity and NOT the address friends use (that is A).
- **Cursors** are unsigned integers that the client stores per bridge and passes back unchanged. They are opaque:
  clients MUST NOT compute with them. Initial value 0. They are held by the client; the bridge keeps no
  per-device read position, so any number of devices sync independently (section 6).

## 2. Online transport: RNS Link

### 2.1 Connection
1. D builds `RNS.Destination(S_identity, OUT, SINGLE, "kestrel", "bridge")` from S's public key, resolves a
   path (S announces every `rns.announce_interval` seconds, default 1800; D may send a path request) and
   opens an `RNS.Link`.
2. D MUST call `link.identify(D_identity)` right after the link is established. The bridge looks up the
   **full public key** of the identified identity in the device registry.
   - Unknown or revoked key: the link is torn down immediately.
   - Not identified within `limits.identify_timeout` (default 30 s): the link is torn down.
   - Before `identify()` every request is answered with `unauthorized`.
3. D sends `/hello`, checks the result (4.1), then `/subscribe` if it wants push.

A device may hold several Links (reconnects overlap); each is authorized independently, each can subscribe.

### 2.2 Requests
`link.request(path, data)`; `path` is one of section 4-9; `data` is the request map. The response is one of

```
{"ok": true,  "result": { ... }}
{"ok": false, "error": {"code": "<code>", "message": "<text>", "details": { ... }?}}
```

`error.code` is stable (section 11); `message` is English text, not for parsing. Responses larger than
`limits.max_response_bytes` (default 262144) become `response_too_large`.

### 2.3 Push
Push events travel over the same Link after `/subscribe`:

```
{"t": "push", "seq": <int>, "id": "<hex16>", "ts": <float>, "event": "<name>", "data": { ... }}
```

- Sent as an RNS **packet** when it fits the link MDU, else as an RNS **Resource**. D MUST handle both
  (`link.set_packet_callback`, `link.set_resource_strategy(ACCEPT_ALL)` + `set_resource_concluded_callback`).
- `seq` increases by one per delivered envelope per bridge process; `id` identifies the event (the Link copy and the
  LXMF fallback copy of one event share it). Push is **best effort** with no acknowledgement: gaps in `seq`, a link
  reset or a `resync` event mean "sync via `/sync_chats`". After every reconnect D MUST resync. D MUST treat
  events idempotently and MAY drop an event whose `id` it already processed.

## 3. Offline / LoRa transport: LXMF fallback

Used when no Link is possible. S runs its own LXMF router on the same identity (`lxmf.delivery` hash
printed by `--print-address`). Commands are LXMF messages D -> S, responses and push S -> D.

- LXMF `content` and `title` are empty. Payload in custom fields (`LXMF/LXMF.py`): `FIELD_CUSTOM_TYPE` = `0xFB`
  (bytes: `b"kestrel.cmd"`, `b"kestrel.resp"`, `b"kestrel.push"`) and `FIELD_CUSTOM_DATA` = `0xFC` (bytes, msgpack).
- Command: `{"v": 2, "cmd_id": "<id>", "ts": <float>, "path": "/send_lxmf", "args": {...}}`. `cmd_id`: 8-64 chars
  `[A-Za-z0-9_-]`, unique per command. `args` is the request map of the same path on the Link.
- Response: `{"v": 2, "cmd_id": "<id>", "ok": true, "result": {...}}` or `"ok": false, "error": {...}`.
- Push: the envelope of 2.3 as `kestrel.push`.
- Available paths over LXMF: `/hello`, `/sync_chats`, `/get_messages`, `/list_rooms`, `/get_room_messages`,
  `/send_lxmf`, `/send_rrc`, `/mark_read`. **Not available** (`unsupported_transport`): `/subscribe`, `/devices/*`, `/vault/*`.
- Responses are limited to `limits.lxmf_max_response_bytes` (default 8192). S replies with OPPORTUNISTIC delivery (upgraded to a
  link when too large) and, if `push.propagation_node` is configured, retries via that node.
- Fallback push: see 7.3.

## 4. Devices

### 4.1 Device record
```
{"device_id": hash32, "public_key": hex128, "name": str, "platform": str, "roles": ["field"?],
 "bootstrap": bool, "added_by": hash32|"config", "added_at": float, "last_seen": float|null,
 "revoked_at": float|null}
```
- `name`: 1-64 UTF-8 bytes, no control characters. `platform`: `[a-z0-9][a-z0-9._-]{0,31}`
  (`android`, `ios`, `windows`, `macos`, `linux`, `unknown`, ...).
- `roles`: `field` = the device receives the LXMF/LoRa fallback push while it has no live Link (7.3). No other role exists;
  every trusted device is equally trusted (it can approve, rename, change roles of and revoke any device, itself included).
- `added_by`: the approving device's id, or `"config"` for bootstrap devices. `last_seen`: last identified request (updated live,
  persisted at most once a minute). `revoked_at` non-null = revoked.
- A device list result adds `online: bool` (the device has a live Link).

### 4.2 Bootstrap devices, precedence
- Devices in the server config (`[[devices]]`: `public_key`, `name`, `platform`, `roles`) are **bootstrap devices**: trusted from the
  first start, `bootstrap: true`. Dynamic devices (QR pairing) live only in the bridge state database (sqlite).
- The state database is authoritative at runtime. At every start the config **seeds** missing devices; it never overwrites `name`/`roles`
  edited through the protocol and **never un-revokes**. A bootstrap device revoked through the protocol stays revoked across restarts
  even though it is still listed in the config. The operator can undo this with `kestrel-bridge --reinstate <device_id>` (bridge stopped).
- A device that was bootstrap but is no longer in the config is revoked at the next start (fail closed).
- The deprecated `[whitelist] phone_public_keys` is read as bootstrap devices (`name` = `device-<6 hex of id>`, platform `unknown`).

### 4.3 Revocation
- `revoked_at` is permanent: a revoked identity cannot be paired again (`device_revoked`); the user creates a new identity.
- On revocation the bridge **closes every Link of that device immediately** (a device revoking itself gets the response first; its
  Link closes about a second later), drops its subscriptions, rejects every further request with `device_revoked` (Link and LXMF; over LXMF
  with no reply), pushes `device_revoked` to the other devices and bumps the vault `key_epoch` (section 9).
- The **last remaining trusted device cannot be revoked** (`last_trusted_device`).
- A client that receives `device_revoked` (response or Link closed followed by `device_revoked` on reconnect) MUST wipe the bridge
  account's local credentials and tell the user.

## 5. Pairing (QR) and device administration

All `/devices/*` paths need an identified Link. Admin paths (`approve`, `rename`, `set_role`, `revoke`) are rate limited
(`limits.device_admin_rate_per_minute`, default 20 per device).

### 5.1 QR payload
The **new** device shows a QR code with the text

```
kestrel-pair:v1:<base64url(msgpack payload)>        # RFC 4648 section 5 alphabet, no padding
payload = {"pubkey": bin(64), "name": str, "platform": str, "nonce": bin(16..32), "ts": number}
```
`pubkey` = the new device's public key, `name`/`platform` as in 4.1 (proposed values), `nonce` = fresh random bytes (16 recommended),
`ts` = the new device's current time (Unix seconds). A QR code expires after `limits.pairing_window` (default and maximum 600 s):
the device regenerates it (new nonce) periodically. The new device MUST keep its private key local; only the public key travels.

### 5.2 `/devices/approve`  (trusted device, Link)
The approving device scans the QR, decodes the text to the exact payload bytes `P` (base64url-decode, **do not re-encode**) and sends

```
{"payload": bin(P), "signature": bin(64), "name": str?, "roles": ["field"]?,
 "key_epoch": int?, "wrapped_group_key": bin?}
signature = Ed25519 signature of (b"kestrel-pair-approve:v1:" || P || approver_device_id_as_16_raw_bytes)
            made with the approver's identity (`Identity.sign`)
```
The domain-separation prefix keeps the signature from being valid in any other context. The bridge checks in this order:
1. the caller is trusted and not revoked (`device_revoked` / `unauthorized`);
2. `P` parses, field types and sizes are valid (`pairing_invalid`);
3. `abs(now - ts) <= pairing_window` (`pairing_expired`, `details.server_time`; clocks matter: an out-of-sync device clock fails here);
4. the signature verifies against the approver's public key (`bad_signature`);
5. `name`/`roles` overrides are valid (`bad_request`); the vault key fields (9.3);
6. in one transaction: the nonce was never used (`pairing_replay`; nonces are unique across all devices) and is recorded, the device
   does not exist (`device_exists`, or `device_revoked` for a revoked identity), the device limit `limits.max_devices` (default 16)
   is not exceeded (`too_many_devices`). A failed attempt consumes nothing.

Result: `{"device": <device record>}` (`added_by` = approver, `bootstrap` false, `name` = override or payload name, `roles` default `[]`).
The bridge pushes `device_added` to all subscribed Links (also the approver's). The new device then connects, identifies and works;
it learns it was approved by trying `/hello` (until then `unauthorized`).
UX note: the new device SHOULD retry `/hello` every few seconds for a minute after showing its QR.

### 5.3 Other device paths
| path | request | result |
|---|---|---|
| `/devices/list` | `{"include_revoked": bool?}` (default true) | `{"devices": [record+online], "key_epoch": int}` |
| `/devices/rename` | `{"device_id": hash32?, "name": str}` (default: caller) | `{"device": record}` |
| `/devices/set_role` | `{"device_id": hash32, "role": "field", "enabled": bool}` | `{"device": record}` |
| `/devices/revoke` | `{"device_id": hash32, "reason": str(<=64 bytes)?, "key_epoch": int?, "wrapped_group_keys": {device_id: bin}?}` | `{"device": record, "key_epoch": int}` |

`rename`/`set_role` push `device_updated`. `revoke` push `device_revoked` (4.3). `key_epoch`/`wrapped_group_keys` of `/devices/revoke`: section 9.3.

## 6. Reading: sync, messages, cursors

All of this works on both transports unless stated. `limit` is clamped to `limits.page_max` (default 100).

### 6.1 `/hello`
Request: `{"protocol_version": 2, "client": "<name/version>"?}`. A `protocol_version` outside [min, max] fails with
`protocol_mismatch`, `details: {server_version, min_version, max_version, client_version}`. Result:
```
{"protocol_version": 2, "min_protocol_version": 2, "max_protocol_version": 2, "server": "kestrel-bridge/<ver>",
 "time": <float>, "state_id": "<hex16>", "cursor": <int>, "device": <device record>,
 "capabilities": ["lxmf","rrc","push","lxmf_transport","devices","pairing","read_state","origin_device","vault"],
 "compat": {"ok": bool, "meshchatx_version": str|null, "api_version": int|null},
 "profile": "full"|"constrained"|null,
 "vault": {"key_epoch": int, "in_use": bool, "used_bytes": int},
 "limits": {"max_text_bytes","page_max","constrained_max_text_bytes","lxmf_max_response_bytes","lxmf_ts_window",
            "pairing_window","max_devices","vault_max_blob_bytes","vault_device_quota_bytes","vault_total_quota_bytes",
            "vault_get_max_ids"}}
```
`time` lets the client estimate its clock offset (it matters for pairing and LXMF `ts`). `compat.ok = false` means the MeshChatX
version/API is not on the allowlist; every request except `/hello`, `/subscribe`, `/devices/*`, `/vault/*` then fails with
`upstream_incompatible`. `profile` is the push profile for this device (null over LXMF).

### 6.2 `/sync_chats`  (conversation changes)
Request: `{"cursor": int?, "limit": int?, "state_id": str?}`. Result:
```
{"state_id": "<hex16>", "cursor": int, "reset": bool, "more": bool,
 "lxmf": [{"peer": hash32, "name": str, "last_ts": any, "unread": bool, "failed": int, "preview": str(<=80 bytes), "last_id": int}],
 "rrc":  [{"hub": hash32, "hub_name": str, "room": str, "unread": int, "mention": bool}]}
```
**Exact cursor semantics** (the bridge keeps ONE global change counter `C`, no per-device state):
- Every observed change of a conversation (a new/changed message, `unread` flipping, failed count, a **delivery-state change of an
  outgoing message**, an RRC counter change) assigns the conversation the next value of `C`; the conversation keeps only its latest value.
  Values are unique and strictly increasing, and conversation rows are never deleted, so any old cursor stays valid forever
  (a device offline for weeks needs no special handling).
- `/sync_chats(cursor=c)` returns the conversations with value `> c`, **oldest change first**, at most `limit`, each **once** with its current
  state. `cursor` in the result is the value of the last returned conversation when `more` is true, else the current `C`.
  Store it and call again immediately while `more` is true. Passing back the returned cursor never skips and never repeats a change;
  a conversation that changes during paging simply appears again later (later value).
- `reset: true` (a full snapshot, treat as replacement): the request cursor was greater than `C`, or the supplied `state_id` differs from the bridge's.
  The client SHOULD send the `state_id` it stored with the cursor. A changed `state_id` (in any result) means the bridge's database was recreated:
  the client MUST discard all cursors for this bridge (also the per-conversation `last_id`s, vault cursor) and resync fully.
- `unread` (LXMF) is the **read state**: the inverse of "read" in MeshChatX (shared with its web UI). RRC has counts. `last_ts` is MeshChatX's value
  passed through (format may change; do not parse). `last_id`: highest message id the bridge served for this peer (informational).
- Because a delivery-state change only marks the conversation changed, a client that has non-terminal outgoing messages
  in a returned conversation SHOULD refetch the newest messages of it (`/get_messages` without cursors, `limit` 50) and update their `state`.

### 6.3 `/get_messages`
Request: `{"peer": hash32, "limit": int?, "before_id": int?, "after_id": int?}` (`before_id`/`after_id` exclusive). `id` is MeshChatX's
autoincrement message id, increasing with arrival, global across peers; **the per-conversation message cursor is simply the highest `id` the
device has stored for that peer**, kept by the device. Modes: neither = newest `limit`; `before_id` = up to `limit` older messages (page back);
`after_id` = messages with `id > after_id`, **oldest first**, at most `limit` (`has_more` true: call again with the highest `id` received). Result:
```
{"peer": hash32, "has_more": bool, "gap": bool, "messages": [ { "id": int, "hash": hash32, "incoming": bool, "state": str,
  "method": str|null, "title": str, "text": str, "ts": float, "attachments": bool,
  "origin_device": hash32|null, "cmd_id": str|null } ]}      # ascending by id
```
`gap: true` (only with `after_id`) means the bridge's page cap (10 x 1000) was hit and the oldest part of the range is missing: page back with
`before_id`. `state` is MeshChatX's: `generating, outbound, sending, sent, delivered, rejected, cancelled, failed`. Attachments are only flagged.
Device catch-up recipe: for every conversation returned by `/sync_chats`, `after_id = stored last id` until `has_more` is false (two
devices with different `after_id` get consistent results from the same history); a never-seen peer starts with no cursor and pages back as needed.

### 6.4 Origin device
Every message sent through the bridge (`/send_lxmf`) is recorded permanently with the sending device and its `cmd_id`. In `/get_messages`
and in push events, an outgoing message carries `origin_device` = that device's id and `cmd_id`. `origin_device` is **null** for incoming
messages and for outgoing messages not sent through the bridge, i.e. typed in the MeshChatX web UI: the client labels these "MeshChatX".
The client resolves a device id to a name via `/devices/list` (also for revoked devices). Example label: "A - from iPhone - direct - delivered".
A client can reconcile its own outbox after a lost ack: find the message with its `cmd_id`.

### 6.5 Read state: `/mark_read`
Request: `{"peer": hash32}` (LXMF only; RRC read state is not part of v2). The bridge marks the conversation read in MeshChatX (shared with its
web UI), then refreshes its index: the conversation gets a new cursor value (so `/sync_chats` shows `unread: false` to every device) and **every
subscribed Link** (the caller included) receives `read_state` (7.2) with `by_device` = the caller. Result: `{"peer", "cursor"}`. Idempotent
(no push when nothing changed). Rate limit: `limits.mark_read_rate_per_minute` (default 60 per device). A read in the MeshChatX web UI is noticed by the
bridge's periodic conversation refresh (about every 30 s while a device is subscribed) and pushed the same way with `by_device: null`.
Devices SHOULD call `/mark_read` when the user opens a conversation with unread messages.

### 6.6 RRC
`/list_rooms` and `/get_room_messages` are unchanged from v1:
`/list_rooms {}` -> `{"hubs": [{"hub","name","connected","status","rooms":[{"room","unread","mention"}]}]}`;
`/get_room_messages {"hub","room"(<=64),"limit"?,"before_seq"?,"after_seq"?}` -> `{"hub","room","has_more","gap","messages":[{"seq","kind","nick","text","ts"(ms),"mention","src"}]}`
ascending by `seq` (per-hub monotonic cursor; `after_seq` is served from the latest 1000 messages, `gap: true` = page back with `before_seq`).
The bridge undoes MeshChatX's "active room" side effect of reading history.

## 7. Sending, idempotency, push

### 7.1 Sending (mutating)
`/send_lxmf`: `{"cmd_id", "to": hash32, "text", "delivery_method": "direct"|"opportunistic"|"propagated"|null}` (`text` <= `limits.max_text_bytes`, default 4096).
Sent **as A**, visible in MeshChatX. Ack result: `{"lxmf_hash", "state", "method", "to", "ts"}` (`lxmf_hash` = `hash` in messages and push). Further state changes
come as `lxmf.state` push events with the same `cmd_id`. The message is attributed to the calling device (6.4).
`/send_rrc`: `{"cmd_id", "hub", "room", "text"}`; text starting with `/` after optional whitespace is rejected (`rrc_command_rejected`: MeshChatX would run it
as a hub command as A). Result `{"sent": true, "hub","room","ts"}`.

Idempotency: every mutating request MUST carry `cmd_id`. The bridge journals `(device_id, cmd_id)` for `limits.journal_ttl` (default 7 days) and executes a
`cmd_id` at most once. A repeat gets `replay`, with `error.details.cached` = the first response when known (a client that lost an ack resends and treats
`replay` with `cached.ok == true` as success). Failures before anything was executed upstream (`upstream_unavailable`, `upstream_auth`, `rate_limited`)
release the `cmd_id`; other failures (e.g. `send_failed`) are final: use a new `cmd_id`. Malformed requests do not consume it. Rate limit
`limits.send_rate_per_minute` (default 30 per device). `cmd_id`s are per device: two devices cannot collide.
LXMF transport adds, in this order (a failure at any step drops the command): 1. `signature_validated` is exactly true; 2. the sender's full public key
belongs to a trusted device (else no reply); 3. valid payload (`v == 2`, known non-Link-only `path`, valid `cmd_id`); 4. `abs(now - ts) <= limits.lxmf_ts_window`
(default 86400; silent drop); 5. `cmd_id` unused (every LXMF command consumes its id; at most 5 `replay` replies per device and hour).

### 7.2 Subscribe and events
`/subscribe` (Link only): `{"topics": ["lxmf","rrc","vault"]?, "profile": "full"|"constrained"?}` (default all three topics). `profile` is a hint that can only make the bridge
**more** restrictive (7.4). Result `{"topics", "profile", "mdu", "cursor"}`. A new `/subscribe` on the same link replaces the previous one; it ends with the link.

| `event` | topic | `data` |
|---|---|---|
| `lxmf.message` | lxmf | `{peer, hash, incoming, state, method, title, text, ts, attachments, name?, origin_device, cmd_id, cursor}` (`name` for incoming; `origin_device`/`cmd_id` for outgoing, null otherwise) |
| `lxmf.state` | lxmf | `{hash, state, progress?, method?, cmd_id?}` |
| `lxmf.deleted` | lxmf | `{hash}` |
| `read_state` | lxmf | `{peer, unread: false, cursor, by_device: hash32\|null}` |
| `rrc.message` | rrc | `{hub, room, seq, kind, nick, text, ts, mention, src}` |
| `rrc.change` | rrc | `{hub}` refetch `/list_rooms` |
| `vault.blob` | vault | `{blob_id, device_id, seq, key_epoch, size, vcursor}` (not sent to the uploader) |
| `device_added` | always | `{device: record, approved_by: hash32}` |
| `device_updated` | always | `{device: record}` |
| `device_revoked` | always | `{device_id, revoked_at, key_epoch}` |
| `resync` | always | `{cursor}` the bridge lost MeshChatX events: call `/sync_chats` |

Outgoing messages sent from MeshChatX's UI appear as `lxmf.message` with `incoming: false`, `origin_device: null`.

### 7.3 Fan-out
- Every event goes to **every subscribed, identified Link of every non-revoked device** whose topics match (a device with two Links receives it on both: dedupe by `id`).
  A revoked device's Links are closed and its subscriptions dropped before `device_revoked` is sent.
- The **LXMF fallback** (constrained form, `kestrel.push`) of `lxmf.message` (incoming) and `rrc.message` mentions is sent only to devices that
  (a) have the `field` role, (b) have no live Link at all, and (c) are within `push.offline_push_max_per_hour` (default 30 per device and hour). Other devices
  catch up with `/sync_chats` when they connect. Delivery of the fallback is LXMF's (opportunistic, optionally via the propagation node); there is no
  acknowledgement protocol: the fallback is a hint and the truth is the sync. The fallback copy carries the same event `id` as the Link copy.

### 7.4 Transport-aware profile (LoRa)
The bridge assigns each subscribed Link a profile, the most restrictive of: the path (standalone mode: the Link's RTT < `push.full_max_rtt` (1.5 s) and MTU >=
`push.full_min_link_mtu` (1000); shared mode: the interface class of the next hop; `push.profile` overrides; `push.unknown_profile` when unknown) and the
client's `/subscribe` hint (a device that knows it is on LoRa/BLE SHOULD send `constrained`). `full`: all events. `constrained`: only
- `lxmf.message` with `incoming: true`, reduced to `{peer, hash, incoming, ts, text, truncated, name?}` (text cut to `limits.constrained_max_text_bytes`, 160, on a character boundary);
- `rrc.message` with `mention: true` reduced to `{hub, room, seq, ts, nick, mention, text, truncated}`;
- `lxmf.state` only for messages sent through the bridge, terminal states, as `{hash, state, cmd_id}`;
- `resync` and `device_revoked`.
Everything else (`read_state`, `device_added`, `device_updated`, `vault.blob`, ...) is dropped; the next `/sync_chats`/`/devices/list` on a fast link catches up.

## 8. MeshChatX compatibility (informative)
The bridge checks `GET /api/v1/status` (`version`, allowlist default prefix `4.12.`) and `GET /api/v1/app/info` (`api_version`) at start and every 5 minutes, and verifies
required keys in MeshChatX responses (`upstream_incompatible` otherwise). `protocol_version` is independent of MeshChatX versions.

## 9. Vault (Phase 4b) and group-key epochs

Goal: devices sync their **Standalone** (`B-x`) history end-to-end encrypted through the bridge. The bridge stores **opaque ciphertext** and cannot read it; it never holds
a group key. All `/vault/*` paths need an identified Link.

### 9.1 Storage and endpoints
Append-only: blobs are never modified or deleted by the protocol. Limits (config `[limits]`): `vault_max_blob_bytes` 131072 per blob, `vault_device_quota_bytes` 64 MiB
per device, `vault_total_quota_bytes` 512 MiB total, `vault_put_rate_per_minute` 120 per device, `vault_get_max_ids` 32. Data of a revoked device stays.

- `/vault/put`: `{"blob_id": hash32, "device_id": hash32, "seq": int>=1, "key_epoch": int, "ciphertext": bin}`. `blob_id` is chosen by the client (random, 16 bytes hex),
  `device_id` MUST be the caller (`forbidden`). `seq` MUST be the device's last stored `seq` + 1 (`seq_conflict`, `details.last_seq`): readers can detect missing blobs per device.
  `key_epoch` MUST equal the current epoch (`key_epoch_stale`, `details.key_epoch`). Size/quota: `blob_too_large`, `quota_exceeded` (`details: scope device|total, used, quota`).
  Idempotent: repeating the same `blob_id` with the same `seq` and content returns the stored metadata with `duplicate: true`; same `blob_id` with different content/seq = `blob_conflict`.
  Result: `{vcursor, blob_id, device_id, seq, key_epoch, size, sha256, ts, duplicate}`; others get `vault.blob`.
- `/vault/list`: `{"cursor": int?, "limit": int?, "device_id": hash32?}` -> `{"blobs": [meta], "cursor": int, "more": bool, "key_epoch": int}`; meta = the put result without `duplicate`.
  Ordered by `vcursor` (upload order, unique, never reused); `cursor` is the last returned `vcursor` (unchanged if none): pass it back for the next call. No gaps, no repeats, valid forever.
  A device keeps ONE vault cursor per bridge (reset together with the `state_id`, 6.2). A reader tracks `seq` continuity per `device_id` (a missing `seq` = blob not uploaded yet).
- `/vault/get`: `{"blob_ids": [hash32, 1..vault_get_max_ids]}` -> `{"blobs": [meta + "ciphertext": bin], "missing": [ids], "truncated": [ids]}`; `truncated` ids did not fit
  the response size limit: ask again with fewer ids.

### 9.2 Group key and epochs
- One **group key** is shared by all devices of the user; `key_epoch` is an integer starting at **1**. The bridge only stores `key_epoch` and, per device, its **wrapped** group key.
- The vault is **in use** once group keys were distributed (`/vault/set_keys`, 9.3); from then on the wrapped keys of all devices are for the current epoch.
- **Revocation bumps `key_epoch` by one** (also when the vault is not in use). When it is in use, the new epoch needs a **new random group key** generated by the revoking device
  and delivered, in the same `/devices/revoke` request, wrapped for every remaining device (9.3). Uploads with an old epoch are refused (`key_epoch_stale`), so the revoked device,
  which knows the old key, can neither upload nor read new blobs. Honest limits: a revoked device keeps what it already downloaded and the old epochs' keys.

### 9.3 Key distribution
- `/vault/key` (caller's own): `{}` -> `{"key_epoch": int, "in_use": bool, "wrapped_epoch": int|null, "wrapped_group_key": bin|null}`.
- `/vault/set_keys` (activation, only while not in use): `{"key_epoch": <current>, "wrapped_group_keys": {device_id: bin, ...}}` MUST cover **exactly** all trusted devices (the caller included)
  (`bad_request` with `details.missing/unexpected`; `keys_already_set` when in use). Result `{"key_epoch"}`.
- `/devices/approve` while the vault is in use: `wrapped_group_key: bin` and `key_epoch` (current) are **required** (the approving device wraps its key chain to the new device's identity);
  while it is not in use they MUST be omitted. The bridge stores the blob for the new device; the new device fetches it with `/vault/key`.
- `/devices/revoke` while in use: `key_epoch` (= current + 1) and `wrapped_group_keys` (exactly the remaining trusted devices) are **required**; otherwise they MUST be omitted. Atomic: nothing changes if any check fails.
  Concurrent revocations: the second fails with `key_epoch_stale`; refetch `/devices/list` and retry.

### 9.4 Client-side crypto envelope (normative for clients; the bridge cannot check it)
- **Group key chain**: msgpack `{"v": 1, "keys": {"<epoch>": bin(32), ...}}` containing the keys of all epochs the sender knows. The first device generates `GK1` (32 random bytes).
  Rotation: `GK(n+1)` is fresh random (NOT derived from the old key). The chain given to a new device contains all epochs (it must read old blobs).
- **Wrapping** (`wrapped_group_key`, values of `wrapped_group_keys`): `RNS.Identity.encrypt` of the packed chain to the target device's identity
  (ephemeral X25519 + HKDF + Token; `Identity.decrypt` on the target). Not signed: only a trusted device can call the endpoint.
- **Per-epoch key**: `K = HKDF-SHA256(length=64, ikm=GK_epoch, salt=b"kestrel-vault-v1", info=b"epoch:<n>")` (RNS: `RNS.Cryptography.hkdf(length=64, derive_from=GK, salt=..., context=b"epoch:%d" % n)`).
- **Blob**: `ciphertext = RNS.Cryptography.Token(K).encrypt(plaintext)` (AES-256-CBC + HMAC-SHA256; 16-byte IV, 32-byte tag, as in RNS). `plaintext` = msgpack
  `{"v": 1, "blob_id", "device_id", "seq", "key_epoch", "kind": str, "ts": float, "data": {...}}`. Token has no associated data, so the reader MUST check that `blob_id`, `device_id`,
  `seq` and `key_epoch` inside the plaintext equal the outer metadata, else discard the blob. `kind` and `data` are defined by the app (Phase 4b), e.g. `kind: "messages"`.

## 10. Rate limits (per device, one-minute sliding window)
| bucket | config key | default | paths |
|---|---|---|---|
| send | `send_rate_per_minute` | 30 | `/send_lxmf`, `/send_rrc` |
| device admin | `device_admin_rate_per_minute` | 20 | `/devices/approve|rename|set_role|revoke` |
| mark read | `mark_read_rate_per_minute` | 60 | `/mark_read` |
| vault put | `vault_put_rate_per_minute` | 120 | `/vault/put` |

Exceeding one gives `rate_limited` with `details.retry_after` (seconds). Other limits: `limits.max_devices` 16, `limits.pairing_window` 600 s, `push.offline_push_max_per_hour` 30.

## 11. Error codes

| code | meaning | cmd_id released |
|---|---|---|
| `bad_request` | malformed request / field validation (`details` may list `missing`/`unexpected`) | yes (not consumed) |
| `unauthorized` | link not identified with a trusted device key / unknown device | - |
| `device_revoked` | the device (or the pairing identity) was revoked | - |
| `unknown_path` | path not defined | - |
| `unsupported_transport` | path needs a Link (`/subscribe`, `/devices/*`, `/vault/*`) | - |
| `protocol_mismatch` | version outside range; `details: server_version, min_version, max_version, client_version` | - |
| `request_too_large` / `response_too_large` | over the limit | yes / - |
| `rate_limited` | `details.retry_after` | yes |
| `replay` | `cmd_id` already used; `details.cached` | no |
| `ts_out_of_window` | LXMF `ts` outside the window (never sent) | - |
| `rrc_command_rejected` | RRC text starts with `/` | yes |
| `upstream_unavailable` / `upstream_auth` / `upstream_incompatible` / `upstream_error` | MeshChatX problems | yes / yes / - / - |
| `send_failed` | MeshChatX could not send (final) | no |
| `device_not_found` | unknown `device_id` | - |
| `device_exists` | device already paired | - |
| `last_trusted_device` | the last trusted device cannot be revoked | - |
| `too_many_devices` | `limits.max_devices` reached | - |
| `pairing_invalid` | QR payload malformed | - |
| `pairing_expired` | `ts` outside `pairing_window`; `details.server_time` | - |
| `pairing_replay` | pairing nonce already used | - |
| `bad_signature` | approval signature invalid | - |
| `forbidden` | e.g. `/vault/put` with another device's id | - |
| `key_epoch_stale` | wrong `key_epoch`; `details.key_epoch` = current | - |
| `keys_already_set` | `/vault/set_keys` when the vault is in use | - |
| `blob_too_large` | over `vault_max_blob_bytes` | - |
| `blob_conflict` | `blob_id` exists with different content | - |
| `seq_conflict` | `seq` is not last + 1; `details.last_seq` | - |
| `quota_exceeded` | `details: scope, used, quota` | - |
| `internal` | bridge bug | - |

## 12. State database (informative)
The bridge keeps its state in sqlite with a schema version (`meta.schema_version`, currently 2). Start-up migrates older databases (v1 -> v2: new tables, `journal`/`pending` keyed by
device_id instead of public key, new `state_id`) in one transaction after saving a copy `<db>.v1.bak`; a database from a newer bridge is refused. Cursors of v1 clients stay valid across
the migration; `state_id` is created at the migration.
