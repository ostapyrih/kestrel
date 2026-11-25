# Kestrel bridge protocol

`protocol_version`: **0** (draft, unstable). The wire format will be finalized after the
bridge prototype (Phase 1). Any change must bump `protocol_version` and update this file.

Parties: **B** = phone identity, **S** = sidecar identity (`kestrel-bridge`), **A** = MeshChatX
identity (controlled by S through the MeshChatX HTTP/WebSocket API). See [PLAN.md](PLAN.md) section 3.

## 1. Handshake and versioning
TBD. `protocol_version` is exchanged on every handshake; incompatibility is surfaced in the UI.

## 2. Online transport: RNS Link
Link B -> destination of S, then `link.identify()` with the key of B, then request/response.
Push events travel over the open Link. Large responses use RNS Resource.

## 3. Offline / LoRa transport: LXMF fallback
The same commands as LXMF messages B -> S with msgpack custom fields; replies and push as
LXMF S -> B (propagation node fallback).

## 4. Commands
TBD: `sync_chats(since_ts)`, `get_messages(chat, before, limit)`, `list_rooms`,
`get_room_messages`, `send_lxmf`, `send_rrc`.

Every command carries `cmd_id` (UUID) and `ts`. S answers with `ack(cmd_id, result, lxmf_hash_of_A)`.

## 5. Security
- Whitelist of full public keys of B in the S config (server only).
- Link: commands accepted only after `identify()` with a whitelisted key.
- LXMF: only if `signature_validated == True` and the key matches.
- Anti-replay: `ts` window plus a journal of executed `cmd_id`.

## 6. Push
Transport-aware: over a LoRa path only personal LXMF and mentions, with a size limit; the rest
is fetched on the next TCP sync.
