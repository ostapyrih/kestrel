# Kestrel bridge protocol

`protocol_version`: **1**

Any wire-visible change must bump `protocol_version` and update this file. A client can be
written from this document alone; where it says MUST / MUST NOT it is normative.

Parties: **B** = phone identity, **S** = sidecar identity (`kestrel-bridge`), **A** = MeshChatX
identity (controlled by S through the MeshChatX HTTP/WebSocket API). See [PLAN.md](PLAN.md) section 3.
Traffic between B and S never reaches A's inbox.

## 1. Conventions

- All payloads are **msgpack** maps with **string keys**. Hashes are **lowercase hex strings**
  (no binary), timestamps are floats (Unix seconds, UTC), counters are integers.
  Unknown keys in requests and responses MUST be ignored (forward compatibility inside one
  `protocol_version`).
- "hash32" below means a 32-character hex string (16-byte RNS destination hash).
- B is configured out of band with S's **destination hash** (aspect `kestrel`, `bridge`) and S's
  **public key** (64 bytes, hex). `kestrel-bridge --print-address` prints both. S's identity is
  a service identity and is NOT the address friends use (that is A).
- S holds a **whitelist of full public keys of B** (128 hex chars). B's public key is the
  `get_public_key()` of its RNS identity (32 bytes X25519 + 32 bytes Ed25519).

## 2. Online transport: RNS Link

### 2.1 Connection
1. B builds `RNS.Destination(S_identity, OUT, SINGLE, "kestrel", "bridge")` from S's public key,
   resolves a path (S announces this destination every `rns.announce_interval` seconds, default
   1800; B may also send a path request) and opens an `RNS.Link`.
2. B MUST call `link.identify(B_identity)` right after the link is established. The bridge
   compares the **full public key** of the identified identity with its whitelist.
   - Not whitelisted: the link is torn down immediately.
   - Not identified within `limits.identify_timeout` (default 30 s): the link is torn down.
   - Before `identify()` every request is answered with error `unauthorized`.
3. B sends `/hello`, checks the result (section 4.1), then `/subscribe` if it wants push.

### 2.2 Requests
Requests use the RNS request/response mechanism (`link.request(path, data)`). `path` is one of
the strings in section 4; `data` is the request map (RNS itself msgpack-encodes it, nothing else
is wrapped around it). The response is a map, one of

```
{"ok": true,  "result": { ... }}
{"ok": false, "error": {"code": "<code>", "message": "<text>", "details": { ... }?}}
```

`error.code` is stable (section 9); `message` is human-readable English, not for parsing.
Large responses are carried by RNS as a Resource (compressed automatically); the bridge limits
a response to `limits.max_response_bytes` (default 262144), beyond that it answers
`response_too_large` (use a smaller `limit`).

### 2.3 Push
Push events travel over the same Link, bridge to phone, after `/subscribe`. Each event is a
msgpack map:

```
{"t": "push", "seq": <int>, "ts": <float>, "event": "<name>", "data": { ... }}
```

- Delivered as an RNS **packet** on the link when it fits the link MDU, otherwise as an RNS
  **Resource**. B MUST handle both: `link.set_packet_callback(...)` and
  `link.set_resource_strategy(ACCEPT_ALL)` with `link.set_resource_concluded_callback(...)`.
- `seq` is a per-process counter that increases by one for every event the bridge generates
  (including events a given phone does not receive because of filtering). Push is
  **best effort**: gaps in `seq`, a link reset, or a `resync` event mean "call `/sync_chats`".
  After every reconnect B MUST resync.
- Event names (section 6).

## 3. Offline / LoRa transport: LXMF fallback

Used when no Link is possible. S runs its own LXMF router on the same identity; its
`lxmf.delivery` destination hash is printed by `--print-address`. Commands are LXMF messages
B -> S, responses and push are LXMF messages S -> B.

