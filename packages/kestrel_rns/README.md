# kestrel_rns

Pure-Dart (no Flutter) Reticulum (RNS) + LXMF core for Kestrel. The goal is **byte-for-byte
compatibility with the Python reference implementation**; the installed Python `RNS` / `LXMF`
packages are the specification, and every primitive is checked against golden vectors generated
from them.

Phase 2 is the *offline, deterministic* core (packets, crypto, announces, framing, msgpack, LXMF).
Phase 3a adds the **network layer of a client/endpoint node** (it never forwards other nodes'
traffic): interfaces, a minimal Transport, destinations, links, resources, announce stamps and a
`Reticulum` facade.

## Implemented

| Area | Module | Notes |
|---|---|---|
| Hashes, HKDF | `crypto/hashes.dart` | SHA-256/512, truncated hash, HMAC-SHA256, RNS-flavoured HKDF |
| Curves | `crypto/curves.dart` | X25519 + Ed25519 over `package:cryptography` (pure Dart) |
| Token | `crypto/token.dart` | AES-256-CBC (and AES-128) + HMAC-SHA256, incl. RNS's lax PKCS7 unpad |
| Identity | `identity.dart` | key load/generate, sign/validate, `encrypt`/`decrypt` incl. ratchets |
| Destination | `destination.dart` | `expand_name`, `name_hash`, destination hash (SINGLE/PLAIN) |
| Packet | `packet.dart` | HEADER_1/HEADER_2, all contexts, flags, hops, packet hash, MTU checks |
| Announce | `announce.dart` | build + validate (with/without ratchet, app_data, path response) |
| HDLC | `framing/hdlc.dart` | escape/frame + streaming decoder mirroring `TCPInterface` read loop |
| KISS | `framing/kiss.dart` | escape/frame + streaming decoder mirroring `RNodeInterface` read loop |
| msgpack | `msgpack/msgpack.dart` | own codec; bin vs str and int vs float64 strictly preserved (umsgpack semantics) |
| LXMF | `lxmf/lx_message.dart` | pack/sign/unpack/validate, ticket stamp, opportunistic + propagated forms, method/representation selection |

### Network layer (Phase 3a)

| Area | Module | Notes |
|---|---|---|
| Interfaces | `interfaces/interface.dart`, `interfaces/tcp_client.dart` | `RnsInterface` abstraction (a later `RNodeBleInterface`/KISS plugs in); `TcpClientInterface`: HDLC over TCP, reconnect with backoff, state stream, `HW_MTU` 262144 / 10 Mbit/s like RNS |
| Transport | `transport/transport.dart` | inbound dispatch + packet-hash dedup (`Transport.packet_filter`), announce validation, known-destination store, path table (hops, via transport id, interface, random-blob/timebase update rules), path requests (send + answer for own destinations, optional PoW stamp), HEADER_2 routing via next hop when `hops > 1`, SINGLE/PLAIN proofs (implicit by default) and receipts with timeouts. **No forwarding** |
| Destinations | `destination.dart` | IN/OUT SINGLE and PLAIN, packet callbacks, proof strategy, `registerRequestHandler`, ratchets (rotate, persist, enforce) |
| Link | `link/link.dart` | initiator and responder: LINKREQUEST/LRPROOF (signature check), ECDH + HKDF keys, MTU/mode signalling (3 bytes), encrypted link packets, keepalive/stale/teardown, RTT, `identify()` + remote-identified callback, request/response (`[ts, path_hash, data]`, resource-sized requests/responses), packet proofs |
| Resource | `link/resource.dart` | sender and receiver: advertisement, hashmap + HMU, windowed part requests, retries, proof, bz2 (`package:archive`), progress callbacks, `maxResourceSize` |
| Stamps | `stamps.dart` | RNS 1.6.1 fixed-point PoW stamps (cost/target/value), generation (`Isolate.run`), announce ext payload (`0xC1`, flags, 14-byte stamp, link cost), path-request stamps, persisted per destination |
| Storage | `storage.dart` | `KestrelStorage` (JSON maps by key), `MemoryStorage`, `JsonFileStorage`; known destinations, stamps and own ratchets persist through it |
| Facade | `reticulum.dart` | `Reticulum.start(ReticulumConfig)`; streams `announces` / `interfaceEvents`; no global singletons (several instances per process) |

```dart
final rns = await Reticulum.start(ReticulumConfig(
  interfaces: [TcpClientInterface(host: 'rns.ostapyrih.com', port: 4242)],
  storage: JsonFileStorage(Directory(dataDir)),
));
final me = await Identity.generate();
final dest = await rns.createDestination(me, 'lxmf', ['delivery']);
await rns.announce(dest, appData: utf8.encode('name'));   // stamp generated off the UI isolate
rns.announces.listen((a) => print('${toHex(a.destinationHash)} ${a.hops} hops'));
final peer = rns.recallDestination(hash, 'kestrel', ['bridge'])!;
final link = await rns.connect(peer);                      // requests a path if needed
await link.identify(me);
final rr = await link.request('/sync', data: {...});
await rr!.done;                                            // large answers arrive as Resources
```

