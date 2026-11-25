#!/usr/bin/env python3
"""Verify Dart-generated (random) artefacts with the Python RNS/LXMF reference.

Usage: python tools/verify_dart_output.py <dart_output.json>

The JSON is written by ``packages/kestrel_rns/test/python_crosscheck_test.dart``
(tag ``python``). Every item is produced by the Dart implementation with *real*
randomness (random keys, IVs, ephemeral keys), so unlike the golden vectors this
checks that arbitrary Dart output is accepted by the reference implementation:

* Ed25519 signatures verify with ``RNS.Identity.validate``
* ``Identity.encrypt`` ciphertexts decrypt with ``RNS.Identity.decrypt``
* Tokens decrypt with ``RNS.Cryptography.Token``
* Announces pass ``RNS.Identity.validate_announce``
* LXMF messages unpack with ``LXMessage.unpack_from_bytes`` and the signature validates
* Packets unpack with ``RNS.Packet.unpack`` and hash identically
* HDLC / KISS frames survive the reference unescape logic

Exit status is non-zero if anything fails.
"""

import json
import sys

import RNS
import RNS.vendor.umsgpack as umsgpack
from LXMF import LXMessage
from RNS.Cryptography import Token
from RNS.Interfaces.TCPInterface import HDLC

RNS.loglevel = RNS.LOG_CRITICAL
RNS.Transport.register_destination = staticmethod(lambda d: None)

failures = []
checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)
        print(f"FAIL: {what}")


def load_identity(rec):
    i = RNS.Identity(create_keys=False)
    assert i.load_private_key(bytes.fromhex(rec["private_key"]))
    return i


def main(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    ids = {r["name"]: load_identity(r) for r in data["identities"]}
    for r in data["identities"]:
        i = ids[r["name"]]
        check(i.get_public_key().hex() == r["public_key"], f"public key of {r['name']}")
        check(i.hash.hex() == r["hash"], f"identity hash of {r['name']}")

    for s in data["signatures"]:
        pub = RNS.Identity(create_keys=False)
        pub.load_public_key(bytes.fromhex(s["public_key"]))
        check(pub.validate(bytes.fromhex(s["signature"]), bytes.fromhex(s["message"])), "dart signature verifies")

    for e in data["encrypted"]:
        i = ids[e["recipient"]]
        ratchets = [bytes.fromhex(e["ratchet_private"])] if e.get("ratchet_private") else None
        pt = i.decrypt(bytes.fromhex(e["ciphertext"]), ratchets=ratchets)
        check(pt is not None and pt.hex() == e["plaintext"], "dart Identity.encrypt decrypts in python")

    for t in data["tokens"]:
        tok = Token(bytes.fromhex(t["key"]))
        try:
            check(tok.decrypt(bytes.fromhex(t["token"])).hex() == t["plaintext"], "dart token decrypts in python")
        except Exception as ex:  # noqa: BLE001
            check(False, f"dart token decrypt raised {ex}")

    for a in data["announces"]:
        IM = sys.modules["RNS.Identity"]
        IM.Identity._reset_validation_caches()
        IM.Identity.known_destinations.clear()
        p = RNS.Packet(None, bytes.fromhex(a["raw"]))
        check(p.unpack(), "dart announce unpacks in python")
        check(RNS.Identity.validate_announce(p) is True, "dart announce validates in python")
        check(p.packet_hash.hex() == a["packet_hash"], "announce packet hash matches")
        check(p.destination_hash.hex() == a["destination_hash"], "announce destination hash matches")

    IM = sys.modules["RNS.Identity"]
    IM.Identity.known_destinations.clear()
    for r in data["identities"]:
        d = RNS.Destination.hash(ids[r["name"]], "lxmf", "delivery")
        check(d.hex() == r["lxmf_delivery_hash"], "dart lxmf.delivery hash matches")
        RNS.Identity.remember(None, d, ids[r["name"]].get_public_key())

    for m in data["lxmf"]:
        u = LXMessage.unpack_from_bytes(bytes.fromhex(m["packed"]))
        check(u.signature_validated is True, f"dart LXMF signature validates ({m['name']})")
        check(u.hash.hex() == m["hash"], f"dart LXMF hash matches ({m['name']})")
        check(u.content_as_string() == m["content"], f"LXMF content ({m['name']})")
        check(u.title_as_string() == m["title"], f"LXMF title ({m['name']})")
        check(u.timestamp == m["timestamp"], f"LXMF timestamp ({m['name']})")
        check(u.stamp == (bytes.fromhex(m["stamp"]) if m.get("stamp") else None), f"LXMF stamp ({m['name']})")
        if not m.get("stamp"):
            # Re-pack with the reference msgpack: payload must round-trip byte-identically.
            repacked = umsgpack.packb([u.timestamp, u.title, u.content, u.fields])
            check(repacked == bytes.fromhex(m["packed"])[2 * 16 + 64:], f"LXMF payload re-packs identically ({m['name']})")

    for p in data["packets"]:
        q = RNS.Packet(None, bytes.fromhex(p["raw"]))
        check(q.unpack(), "dart packet unpacks in python")
        check(q.packet_hash.hex() == p["packet_hash"], "dart packet hash == python packet hash")

    for h in data["hdlc"]:
        payload = bytes.fromhex(h["payload"])
        frame = bytes.fromhex(h["frame"])
        check(frame == bytes([HDLC.FLAG]) + HDLC.escape(payload) + bytes([HDLC.FLAG]), "dart hdlc frame == python")

    print(f"{checks - len(failures)}/{checks} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