- LXMF `content` and `title` are empty. The payload is carried in the LXMF custom fields
  (constants of the `LXMF` package, `LXMF/LXMF.py`):
  - `FIELD_CUSTOM_TYPE` = `0xFB`: bytes, one of `b"kestrel.cmd"`, `b"kestrel.resp"`, `b"kestrel.push"`;
  - `FIELD_CUSTOM_DATA` = `0xFC`: bytes, the msgpack payload below.
- Command (B -> S), `FIELD_CUSTOM_TYPE = b"kestrel.cmd"`:

  ```
  {"v": 1, "cmd_id": "<id>", "ts": <float>, "path": "/send_lxmf", "args": { ...request map... }}
  ```
  `cmd_id`: 8-64 characters `[A-Za-z0-9_-]`, unique per command (a UUID without dashes works).
  `ts`: B's current time. `args` is exactly the request map of the same path on the Link
  transport (section 4); `cmd_id` inside `args` is ignored, the outer one is used.
- Response (S -> B), `FIELD_CUSTOM_TYPE = b"kestrel.resp"`:

  ```
  {"v": 1, "cmd_id": "<id>", "ok": true, "result": {...}}      # or "ok": false, "error": {...}
  ```
- Push (S -> B), `FIELD_CUSTOM_TYPE = b"kestrel.push"`: the same push envelope as in 2.3
  (`{"t":"push","seq",...}`).
- S replies with LXMF `OPPORTUNISTIC` delivery (automatically upgraded to a link when too large)
  and, if `push.propagation_node` is configured, retries through that propagation node when the
  direct delivery fails.
- `/subscribe` is not available over LXMF (`unsupported_transport`). Responses are limited to
  `limits.lxmf_max_response_bytes` (default 8192; `response_too_large` otherwise), so keep
  `limit` small on slow links.
- B SHOULD address S's `lxmf.delivery` destination using the pre-shared public key of S.
- Offline push: if no phone Link is subscribed, S sends the "constrained" form (section 7) of
  incoming direct messages and RRC mentions as `kestrel.push`, at most
  `push.offline_push_max_per_hour` (default 30) per phone and hour.

## 4. Requests

All paths below exist on both transports unless stated. Unless said otherwise `limit` is
clamped to `limits.page_max` (default 100).

### 4.1 `/hello`
Request: `{"protocol_version": 1, "client": "<name/version>"?}`.
If `protocol_version` differs: error `protocol_mismatch` with `details: {server_version, client_version}`.
Result:
```
{"protocol_version": 1, "server": "kestrel-bridge/<ver>", "time": <float>, "cursor": <int>,
 "capabilities": ["lxmf","rrc","push","lxmf_transport"],
 "compat": {"ok": <bool>, "meshchatx_version": "<str>|null", "api_version": <int>|null},
 "profile": "full"|"constrained"|null,
 "limits": {"max_text_bytes","page_max","constrained_max_text_bytes","lxmf_max_response_bytes","lxmf_ts_window"}}
```
`compat.ok = false` means the MeshChatX version/API is not on the bridge's allowlist; every other
request then fails with `upstream_incompatible`. B should show this in the UI. `/hello` works
even then. `profile` is the push profile the bridge currently assumes for this phone (null over LXMF).

### 4.2 `/sync_chats`
Request: `{"cursor": <int>?, "limit": <int>?}` (`cursor` default 0).
Returns the conversations whose state changed after `cursor`, oldest change first.
```
{"cursor": <int>, "reset": <bool>, "more": <bool>,
 "lxmf": [{"peer": hash32, "name": str, "last_ts": <any>, "unread": bool, "failed": int,
           "preview": str(<=80 bytes), "last_id": int}],
 "rrc":  [{"hub": hash32, "hub_name": str, "room": str, "unread": int, "mention": bool}]}
```
- B stores the returned `cursor` and passes it next time. If `more` is true, call again
  immediately with the returned cursor.
- `reset: true`: the cursor was newer than the server's (server state was reset); the result is
  a full listing, B should treat it as a snapshot.