Link MTU discovery follows RNS 1.6: the initiator signals the next-hop interface `HW_MTU` and the
responder clamps/confirms it (a link over `TCPInterface` therefore carries up to `HW_MTU`-sized
packets); `Packet.maxSize` carries the per-link limit.

Crypto library choice: `package:cryptography` (pure-Dart X25519/Ed25519/AES-CBC, can be swapped for
native implementations through `cryptography_flutter` without code changes) plus `package:crypto`
for synchronous SHA/HMAC. `pointycastle` was not needed.

## Compatibility matrix

| This package | RNS | LXMF | Python (vector generation) |
|---|---|---|---|
| 0.1.x | 1.6.1 | 1.3.1 | 3.12 / 3.14 (`tools/requirements.txt`, `cryptography` 50.x) |

Vectors are generated with the pinned versions in `tools/requirements.txt`; CI regenerates them and
fails on any diff, so a version bump that changes wire behaviour is caught.

## Known gaps / reference quirks (deliberately mirrored or deferred)

* **Announce stamps (RNS >= 1.6):** the reference appends an 18-byte proof-of-work "ext payload"
  to announce `app_data` by default (`Transport.STAMP_DESTINATIONS`). We **do not generate**
  stamps (cost ~2^25 hashes) and do not value-check received ones; unstamped announces are valid
  unless a network sets `enforce_stamps`. `Announce.appData` is the raw trailer including any ext
  payload; `Announce.stampTrailer` detects it. Vectors are generated with stamping disabled.
* **Token padding:** RNS `PKCS7.unpad` only checks the last byte (<= 16) and does not verify the
  padding content; we mirror this (see `lax_padding` vectors).
* **msgpack:** ext types, `uint64 >= 2^63` (decoded as `BigInt`), list-typed map keys and
  `bin` map keys (compared by identity in Dart) are edge cases; trailing bytes after the first
  object are ignored, like `umsgpack.unpackb`.
* HDLC/KISS decoders mirror the reference's quirks (shared flags, `<= 19` byte frames dropped,
  escape flag not reset on FEND for KISS).
* **Announce stamps** are now generated (default **on**, value 25.0, cached per destination) and
  validated (minimum value `requiredAnnounceStampCost`, default 23.5; invalid/missing stamps are
  accepted unless `enforceAnnounceStamps`). Link-request stamps (`LR_STAMPS`) are neither sent nor
  checked (Python only enforces them if configured; default off). Generating a value-25 stamp takes
  roughly 2^25 SHA-256 evaluations (tens of seconds); it runs on a background isolate and is
  persisted, so it happens once per destination.
* Mirrored reference behaviour: any valid announce refreshes the stored app_data/ratchet even when it
  does not change the path table (`Identity.remember`).
* Not implemented (deferred): multi-segment (split, > 1 MiB) resources, sending resource metadata /
  file responses, Channel/Buffer, GROUP destinations, IFAC and KISS-framed TCP, tunnels, transport
  mode (forwarding, announce rebroadcast, path-table persistence), link-request stamps, discovery,
  propagation sync, paper messages, `RNodeBleInterface` (the `RnsInterface` seam exists).

## Tests

```
cd packages/kestrel_rns
dart pub get
dart analyze
dart test                # golden vectors, both directions
dart test -x integration # unit + golden vectors (no Python needed)
dart test -t python      # also cross-check random Dart output with Python (needs tools/.venv)
dart test -t integration # Dart network layer against a live Python RNS peer (needs tools/.venv)
```

`dart test` runs everything; integration tests start `tools/it/rns_peer.py` (RNS 1.6.1 with a
`TCPServerInterface` on 127.0.0.1, optionally `enable_transport = Yes`) and skip themselves when no
Python reference is found. Covered: announce receive/send incl. stamps, path requests, SINGLE
proofs, links in both directions (identify, request/response, 50 KB and 200 KB resource responses,
resources both ways, 500-byte-MTU multi-part transfers with hashmap updates, keepalive, teardown),
reconnect after a server restart, and Dart-to-Dart over a Python transport node (HEADER_2 routing).

Each `test/vectors/*.json` is checked in both directions where applicable: Dart produces identical
bytes from the same fixed keys / IVs / ephemeral keys, and Dart decrypts / verifies what Python
produced. `test/python_crosscheck_test.dart` (tag `python`, skipped when no venv is found) writes
random Dart output (signatures, ciphertexts, tokens, announces, LXMF messages, packets, HDLC frames)
and runs `tools/verify_dart_output.py`, which verifies it with the reference RNS/LXMF.

## Regenerating vectors

```
python -m venv tools/.venv
tools/.venv/bin/pip install -r tools/requirements.txt     # Windows: tools\.venv\Scripts\pip
tools/.venv/bin/python tools/gen_vectors.py
```

`gen_vectors.py` monkey-patches randomness (ephemeral X25519 keys, AES IVs, announce random hash,
time) so output is reproducible. All keys are obviously test-only (derived from the string
`kestrel-test-only/...`). Set `KESTREL_PYTHON` to use a specific interpreter for the `python` test.
