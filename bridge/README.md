# kestrel-bridge

Sidecar that lets the Kestrel phone app (identity **B**) read and send as the MeshChatX identity
**A** without running A on the phone. It attaches to the Reticulum shared instance of the MeshChatX
container with its own identity **S**, talks to MeshChatX over its authenticated HTTP + WebSocket
API, and serves B over an RNS Link (online) or LXMF (offline / LoRa).

Protocol: [`docs/bridge-protocol.md`](../docs/bridge-protocol.md) (`protocol_version` 1).

```
phone B --(RNS Link / LXMF)--> S (this sidecar) --(HTTP + WS, 127.0.0.1)--> MeshChatX (A)
```

## Setup (summary)

1. **Reticulum config of MeshChatX** must have `share_instance = Yes` and the default
   `instance_name = default`. MeshChatX normally runs it that way already.
2. **Compose:** add the service from [`deploy/docker-compose.example.yml`](deploy/docker-compose.example.yml).
   It uses `network_mode: "service:meshchatx"`, so it reaches MeshChatX on `127.0.0.1:8000` and the
   shared instance socket without publishing any port.
3. **Config:** copy [`config.example.toml`](config.example.toml) to `kestrel/config/bridge.toml`
   and edit it. Check it (no secrets are printed):
   `docker compose run --rm kestrel-bridge python -m kestrel_bridge --check-config`.
4. **Password:** MeshChatX has a single web password and no API tokens, so the bridge needs that
   password. Put it in a file (mode 600, owner uid 10001) mounted read-only and set
   `meshchatx.password_file`. It is never logged. The bridge never calls `/auth/logout` (that would
   log the human out of MeshChatX as well); on a 401 it logs in again, with exponential backoff.
   If you change the MeshChatX password, update the file and restart the bridge.
5. **Identity S and its address:** on first start the bridge creates `storage/identity`. Print the
   address data the phone needs:
   `docker compose run --rm kestrel-bridge python -m kestrel_bridge --print-address`
   (destination hash of `kestrel.bridge`, the `lxmf.delivery` hash and the public key of S).
6. **Authorize a phone (add B's public key):** in the app, copy B's **full public key** (128 hex
   characters, not the 32-character address) and add it to `[whitelist] phone_public_keys` in
   `bridge.toml`, then `docker compose restart kestrel-bridge`. Only identities in this list can
   use the bridge, on both transports.
7. **Start:** `docker compose up -d kestrel-bridge`. Watch `docker compose logs -f kestrel-bridge`.
   INFO logs never contain message text or secrets.

## Notes

- **`rpc_key` (optional, transport-aware push).** Attaching to the shared instance and using
  destinations needs no key. Asking the shared instance which interface leads to the phone (to
  decide between the full and the LoRa push profile) uses Reticulum's RPC, which is authenticated
  with the shared instance's `rpc_key` (by default derived from MeshChatX's
  `storage/transport_identity`). Without a matching key the lookup fails and the bridge falls back to
  `push.unknown_profile` (default `constrained`: only direct messages and mentions, truncated; a
  phone hint in `/subscribe` can only downgrade, never upgrade). To enable the full profile for TCP
  phones either set the same explicit
  `rpc_key = <hex>` in MeshChatX's Reticulum config and in the sidecar's
  `.reticulum/config`, or set `push.unknown_profile = "full"` if all your phones use TCP.
  Do not commit or log this key.
- **MeshChatX recreated:** the sidecar lives in MeshChatX's network namespace. After the MeshChatX
  container is *recreated* (image update) run `docker compose up -d --force-recreate kestrel-bridge`.
  A plain `docker restart meshchatx` is fine. `restart: unless-stopped` plus the healthcheck cover
  crashes; a stale namespace after a recreate needs the recreate above.
- **Start order:** the bridge waits for MeshChatX `network_ready` and attaches with
  `require_shared_instance=True`; it never becomes the shared instance itself.
- **MeshChatX version:** checked against an allowlist (`meshchatx.allowed_versions`, default
  `4.12.*`, and `/app/info` `api_version`). On a mismatch the bridge keeps running, reports
  `compat.ok = false` in `/hello` and refuses commands with `upstream_incompatible` until a
  tested version is found (re-checked every 5 minutes).
- **Trust:** the bridge holds the full MeshChatX session power. It exposes only the commands in
  the protocol, and only to whitelisted public keys.

## Development

```
python -m venv .venv && .venv/bin/pip install -e .[dev]     # Windows: .venv\Scripts\pip
python -m unittest discover -s tests -t .                    # unit tests, no network/RNS needed at runtime
KESTREL_IT=1 python -m unittest tests.test_integration_rns  # Reticulum integration test (starts subprocesses)
```

`tests/fake_meshchatx.py` is a small fake MeshChatX (cookie + CSRF login, newest-first paging,
WebSocket) used by the unit and integration tests.