- `unread` for LXMF is a boolean (MeshChatX has no counts); RRC has counts.
- `last_ts` is MeshChatX's `latest_message_created_at` passed through unchanged (its type may
  change with MeshChatX versions; B must not rely on its format).
- `last_id`: highest message id the bridge has served for this peer (0 if none), informational.
- The cursor is global across LXMF and RRC and is bumped by the bridge each time it observes a
  change (MeshChatX conversation list diff, or a WS event).

### 4.3 `/get_messages`
Request: `{"peer": hash32, "limit": <int>?, "before_id": <int>?, "after_id": <int>?}`;
`before_id` and `after_id` are mutually exclusive. `id` is MeshChatX's stable autoincrement
message id (increasing with arrival, global across peers).
- neither: the latest `limit` messages.
- `before_id`: up to `limit` messages with `id < before_id` (the newest of them) - page backwards.
- `after_id`: messages with `id > after_id`, **oldest first**, at most `limit`; if more exist
  `has_more` is true, call again with the highest `id` received. The bridge works around the
  MeshChatX paging quirk (see section 10) so no messages are skipped.
Result:
```
{"peer": hash32, "has_more": bool, "gap": bool,
 "messages": [{"id": int, "hash": hash32, "incoming": bool, "state": str, "method": str|null,
               "title": str, "text": str, "ts": float, "attachments": bool}]}   # ascending by id
```
`gap: true` (only with `after_id`) means the bridge's page cap was hit and the **oldest** part of
the range is missing: the returned rows are the newest ones; page backwards with `before_id`.
`state` is MeshChatX's state string (`generating, outbound, sending, sent, delivered, rejected,
cancelled, failed`). Attachments are not transferred, only flagged.

### 4.4 `/list_rooms`
Request: `{}`. Result:
`{"hubs": [{"hub": hash32, "name": str, "connected": bool, "status": str, "rooms": [{"room": str, "unread": int, "mention": bool}]}]}`
(only joined rooms).

### 4.5 `/get_room_messages`
Request: `{"hub": hash32, "room": str(<=64), "limit": <int>?, "before_seq": <int>?, "after_seq": <int>?}`
(`before_seq`/`after_seq` mutually exclusive). RRC cursor = per-hub monotonic `seq`.
Result: `{"hub","room","has_more": bool,"gap": bool,"messages":[{"seq","kind","nick","text","ts"(ms),"mention","src"}]}`
ascending by `seq`. `after_seq` is answered from the latest 1000 messages; `gap: true` means
older messages newer than `after_seq` exist (page with `before_seq`). The bridge undoes the
"active room" side effect of reading history in the MeshChatX desktop UI.

### 4.6 `/send_lxmf`  (mutating)
Request: `{"cmd_id": str, "to": hash32, "text": str, "delivery_method": "direct"|"opportunistic"|"propagated"|null}`.
`text` is at most `limits.max_text_bytes` (default 4096) UTF-8 bytes. `to` is the recipient's
`lxmf.delivery` hash. The message is sent **as A** and is visible in the MeshChatX UI.
Result (the **ack**): `{"lxmf_hash": hash32, "state": str, "method": str|null, "to": hash32, "ts": float}`
- `lxmf_hash` is the LXMF message hash of A's message. It is also the `hash` in `/get_messages`
  and in push events, so B can track delivery.
- State changes follow as `lxmf.state` push events carrying the same `cmd_id` (and are visible
  with `/get_messages`).
Errors: `send_failed` (MeshChatX refused, e.g. no path; the message may exist in A's history as
`failed`), `upstream_*`.

### 4.7 `/send_rrc`  (mutating)
Request: `{"cmd_id": str, "hub": hash32, "room": str, "text": str}`.
**`text` starting with `/` (after optional leading whitespace) is rejected with
`rrc_command_rejected`**: MeshChatX would execute it as a hub command as A. Result:
`{"sent": true, "hub","room","ts"}`; MeshChatX returns no message id, the message shows up as an
`rrc.message` push / in `/get_room_messages`.

### 4.8 `/subscribe`  (Link only)
Request: `{"topics": ["lxmf","rrc"]?, "profile": "full"|"constrained"?}`.
`profile` is a hint that can only make the bridge **more** restrictive (section 7).
Result: `{"topics": [...], "profile": "full"|"constrained", "mdu": <int>, "cursor": <int>}`.
A new `/subscribe` on the same link replaces the previous subscription. It ends with the link.

## 5. Idempotency and anti-replay

- Every **mutating** request (`/send_lxmf`, `/send_rrc`) MUST carry `cmd_id`. S keeps a journal
  of `(phone key, cmd_id)` for at least `limits.journal_ttl` (default 7 days) and executes a
  `cmd_id` **at most once**.
- A repeated `cmd_id` is answered with error `replay`; if the first execution finished,
  `error.details.cached` contains the original response. A client that lost the ack
  re-sends the same command and treats `replay` with `cached.ok == true` as success.
- A command that failed *before* anything was executed upstream (`upstream_unavailable`,
  `upstream_auth`, `rate_limited`) releases its `cmd_id`: it may be retried with the same id.
  Other failures (e.g. `send_failed`) are final: use a new `cmd_id`.
- Malformed requests (`bad_request`, `rrc_command_rejected`, ...) do not consume the `cmd_id`.
- Rate limit: `limits.send_rate_per_minute` (default 30) mutating commands per phone.
- **LXMF transport** adds mandatory checks, in this order (a failure at any step drops the
  command; no other step runs):
  1. LXMF `signature_validated` MUST be exactly `true`;
  2. the full public key of the sending identity MUST be in the whitelist;
  3. the payload decodes to the command map above with a valid `cmd_id`, `v == 1`, known `path`;
  4. `abs(now - ts) <= limits.lxmf_ts_window` (default 86400 s, tolerant of propagation delay);
  5. `cmd_id` was not seen before (every LXMF command, read-only ones too, consumes its id).
  Senders that fail 1 or 2 get **no reply** (S never answers strangers). Authenticated senders
  get an error response for malformed/replayed commands, except `ts_out_of_window`, which is
  dropped silently, and at most 5 `replay` replies per phone and hour (a replayed signed message
  must not become an amplifier towards a LoRa phone).
  B SHOULD keep its clock reasonably accurate and use a fresh `cmd_id` and `ts` per command.
- On the Link transport `ts` is not required; Link-level encryption already prevents replay.

## 6. Push events

Topics: `lxmf`, `rrc`. `resync` is always delivered.

| `event` | topic | `data` |
|---|---|---|
| `lxmf.message` | lxmf | `{peer, hash, incoming: bool, state, method, title, text, ts, attachments, name?, cmd_id?, cursor}` (`name` for incoming, `cmd_id` for outgoing messages created by B's command) |
| `lxmf.state` | lxmf | `{hash, state, progress?, method?, cmd_id?}` state/progress of an outbound message; only changes are pushed |
| `lxmf.deleted` | lxmf | `{hash}` |
| `rrc.message` | rrc | `{hub, room, seq, kind, nick, text, ts, mention: bool, src}` |
| `rrc.change` | rrc | `{hub}` hub/rooms/unread changed: refetch `/list_rooms` |
| `resync` | - | `{cursor}` the bridge lost WS events (MeshChatX reconnect/restart): call `/sync_chats` |

Outgoing messages sent from the MeshChatX desktop UI appear as `lxmf.message` with
`incoming: false` (mirroring), outgoing messages sent by B's own command appear too (with `cmd_id`).

## 7. Transport-aware push (LoRa profile)

The bridge assigns each subscribed phone a **profile**, the most restrictive of:
1. **path**: how the bridge sees the transport to B. In `rns.mode = "standalone"` (no access to
   MeshChatX's path table) this is B's live Link: RTT < `push.full_max_rtt` (default 1.5 s) and link
   MTU >= `push.full_min_link_mtu` (default 1000) -> `full`, otherwise `constrained`. In shared mode it
   is the next-hop interface towards B's `lxmf.delivery` destination in the shared
   instance's path table. Interface class `TCPInterface`, `TCPClientInterface`,
   `TCPServerInterface`, `BackboneInterface`, `BackboneClientInterface` (configurable,
   `push.fast_interfaces`) -> `full`; anything else (RNode, serial, AutoInterface, ...) ->
   `constrained`; unknown path -> `push.unknown_profile` (default `constrained`).
   `push.profile = full|constrained` overrides this step in both modes. This is a bridge-side policy:
   the wire protocol is unchanged.
2. **hint**: the `profile` B sent in `/subscribe`. B knows its own transport and SHOULD send
   `constrained` when connected over LoRa/BLE-RNode. A hint can never upgrade.

`full`: all events of subscribed topics. `constrained`: only
- `lxmf.message` with `incoming: true`, reduced to `{peer, hash, incoming, ts, text, truncated, name?}`
  with `text` cut to `limits.constrained_max_text_bytes` (default 160 UTF-8 bytes, on a
  character boundary) and `truncated: true` when cut (fetch the rest with `/get_messages`);
- `rrc.message` with `mention: true`, reduced to `{hub, room, seq, ts, nick, mention, text, truncated}`;
- `lxmf.state` only for messages sent by B's commands and only terminal states
  (`delivered, rejected, cancelled, failed`), reduced to `{hash, state, cmd_id}`;
- `resync`.
Everything else is dropped and is picked up by the next `/sync_chats` on a fast link.
The same reduced form is used for offline LXMF push (section 3).

## 8. MeshChatX compatibility (informative for clients)

The bridge checks `GET /api/v1/status` (`version`) against an allowlist (default prefix
`4.12.`) and `GET /api/v1/app/info` (`app_info.api_version`) at start and every 5 minutes. It
verifies that required keys exist in MeshChatX responses and answers `upstream_incompatible`
with the missing key named otherwise. `protocol_version` is independent of MeshChatX versions.

## 9. Error codes

| code | meaning | cmd_id released |
|---|---|---|
| `bad_request` | malformed request / field validation | yes (not consumed) |
| `unauthorized` | link not identified with a whitelisted key | - |
| `unknown_path` | path not in section 4 | - |
| `protocol_mismatch` | `protocol_version` not supported | - |
| `request_too_large` | payload or `text` over the limit | yes |
| `response_too_large` | response over the limit, use a smaller `limit` | - |
| `rate_limited` | too many mutating commands, `details.retry_after` | yes |
| `replay` | `cmd_id` already used; `details.cached` = first response if known | no |
| `ts_out_of_window` | LXMF `ts` outside the window (never sent on the wire, see 5) | - |
| `rrc_command_rejected` | RRC text starts with `/` | yes |
| `unsupported_transport` | e.g. `/subscribe` over LXMF | - |
| `upstream_unavailable` | MeshChatX unreachable/starting/rate-limited/login backoff, `details.retry_after`? | yes |
| `upstream_auth` | the bridge's MeshChatX password was rejected | yes |
| `upstream_incompatible` | MeshChatX version/API not supported or response shape changed | - |
| `upstream_error` | other MeshChatX error | - |
| `send_failed` | MeshChatX could not send (final, new `cmd_id` needed) | no |
| `internal` | bridge bug | - |

## 10. Implementation notes (informative)

- MeshChatX returns conversation pages **newest first** whatever `order` says, and with
  `order=asc&after_id=X` returns the newest `count` rows above X (leaving a gap below them);
  `order=desc&after_id=X` means `id < X`. The bridge therefore pages backwards until it reaches
  `after_id` and reports `gap` if its page cap (10 pages of 1000) is hit.
- MeshChatX's WebSocket never replays missed events: after every reconnect the bridge
  rebuilds its index over HTTP, re-polls the delivery state of messages sent through it and
  emits `resync`.
- The bridge never calls `/auth/logout` (it would invalidate the session of the MeshChatX user too).
