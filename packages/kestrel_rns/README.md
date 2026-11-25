# kestrel_rns

Pure-Dart (no Flutter) Reticulum (RNS) + LXMF core for Kestrel. The goal is **byte-for-byte
compatibility with the Python reference implementation**; the installed Python `RNS` / `LXMF`
packages are the specification, and every primitive is checked against golden vectors generated
from them.

This package is the *offline, deterministic* core (Phase 2). It does no networking and has no
Transport/Link logic yet.

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
* Not implemented: GROUP destinations, Links, Transport/path tables, Resources, Channels,
  IFAC, propagation sync, stamp generation/validation, paper messages (Phase 3+).

## Tests

```
cd packages/kestrel_rns
dart pub get
dart analyze
dart test                # golden vectors, both directions
dart test -t python      # also cross-check random Dart output with Python (needs tools/.venv)
```

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
