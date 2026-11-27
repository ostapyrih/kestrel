#!/usr/bin/env python3
"""Deterministic golden-vector generator for the Kestrel pure-Dart RNS/LXMF core.

The *installed* Python ``RNS`` and ``LXMF`` packages are the specification.
This script drives them with fixed private keys and monkey-patched randomness
(ephemeral X25519 keys, AES IVs, announce random hashes, wall-clock time) so the
output is byte-for-byte reproducible, then writes hex-encoded JSON vectors to
``packages/kestrel_rns/test/vectors/``.

Run (from the repo root, inside ``tools/.venv``)::

    python tools/gen_vectors.py

CI regenerates the vectors and fails if ``git diff`` is non-empty, so any RNS /
LXMF version bump that changes wire behaviour is caught.

All keys used here are obviously test-only (derived from the string
``kestrel-test-only/...``) and must never be used for anything real.
"""

import contextlib
import hashlib
import json
import os
import struct
import sys
import time
import types
from pathlib import Path

import RNS
import RNS.vendor.umsgpack as umsgpack
import LXMF
from LXMF import LXMessage
from RNS.Interfaces.TCPInterface import HDLC
from RNS.Interfaces.RNodeInterface import KISS

OUT_DIR = Path(__file__).resolve().parent.parent / "packages" / "kestrel_rns" / "test" / "vectors"

IM = sys.modules["RNS.Identity"]  # the module (RNS.Identity the name is the class)
TOKEN_MOD = sys.modules["RNS.Cryptography.Token"]

# --------------------------------------------------------------------------
# Neutralise anything that needs a running Reticulum instance.
# --------------------------------------------------------------------------
RNS.Transport.register_destination = staticmethod(lambda d: None)
RNS.Transport.STAMP_DESTINATIONS = False  # announces without PoW stamp (see README)
RNS.loglevel = RNS.LOG_CRITICAL


def hx(b):
    return None if b is None else bytes(b).hex()


def det(label, n):
    """Deterministic n bytes from a label (test material only)."""
    out = b""
    c = 0
    while len(out) < n:
        out += hashlib.sha256(f"kestrel-test-only/{label}/{c}".encode()).digest()
        c += 1
    return out[:n]


# --------------------------------------------------------------------------
# Determinism harness
# --------------------------------------------------------------------------
class _FixedX25519:
    """Shim for RNS.Identity.X25519PrivateKey whose generate() is fixed."""

    def __init__(self, real_cls, fixed):
        self._real = real_cls
        self._fixed = fixed

    def generate(self):
        return self._real.from_private_bytes(self._fixed)

    def from_private_bytes(self, b):
        return self._real.from_private_bytes(b)


@contextlib.contextmanager
def deterministic(ephemeral=None, iv=None, now=None, random_hash=None, ratchet_for=None):
    """Patch randomness / time / ratchet lookup for the duration of a block."""
    saved = []

    def patch(obj, name, value):
        saved.append((obj, name, getattr(obj, name)))
        setattr(obj, name, value)

    if ephemeral is not None:
        patch(IM, "X25519PrivateKey", _FixedX25519(IM.X25519PrivateKey, ephemeral))
    if iv is not None:
        patch(TOKEN_MOD, "os", types.SimpleNamespace(urandom=lambda n: iv[:n]))
    if now is not None:
        patch(time, "time", lambda: now)
    if random_hash is not None:
        patch(RNS.Identity, "get_random_hash", staticmethod(lambda: random_hash))
    patch(RNS.Identity, "get_ratchet", staticmethod(lambda h: ratchet_for))
    patch(RNS.Identity, "_remember_ratchet", staticmethod(lambda *a: None))
    try:
        yield
    finally:
        for obj, name, value in reversed(saved):
            setattr(obj, name, value)


# --------------------------------------------------------------------------
# Fixed test identities
# --------------------------------------------------------------------------
def make_identity(name):
    prv = det(f"{name}/x25519", 32) + det(f"{name}/ed25519", 32)
    i = RNS.Identity(create_keys=False)
    assert i.load_private_key(prv)
    return i


def public_only(identity):
    i = RNS.Identity(create_keys=False)
    assert i.load_public_key(identity.get_public_key())
    return i


def identity_json(name, i):
    return {
        "name": name,
        "private_key": hx(i.get_private_key()),
        "x25519_private": hx(i.prv_bytes),
        "ed25519_seed": hx(i.sig_prv_bytes),
        "x25519_public": hx(i.pub_bytes),
        "ed25519_public": hx(i.sig_pub_bytes),
        "public_key": hx(i.get_public_key()),
        "hash": hx(i.hash),
    }


IDENTITIES = {n: make_identity(n) for n in ("alice", "bob", "carol")}


def dest_out(identity, *name):
    return RNS.Destination(public_only(identity), RNS.Destination.OUT, RNS.Destination.SINGLE, *name)


def dest_in(identity, *name):
    return RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, *name)


# --------------------------------------------------------------------------
# JSON writer
# --------------------------------------------------------------------------
def write(name, obj):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / name
    with open(path, "w", newline="\n", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=False, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {path.relative_to(OUT_DIR.parent.parent.parent.parent)}")


# ==========================================================================
# identity.json
# ==========================================================================
def gen_identity():
    ids = {n: identity_json(n, i) for n, i in IDENTITIES.items()}
    alice, bob = IDENTITIES["alice"], IDENTITIES["bob"]

    sigs = []
    for msg in (b"", b"kestrel", bytes(range(256)), det("sigmsg", 1000)):
        sigs.append({"identity": "alice", "message": hx(msg), "signature": hx(alice.sign(msg))})
        assert alice.validate(alice.sign(msg), msg)
    bad = bytearray(alice.sign(b"kestrel"))
    bad[0] ^= 1
    assert not alice.validate(bytes(bad), b"kestrel")
    invalid_sigs = [
        {"identity": "alice", "message": hx(b"kestrel"), "signature": hx(bytes(bad))},
        {"identity": "alice", "message": hx(b"kestrelX"), "signature": hx(alice.sign(b"kestrel"))},
        {"identity": "bob", "message": hx(b"kestrel"), "signature": hx(alice.sign(b"kestrel"))},
    ]

    enc = []
    cases = [
        ("short", b"hello kestrel"),
        ("empty", b""),
        ("block_aligned", bytes(range(16))),
        ("long", det("encplain", 300)),
    ]
    for idx, (label, plaintext) in enumerate(cases):
        eph = det(f"eph/{idx}", 32)
        iv = det(f"iv/{idx}", 16)
        with deterministic(ephemeral=eph, iv=iv):
            ct = bob.encrypt(plaintext)
        assert bob.decrypt(ct) == plaintext
        enc.append({
            "name": label, "recipient": "bob", "plaintext": hx(plaintext),
            "ephemeral_private": hx(eph), "iv": hx(iv), "ratchet_private": None,
            "ratchet_public": None, "ciphertext": hx(ct),
        })

    # Ratchet-encrypted (Destination.encrypt picks the announced ratchet).
    ratchet_prv = det("ratchet/bob", 32)
    ratchet_pub = IM.Identity._ratchet_public_bytes(ratchet_prv)
    eph = det("eph/ratchet", 32)
    iv = det("iv/ratchet", 16)
    plaintext = b"to the ratchet key"
    with deterministic(ephemeral=eph, iv=iv):
        ct = public_only(bob).encrypt(plaintext, ratchet=ratchet_pub)
    assert bob.decrypt(ct, ratchets=[ratchet_prv]) == plaintext
    assert bob.decrypt(ct) is None  # identity key alone must NOT decrypt
    enc.append({
        "name": "ratchet", "recipient": "bob", "plaintext": hx(plaintext),
        "ephemeral_private": hx(eph), "iv": hx(iv), "ratchet_private": hx(ratchet_prv),
        "ratchet_public": hx(ratchet_pub), "ciphertext": hx(ct),
    })

    # Decrypt-only vectors (wrong key / tamper must yield None).
    ct0 = bytes.fromhex(enc[0]["ciphertext"])
    tampered = bytearray(ct0)
    tampered[-1] ^= 1
    assert bob.decrypt(bytes(tampered)) is None
    assert alice.decrypt(ct0) is None
    decrypt_fail = [
        {"name": "tampered_hmac", "recipient": "bob", "ciphertext": hx(bytes(tampered))},
        {"name": "wrong_recipient", "recipient": "alice", "ciphertext": hx(ct0)},
        {"name": "too_short", "recipient": "bob", "ciphertext": hx(b"\x00" * 32)},
    ]
    assert bob.decrypt(b"\x00" * 32) is None

    # Hashes
    hashes = []
    for data in (b"", b"abc", det("hash", 500)):
        hashes.append({
            "data": hx(data),
            "sha256": hx(RNS.Identity.full_hash(data)),
            "truncated": hx(RNS.Identity.truncated_hash(data)),
            "sha512": hx(hashlib.sha512(data).digest()),
        })

    write("identity.json", {
        "_note": "Test-only keys derived from 'kestrel-test-only/...'. Never use for real traffic.",
        "identities": list(ids.values()),
        "signatures": sigs,
        "invalid_signatures": invalid_sigs,
        "encrypt": enc,
        "decrypt_failures": decrypt_fail,
        "hashes": hashes,
        "derived_key_length": IM.Identity.DERIVED_KEY_LENGTH,
    })


# ==========================================================================
# token.json
# ==========================================================================
def gen_token():
    from RNS.Cryptography import Token, hkdf

    tokens = []
    for idx, (klen, plaintext) in enumerate([
        (64, b"AES-256-CBC + HMAC-SHA256"), (64, b""), (64, det("tok", 100)), (64, bytes(32)),
        (32, b"AES-128-CBC mode"), (32, det("tok128", 49)),
    ]):
        key = det(f"token/key/{idx}", klen)
        iv = det(f"token/iv/{idx}", 16)
        t = Token(key)
        with deterministic(iv=iv):
            tok = t.encrypt(plaintext)
        assert t.decrypt(tok) == plaintext
        tokens.append({
            "key": hx(key), "iv": hx(iv), "plaintext": hx(plaintext), "token": hx(tok),
            "mode": "AES-256-CBC" if klen == 64 else "AES-128-CBC",
        })

    # Invalid tokens
    t = Token(bytes.fromhex(tokens[0]["key"]))
    good = bytes.fromhex(tokens[0]["token"])
    bad_hmac = bytearray(good)
    bad_hmac[-1] ^= 1
    bad_ct = bytearray(good)
    bad_ct[20] ^= 1  # corrupts ciphertext; HMAC no longer matches
    invalid = []
    for name, tok in (("bad_hmac", bytes(bad_hmac)), ("bad_ciphertext", bytes(bad_ct)), ("too_short", b"\x00" * 32)):
        try:
            t.decrypt(tok)
            raise AssertionError("expected failure")
        except ValueError:
            pass
        invalid.append({"name": name, "key": tokens[0]["key"], "token": hx(tok)})

    # Valid HMAC but odd padding. RNS PKCS7.unpad() only checks the LAST byte (<=16) and strips that many
    # bytes without verifying the padding content (RNS/Cryptography/PKCS7.py:40-47). Dart must match.
    key = bytes.fromhex(tokens[0]["key"])
    sig_key, enc_key = key[:32], key[32:]
    from RNS.Cryptography import HMAC
    from RNS.Cryptography.AES import AES_256_CBC

    def forge(label, block):
        iv = det(f"token/forge/{label}", 16)
        ct = AES_256_CBC.encrypt(plaintext=block, key=enc_key, iv=iv)
        signed = iv + ct
        return signed + HMAC.new(sig_key, signed).digest()

    lax = []
    for label, block in (
        ("pad_len_17_rejected", bytes(15) + bytes([17])),
        ("pad_len_0_keeps_all", bytes(range(16, 32)) [:15] + bytes([0])),
        ("pad_content_unchecked", bytes(range(1, 14)) + bytes([9, 9, 3])),
    ):
        tok = forge(label, block)
        try:
            pt = t.decrypt(tok)
            lax.append({"name": label, "key": hx(key), "token": hx(tok), "plaintext": hx(pt)})
        except ValueError:
            invalid.append({"name": label, "key": hx(key), "token": hx(tok)})

    hk = []
    for idx, (length, derive_from, salt, ctx) in enumerate([
        (64, det("hkdf/ikm0", 32), det("hkdf/salt0", 16), None),
        (64, det("hkdf/ikm1", 32), None, None),
        (64, det("hkdf/ikm2", 32), b"", b"ctx"),
        (32, det("hkdf/ikm3", 48), det("hkdf/salt3", 32), det("hkdf/ctx3", 10)),
        (100, det("hkdf/ikm4", 32), det("hkdf/salt4", 16), None),
        (256, det("hkdf/ikm5", 32), det("hkdf/salt5", 16), None),
    ]):
        out = hkdf(length=length, derive_from=derive_from, salt=salt, context=ctx)
        hk.append({
            "length": length, "derive_from": hx(derive_from), "salt": hx(salt) if salt is not None else None,
            "context": hx(ctx) if ctx is not None else None, "output": hx(out),
        })

    write("token.json", {"tokens": tokens, "invalid_tokens": invalid, "lax_padding": lax, "hkdf": hk, "token_overhead": Token.TOKEN_OVERHEAD})


# ==========================================================================
# vault.json: client-side crypto envelope of the bridge vault (docs/bridge-protocol.md section 9.4)
# ==========================================================================
VAULT_SALT = b"kestrel-vault-v1"


def vault_chain_pack(keys):
    return umsgpack.packb({"v": 1, "keys": {str(e): k for e, k in sorted(keys.items())}})


def vault_epoch_key(gk, epoch):
    from RNS.Cryptography import hkdf
    return hkdf(length=64, derive_from=gk, salt=VAULT_SALT, context=b"epoch:%d" % epoch)


def vault_invite_key(secret):
    from RNS.Cryptography import hkdf
    return hkdf(length=64, derive_from=secret, salt=VAULT_SALT, context=b"invite")


def vault_blob_plain(blob_id, device_id, seq, epoch, kind, ts, data):
    return umsgpack.packb({"v": 1, "blob_id": blob_id, "device_id": device_id, "seq": seq, "key_epoch": epoch,
                           "kind": kind, "ts": ts, "data": data})


def gen_vault():
    from RNS.Cryptography import Token

    bob = IDENTITIES["bob"]
    gk1, gk2 = det("vault/gk1", 32), det("vault/gk2", 32)
    chain = {1: gk1, 2: gk2}
    packed = vault_chain_pack(chain)

    eph, iv = det("vault/wrap/eph", 32), det("vault/wrap/iv", 16)
    with deterministic(ephemeral=eph, iv=iv):
        wrapped_identity = public_only(bob).encrypt(packed)
    assert umsgpack.unpackb(bob.decrypt(wrapped_identity)) == {"v": 1, "keys": {"1": gk1, "2": gk2}}

    secret = det("vault/invite_secret", 32)
    inv_iv = det("vault/invite/iv", 16)
    with deterministic(iv=inv_iv):
        wrapped_invite = Token(vault_invite_key(secret)).encrypt(packed)
    assert Token(vault_invite_key(secret)).decrypt(wrapped_invite) == packed

    blob_id, device_id = det("vault/blob_id", 16).hex(), det("vault/device_id", 16).hex()
    data = {"messages": [
        {"hash": det("vault/msg0", 16).hex(), "dir": "out", "text": "Привіт vault", "ts": 1700000000.25,
         "n": -3, "ok": True, "none": None, "att": [{"name": "a.bin", "size": 12}]},
        {"hash": det("vault/msg1", 16).hex(), "dir": "in", "text": "", "ts": 1700000001.0, "n": 70000, "ok": False,
         "none": None, "att": []},
    ]}
    blobs = []
    for idx, (epoch, gk, seq, kind) in enumerate([(1, gk1, 1, "messages"), (2, gk2, 7, "messages")]):
        biv = det(f"vault/blob/iv/{idx}", 16)
        plain = vault_blob_plain(blob_id, device_id, seq, epoch, kind, 1700000002.5, data)
        with deterministic(iv=biv):
            ct = Token(vault_epoch_key(gk, epoch)).encrypt(plain)
        blobs.append({"blob_id": blob_id, "device_id": device_id, "seq": seq, "key_epoch": epoch, "kind": kind,
                      "ts": 1700000002.5, "iv": hx(biv), "plaintext": hx(plain), "data_packed": hx(umsgpack.packb(data)),
                      "ciphertext": hx(ct)})

    # a blob whose inner metadata (seq 5) differs from the outer one the bridge reports (seq 6): MUST be discarded
    biv = det("vault/blob/iv/bad", 16)
    with deterministic(iv=biv):
        mism = Token(vault_epoch_key(gk1, 1)).encrypt(vault_blob_plain(blob_id, device_id, 5, 1, "messages", 1.0, {}))

    write("vault.json", {
        "_note": "Test-only keys derived from 'kestrel-test-only/...'. Never use for real traffic.",
        "recipient": "bob",
        "group_keys": {"1": hx(gk1), "2": hx(gk2)},
        "chain_packed": hx(packed),
        "wrap_identity": {"ephemeral_private": hx(eph), "iv": hx(iv), "wrapped": hx(wrapped_identity)},
        "epoch_keys": {"1": hx(vault_epoch_key(gk1, 1)), "2": hx(vault_epoch_key(gk2, 2))},
        "invite": {"secret": hx(secret), "key": hx(vault_invite_key(secret)), "iv": hx(inv_iv),
                   "wrapped": hx(wrapped_invite)},
        "blobs": blobs,
        "mismatch": {"blob_id": blob_id, "device_id": device_id, "claimed_seq": 6, "key_epoch": 1,
                     "ciphertext": hx(mism)},
    })


# ==========================================================================
# destination.json
# ==========================================================================
def gen_destination():
    names = [
        ("lxmf", ["delivery"]),
        ("lxmf", ["propagation"]),
        ("kestrel", ["bridge"]),
        ("nomadnetwork", ["node"]),
        ("rnstransport", ["probe"]),
        ("app", []),
        ("example", ["a", "b", "c"]),
    ]
    ids = list(IDENTITIES.items())
    out = []
    for app, aspects in names:
        full = ".".join([app] + aspects)
        nh = RNS.Destination.name_hash(full)
        item = {"app_name": app, "aspects": aspects, "full_name": full, "name_hash": hx(nh), "per_identity": []}
        # SINGLE destinations: hash with each identity
        for iname, ident in ids:
            h = RNS.Destination.hash(ident, app, *aspects)
            assert h == RNS.Destination.hash_from_name_and_identity(full, ident)
            assert h == RNS.Destination.hash(ident.hash, app, *aspects)
            item["per_identity"].append({
                "identity": iname,
                "hash": hx(h),
                "expanded_name": RNS.Destination.expand_name(ident, app, *aspects),
            })
        # PLAIN destinations: no identity
        item["plain_hash"] = hx(RNS.Destination.hash(None, app, *aspects))
        item["plain_expanded_name"] = RNS.Destination.expand_name(None, app, *aspects)
        out.append(item)

    # Dots in names are rejected.
    for bad in (("a.b", []), ("a", ["b.c"])):
        try:
            RNS.Destination.expand_name(None, bad[0], *bad[1])
            raise AssertionError("expected ValueError")
        except ValueError:
            pass

    write("destination.json", {"destinations": out})


# ==========================================================================
# packet.json
# ==========================================================================
class _LinkStub:
    """Minimal stand-in for an RNS.Link destination (Phase 3 implements Links)."""

    def __init__(self, link_id):
        self.type = RNS.Destination.LINK
        self.hash = link_id
        self.link_id = link_id
        self.mtu = RNS.Reticulum.MTU
        self.status = None

    def encrypt(self, data):
        return data  # real link encryption is Phase 3; payload below is opaque


def packet_record(name, p, note=None):
    """Serialise a packed outbound packet as a vector."""
    raw = p.raw
    rec = {
        "name": name,
        "raw": hx(raw),
        "flags": raw[0],
        "hops": p.hops,
        "header_type": p.header_type,
        "context_flag": p.context_flag,
        "transport_type": p.transport_type,
        "destination_type": (raw[0] >> 2) & 3,
        "packet_type": p.packet_type,
        "context": p.context,
        "transport_id": hx(p.transport_id) if p.header_type == RNS.Packet.HEADER_2 else None,
        "destination_hash": hx(p.destination_hash),
        "data": hx(p.ciphertext),
        "packet_hash": hx(p.packet_hash),
        "truncated_packet_hash": hx(p.truncated_packet_hash),
        "hashable_part": hx(p.get_hashable_part()),
    }
    if note:
        rec["note"] = note
    # Re-parse like a receiver would and make sure Python agrees with itself.
    q = RNS.Packet(None, raw)
    assert q.unpack()
    assert q.packet_hash == p.packet_hash
    assert q.destination_hash == p.destination_hash
    assert q.data == p.ciphertext
    return rec


def gen_packet():
    alice, bob = IDENTITIES["alice"], IDENTITIES["bob"]
    plain_dest = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN, "kestrel", "plain")
    single_out = dest_out(bob, "lxmf", "delivery")
    link_id = det("link/id", 16)
    link = _LinkStub(link_id)
    transport_id = det("transport/id", 16)

    packets = []

    def add(name, dest, data, ptype=RNS.Packet.DATA, context=RNS.Packet.NONE, header_type=RNS.Packet.HEADER_1,
            transport_type=RNS.Transport.BROADCAST, hops=0, tid=None, context_flag=RNS.Packet.FLAG_UNSET, note=None,
            ephemeral=None, iv=None):
        want_h2 = header_type == RNS.Packet.HEADER_2 and ptype != RNS.Packet.ANNOUNCE
        # RNS.Packet.pack() can only emit HEADER_2 for announces; Transport rewrites other packets'
        # raw bytes when forwarding (Transport.py inbound/outbound). Emulate that here.
        p = RNS.Packet(dest, data, ptype, context=context, header_type=RNS.Packet.HEADER_1 if want_h2 else header_type,
                       transport_type=transport_type, transport_id=tid, context_flag=context_flag, create_receipt=False)
        p.hops = hops
        with deterministic(ephemeral=ephemeral, iv=iv):
            p.pack()
        if want_h2:
            flags = (1 << 6) | (context_flag << 5) | (transport_type << 4) | (p.raw[0] & 0b00001111)
            raw2 = bytes([flags, hops]) + tid + p.raw[2:]
            h1_hash = p.packet_hash
            p = RNS.Packet(None, raw2)
            assert p.unpack()
            assert p.packet_hash == h1_hash  # hash is invariant under H1 -> H2 rewrite
            p.raw = raw2
            p.ciphertext = p.data
        rec = packet_record(name, p, note)
        rec["plaintext"] = hx(data)
        packets.append(rec)
        return p

    add("data_plain_h1", plain_dest, b"plain payload")
    add("data_plain_h1_hops5", plain_dest, b"plain payload", hops=5)
    add("data_plain_h2_transport", plain_dest, b"plain payload", header_type=RNS.Packet.HEADER_2,
        transport_type=RNS.Transport.TRANSPORT, hops=3, tid=transport_id)
    p = add("data_single_h1_encrypted", single_out, b"opportunistic hello",
            ephemeral=det("pkt/eph", 32), iv=det("pkt/iv", 16),
            note="payload is Identity.encrypt() of plaintext to bob (ciphertext in 'data')")
    packets[-1]["recipient"] = "bob"
    add("data_single_h2_encrypted", single_out, b"via transport", header_type=RNS.Packet.HEADER_2,
        transport_type=RNS.Transport.TRANSPORT, hops=1, tid=transport_id,
        ephemeral=det("pkt/eph2", 32), iv=det("pkt/iv2", 16))
    packets[-1]["recipient"] = "bob"
    add("linkrequest_h1", single_out, det("lr/data", 67), ptype=RNS.Packet.LINKREQUEST,
        note="LINKREQUEST data is not encrypted (64 byte keys + 3 byte signalling)")
    add("linkrequest_h2", single_out, det("lr/data", 67), ptype=RNS.Packet.LINKREQUEST,
        header_type=RNS.Packet.HEADER_2, transport_type=RNS.Transport.TRANSPORT, hops=2, tid=transport_id)
    add("proof_single_explicit", RNS.Packet.__dict__ and _ProofDest(det("proof/hash", 16)),
        det("proof/data", 32 + 64), ptype=RNS.Packet.PROOF,
        note="explicit proof: packet_hash(32) + signature(64); destination is truncated hash of proven packet")
    add("proof_link", link, det("proof/link", 64), ptype=RNS.Packet.PROOF, context=RNS.Packet.LINKPROOF)
    add("lrproof", link, det("lrproof", 96), ptype=RNS.Packet.PROOF, context=RNS.Packet.LRPROOF,
        note="LRPROOF: destination type forced to LINK in flags")
    add("keepalive_link", link, b"\xff", context=RNS.Packet.KEEPALIVE)
    add("resource_link", link, det("res", 200), context=RNS.Packet.RESOURCE)
    add("request_link", link, det("req", 40), context=RNS.Packet.REQUEST)
    add("channel_link", link, det("chan", 40), context=RNS.Packet.CHANNEL)
    add("context_flag_set", plain_dest, b"flag", context_flag=RNS.Packet.FLAG_SET)
    add("max_size_plain", plain_dest, det("max", RNS.Reticulum.MDU), note="payload exactly MDU bytes => packet == MTU")

    # Contexts: every defined constant must round-trip.
    contexts = {
        "NONE": 0x00, "RESOURCE": 0x01, "RESOURCE_ADV": 0x02, "RESOURCE_REQ": 0x03, "RESOURCE_HMU": 0x04,
        "RESOURCE_PRF": 0x05, "RESOURCE_ICL": 0x06, "RESOURCE_RCL": 0x07, "CACHE_REQUEST": 0x08,
        "REQUEST": 0x09, "RESPONSE": 0x0A, "PATH_RESPONSE": 0x0B, "COMMAND": 0x0C, "COMMAND_STATUS": 0x0D,
        "CHANNEL": 0x0E, "KEEPALIVE": 0xFA, "LINKIDENTIFY": 0xFB, "LINKCLOSE": 0xFC, "LINKPROOF": 0xFD,
        "LRRTT": 0xFE, "LRPROOF": 0xFF,
    }
    for k, v in contexts.items():
        assert getattr(RNS.Packet, k) == v, k

    # Receive-side vectors that Python must reject.
    valid_raw = bytes.fromhex(packets[0]["raw"])
    invalid = []

    def chk(name, raw):
        q = RNS.Packet(None, raw)
        assert q.unpack() is False, name
        invalid.append({"name": name, "raw": hx(raw)})

    chk("empty", b"")
    chk("one_byte", b"\x00")
    chk("header_only_no_data", valid_raw[:19])  # flags,hops,dest(16),ctx => zero-length data
    chk("hops_128", bytes([valid_raw[0], 128]) + valid_raw[2:])
    chk("hops_255", bytes([valid_raw[0], 255]) + valid_raw[2:])
    chk("h2_truncated", bytes([0x40 | valid_raw[0], 0]) + b"\x01" * 20)

    # Boundary: hops 127 is still accepted
    ok = bytes([valid_raw[0], 127]) + valid_raw[2:]
    assert RNS.Packet(None, ok).unpack()

    write("packet.json", {
        "mtu": RNS.Reticulum.MTU, "mdu": RNS.Reticulum.MDU, "header_maxsize": RNS.Reticulum.HEADER_MAXSIZE,
        "header_minsize": RNS.Reticulum.HEADER_MINSIZE, "pathfinder_m": RNS.Transport.PATHFINDER_M,
        "encrypted_mdu": RNS.Packet.ENCRYPTED_MDU, "token_overhead": RNS.Identity.TOKEN_OVERHEAD,
        "identities": [identity_json("alice", alice), identity_json("bob", bob)],
        "packets": packets,
        "invalid_raw": invalid,
        "hops_127_ok_raw": hx(ok),
        "contexts": contexts,
    })


class _ProofDest:
    """ProofDestination stand-in: SINGLE type, hash = truncated hash of proven packet."""

    def __init__(self, h):
        self.hash = h
        self.type = RNS.Destination.SINGLE

    def encrypt(self, data):
        return data


# ==========================================================================
# announce.json
# ==========================================================================
def build_announce(identity, app, aspects, app_data, ratchet_prv, random_hash, now, path_response=False):
    d = dest_in(identity, app, *aspects)
    if ratchet_prv is not None:
        d.ratchets = [ratchet_prv]
        d.latest_ratchet_time = now
        d.ratchet_interval = 10**9  # no rotation during generation
    with deterministic(now=now, random_hash=random_hash):
        p = d._announce(app_data=app_data, path_response=path_response, send=False)
    p.hops = 0
    p.pack()
    return d, p


def validate_with_python(raw):
    IM.Identity._reset_validation_caches()
    IM.Identity.known_destinations.clear()
    q = RNS.Packet(None, raw)
    assert q.unpack()
    return RNS.Identity.validate_announce(q)


def gen_announce():
    alice = IDENTITIES["alice"]
    cases = []
    specs = [
        ("lxmf_delivery_plain", "lxmf", ["delivery"], b"Alice", None, False),
        ("lxmf_delivery_no_appdata", "lxmf", ["delivery"], None, None, False),
        ("lxmf_delivery_ratchet", "lxmf", ["delivery"], b"Alice", det("ratchet/alice", 32), False),
        ("kestrel_bridge_ratchet_noappdata", "kestrel", ["bridge"], None, det("ratchet/alice2", 32), False),
        ("path_response", "lxmf", ["delivery"], b"pr", None, True),
        ("large_appdata", "nomadnetwork", ["node"], det("appdata", 120), None, False),
        # app_data that merely *looks* like a stamp ext payload; unverified stamps are left in app_data.
        ("appdata_with_ext_payload", "lxmf", ["delivery"],
         b"x" + bytes([0xC1, 0x00]) + det("fakestamp", 14) + bytes([0x00, 0x18]), None, False),
    ]
    for idx, (name, app, aspects, app_data, ratchet_prv, pr) in enumerate(specs):
        random_hash = det(f"announce/rh/{idx}", 16)
        now = 1700000000 + idx
        d, p = build_announce(alice, app, aspects, app_data, ratchet_prv, random_hash, now, pr)
        raw = p.raw
        assert validate_with_python(raw) is True
        rec = packet_record(name, p)
        rec.update({
            "identity": "alice", "app_name": app, "aspects": aspects,
            "name_hash": hx(d.name_hash), "destination_hash": hx(d.hash),
            "app_data": hx(app_data), "ratchet_private": hx(ratchet_prv),
            "ratchet_public": hx(IM.Identity._ratchet_public_bytes(ratchet_prv)) if ratchet_prv else None,
            "random_hash_10": hx(random_hash[0:5] + int(now).to_bytes(5, "big")),
            "random_hash_seed5": hx(random_hash[0:5]),
            "timestamp": now,
            "path_response": pr,
            "announce_data": hx(p.ciphertext),
        })
        cases.append(rec)

    # HEADER_2 re-emission by a transport node (hops+1, transport id inserted); validity is unchanged.
    base = cases[2]
    p = RNS.Packet(None, bytes.fromhex(base["raw"]))
    assert p.unpack()
    transport_id = det("announce/transport", 16)
    new_flags = (1 << 6) | (p.context_flag << 5) | (1 << 4) | ((p.flags & 0b1100)) | RNS.Packet.ANNOUNCE
    h2_raw = bytes([new_flags, 1]) + transport_id + p.destination_hash + bytes([p.context]) + p.data
    assert validate_with_python(h2_raw) is True
    q = RNS.Packet(None, h2_raw)
    assert q.unpack()
    assert q.packet_hash == p.packet_hash  # transport rewrite doesn't change the packet hash
    h2 = {
        "name": "ratchet_announce_via_transport", "raw": hx(h2_raw), "transport_id": hx(transport_id),
        "hops": 1, "packet_hash": hx(q.packet_hash), "destination_hash": base["destination_hash"],
        "source_raw": base["raw"],
    }

    # Invalid announces: Python must reject every one.
    invalid = []
    good_raw = bytes.fromhex(cases[0]["raw"])

    def mutate(i, xor=1):
        b = bytearray(good_raw)
        b[i] ^= xor
        return bytes(b)

    n_hdr = 19  # H1 header: flags,hops,dest(16),context
    ann_off = {"pub": n_hdr, "name": n_hdr + 64, "rand": n_hdr + 74, "sig": n_hdr + 84, "appdata": n_hdr + 148}
    bad = {
        "bad_signature": mutate(ann_off["sig"]),
        "tampered_app_data": mutate(ann_off["appdata"]),
        "tampered_public_key": mutate(ann_off["pub"] + 5),
        "tampered_name_hash": mutate(ann_off["name"]),
        "tampered_random_hash": mutate(ann_off["rand"]),
        "tampered_destination_hash": mutate(2),  # dest hash is part of signed material
        "truncated_signature": good_raw[: ann_off["sig"] + 30],
    }
    for name, raw in bad.items():
        q = RNS.Packet(None, raw)
        if q.unpack():
            assert not validate_with_python(raw), name
        invalid.append({"name": name, "raw": hx(raw)})

    # Valid signature, but destination hash does not match name_hash + identity hash.
    # Build by signing an announce for the wrong destination hash.
    wrong_dest = det("announce/wrongdest", 16)
    pub = alice.get_public_key()
    name_hash = RNS.Destination.name_hash("lxmf.delivery")
    rh = det("announce/wd/rh", 10)
    signed = wrong_dest + pub + name_hash + rh + b"x"
    sig = alice.sign(signed)
    data = pub + name_hash + rh + sig + b"x"
    raw = bytes([0x01, 0x00]) + wrong_dest + b"\x00" + data
    assert not validate_with_python(raw)
    invalid.append({"name": "dest_hash_mismatch_valid_signature", "raw": hx(raw)})

    write("announce.json", {
        "identity": identity_json("alice", alice),
        "announces": cases,
        "transport_reemitted": h2,
        "invalid": invalid,
        "layout": {"keysize": 64, "name_hash": 10, "random_hash": 10, "ratchet": 32, "signature": 64},
        "ext_payload": {"marker": IM.Identity.EXTPAYLOADMARKER, "header_length": IM.Identity.EXTHEADERLENGTH,
                        "stamp_length": IM.Identity.STAMPLENGTH, "total_length": IM.Identity.EXTPAYLOADLENGTH},
    })


# ==========================================================================
# framing: hdlc.json / kiss.json
# ==========================================================================
def py_hdlc_read(chunks, hw_mtu=262144, ifac_size=0):
    """Verbatim port of TCPInterface.read_loop (HDLC branch) returning delivered frames."""
    frames = []
    frame_buffer = b""
    for data_in in chunks:
        frame_buffer += data_in
        flags_remaining = True
        while flags_remaining:
            frame_start = frame_buffer.find(HDLC.FLAG)
            if frame_start != -1:
                frame_end = frame_buffer.find(HDLC.FLAG, frame_start + 1)
                if frame_end != -1:
                    frame = frame_buffer[frame_start + 1:frame_end]
                    frame = frame.replace(bytes([HDLC.ESC, HDLC.FLAG ^ HDLC.ESC_MASK]), bytes([HDLC.FLAG]))
                    frame = frame.replace(bytes([HDLC.ESC, HDLC.ESC ^ HDLC.ESC_MASK]), bytes([HDLC.ESC]))
                    frame_len = len(frame)
                    if frame_len != 0:
                        # TCPInterface.check_frame_len
                        if frame_len > RNS.Reticulum.HEADER_MINSIZE and frame_len <= hw_mtu + (ifac_size or 0):
                            frames.append(frame)
                    frame_buffer = frame_buffer[frame_end:]
                else:
                    if len(frame_buffer) > hw_mtu * 2:
                        frame_buffer = b""
                    flags_remaining = False
            else:
                frame_buffer = b""
                flags_remaining = False
    return frames


def gen_hdlc():
    payloads = [
        b"", b"A" * 20, bytes([0x7E]) * 25, bytes([0x7D]) * 25, bytes([0x7E, 0x7D]) * 12,
        bytes(range(256)), bytes([0x7D, 0x5E]) * 12, bytes([0x7D, 0x5D, 0x5E, 0x5D]) * 6,
        det("hdlc/rand", 400), b"\x7e", b"\x7d", b"\x00",
    ]
    frames = []
    for p in payloads:
        framed = bytes([HDLC.FLAG]) + HDLC.escape(p) + bytes([HDLC.FLAG])
        frames.append({"payload": hx(p), "escaped": hx(HDLC.escape(p)), "frame": hx(framed)})

    streams = []

    def stream(name, chunks, hw_mtu=262144):
        streams.append({
            "name": name, "chunks": [hx(c) for c in chunks], "hw_mtu": hw_mtu,
            "frames": [hx(f) for f in py_hdlc_read(chunks, hw_mtu)],
        })

    fr = lambda p: bytes([HDLC.FLAG]) + HDLC.escape(p) + bytes([HDLC.FLAG])
    p1, p2, p3 = det("hdlc/s1", 40), bytes([0x7E, 0x7D]) * 15, det("hdlc/s3", 25)
    stream("single", [fr(p1)])
    stream("back_to_back_one_chunk", [fr(p1) + fr(p2) + fr(p3)])
    stream("split_every_byte", [bytes([b]) for b in fr(p1) + fr(p2)])
    stream("split_mid_frame", [fr(p1)[:10], fr(p1)[10:] + fr(p2)[:7], fr(p2)[7:]])
    stream("leading_garbage", [b"\x01\x02\x03" + fr(p1)])
    stream("garbage_between", [fr(p1) + b"\x11\x22" + fr(p2)])
    stream("empty_frames_ignored", [bytes([0x7E, 0x7E, 0x7E]) + fr(p1)])
    stream("short_frame_dropped_le_header_minsize", [fr(b"A" * 19) + fr(b"A" * 20)])
    stream("no_closing_flag_pending", [bytes([0x7E]) + p1])
    stream("shared_flag_between_frames", [bytes([0x7E]) + HDLC.escape(p1) + bytes([0x7E]) + HDLC.escape(p2) + bytes([0x7E])])
    stream("oversize_dropped_small_mtu", [fr(b"B" * 60) + fr(b"C" * 30)], hw_mtu=50)
    stream("buffer_overflow_reset", [bytes([0x7E]) + b"Z" * 150, fr(p1)], hw_mtu=50)

    write("hdlc.json", {
        "flag": HDLC.FLAG, "esc": HDLC.ESC, "esc_mask": HDLC.ESC_MASK, "header_minsize": RNS.Reticulum.HEADER_MINSIZE,
        "default_hw_mtu": 262144, "frames": frames, "streams": streams,
    })


def py_kiss_read(chunks, hw_mtu=508):
    """Port of RNodeInterface.readLoop for CMD_DATA, generalised to report all commands.

    Non-data commands are reported with their unescaped payload (RNodeInterface itself parses
    fixed-length payloads for those; framing is identical).
    """
    out = []
    in_frame = False
    escape = False
    command = KISS.CMD_UNKNOWN
    buf = b""
    for chunk in chunks:
        for byte in chunk:
            if in_frame and byte == KISS.FEND and command != KISS.CMD_UNKNOWN:
                in_frame = False
                out.append((command, buf))
                buf = b""
            elif byte == KISS.FEND:
                in_frame = True
                command = KISS.CMD_UNKNOWN
                buf = b""
            elif in_frame and len(buf) < hw_mtu:
                if len(buf) == 0 and command == KISS.CMD_UNKNOWN:
                    command = byte
                else:
                    if byte == KISS.FESC:
                        escape = True
                    else:
                        if escape:
                            if byte == KISS.TFEND:
                                byte = KISS.FEND
                            if byte == KISS.TFESC:
                                byte = KISS.FESC
                            escape = False
                        buf = buf + bytes([byte])
    return out


def gen_kiss():
    payloads = [
        b"", b"hello", bytes([0xC0]) * 10, bytes([0xDB]) * 10, bytes([0xC0, 0xDB, 0xDC, 0xDD]) * 5,
        bytes(range(256)), det("kiss/rand", 300), bytes([0xDB, 0xDC]), bytes([0xDB, 0xDD]),
    ]
    frames = []
    for p in payloads:
        frames.append({
            "payload": hx(p), "escaped": hx(KISS.escape(p)),
            "frame": hx(bytes([KISS.FEND, KISS.CMD_DATA]) + KISS.escape(p) + bytes([KISS.FEND])),
        })

    # Command frames as RNodeInterface builds them.
    def cmd_frame(cmd, payload):
        return bytes([KISS.FEND, cmd]) + KISS.escape(payload) + bytes([KISS.FEND])

    freq = 867200000
    bw = 125000
    commands = [
        {"name": "frequency", "command": KISS.CMD_FREQUENCY, "payload": struct.pack(">I", freq)},
        {"name": "bandwidth", "command": KISS.CMD_BANDWIDTH, "payload": struct.pack(">I", bw)},
        {"name": "txpower", "command": KISS.CMD_TXPOWER, "payload": bytes([17])},
        {"name": "sf", "command": KISS.CMD_SF, "payload": bytes([8])},
        {"name": "cr", "command": KISS.CMD_CR, "payload": bytes([5])},
        {"name": "radio_state_on", "command": KISS.CMD_RADIO_STATE, "payload": bytes([KISS.RADIO_STATE_ON])},
        {"name": "detect_req", "command": KISS.CMD_DETECT, "payload": bytes([KISS.DETECT_REQ])},
        {"name": "frequency_escapes_fend", "command": KISS.CMD_FREQUENCY, "payload": bytes([0xC0, 0xDB, 0x00, 0xC0])},
    ]
    for c in commands:
        c["frame"] = hx(cmd_frame(c["command"], c["payload"]))
        c["payload"] = hx(c["payload"])

    streams = []

    def stream(name, chunks, hw_mtu=508):
        streams.append({
            "name": name, "chunks": [hx(c) for c in chunks], "hw_mtu": hw_mtu,
            "frames": [{"command": c, "data": hx(d)} for c, d in py_kiss_read(chunks, hw_mtu)],
        })

    fr = lambda p: bytes([KISS.FEND, KISS.CMD_DATA]) + KISS.escape(p) + bytes([KISS.FEND])
    p1, p2 = det("kiss/s1", 40), bytes([0xC0, 0xDB]) * 10
    stream("single", [fr(p1)])
    stream("back_to_back", [fr(p1) + fr(p2)])
    stream("split_every_byte", [bytes([b]) for b in fr(p1) + fr(p2)])
    stream("split_inside_escape", [fr(p2)[:4], fr(p2)[4:]])
    stream("leading_garbage", [b"\x01\x02" + fr(p1)])
    stream("empty_data_frame", [bytes([KISS.FEND, KISS.CMD_DATA, KISS.FEND]) + fr(p1)])
    stream("interleaved_commands", [cmd_frame(KISS.CMD_TXPOWER, bytes([17])) + fr(p1)
                                    + cmd_frame(KISS.CMD_FREQUENCY, struct.pack(">I", freq)) + fr(p2)])
    stream("unfinished_frame_then_new", [bytes([KISS.FEND, KISS.CMD_DATA]) + b"abc", fr(p1)])
    stream("oversize_truncated_at_hw_mtu", [fr(b"Q" * 80)], hw_mtu=32)

    write("kiss.json", {
        "fend": KISS.FEND, "fesc": KISS.FESC, "tfend": KISS.TFEND, "tfesc": KISS.TFESC,
        "cmd_data": KISS.CMD_DATA, "default_hw_mtu": 508, "frames": frames, "commands": commands, "streams": streams,
    })


# ==========================================================================
# msgpack.json
# ==========================================================================
def to_tree(o):
    """Typed JSON tree that keeps bin/str and int/float distinctions."""
    if o is None:
        return {"type": "nil"}
    if isinstance(o, bool):
        return {"type": "bool", "value": o}
    if isinstance(o, int):
        return {"type": "int", "value": str(o)}
    if isinstance(o, float):
        return {"type": "float", "bits": struct.pack(">d", o).hex()}
    if isinstance(o, str):
        return {"type": "str", "value": o}
    if isinstance(o, bytes):
        return {"type": "bin", "hex": o.hex()}
    if isinstance(o, (list, tuple)):
        return {"type": "array", "items": [to_tree(x) for x in o]}
    if isinstance(o, dict):
        return {"type": "map", "entries": [[to_tree(k), to_tree(v)] for k, v in o.items()]}
    raise TypeError(type(o))


def gen_msgpack():
    ts = 1700000000.123456
    objs = {
        "nil": None, "true": True, "false": False,
        "int_0": 0, "int_127": 127, "int_128": 128, "int_255": 255, "int_256": 256, "int_65535": 65535,
        "int_65536": 65536, "int_u32_max": 2**32 - 1, "int_u32_over": 2**32, "int_i63_max": 2**63 - 1,
        "int_u64_max": 2**64 - 1, "int_-1": -1, "int_-32": -32, "int_-33": -33, "int_-128": -128,
        "int_-129": -129, "int_-32768": -32768, "int_-32769": -32769, "int_-2^31": -2**31,
        "int_-2^31-1": -2**31 - 1, "int_-2^63": -2**63,
        "float_zero": 0.0, "float_neg_zero": -0.0, "float_one": 1.0, "float_1_5": 1.5,
        "float_timestamp": ts, "float_integral_not_int": 1700000000.0, "float_inf": float("inf"),
        "float_neg_inf": float("-inf"), "float_tiny": 5e-324, "float_max": 1.7976931348623157e308,
        "str_empty": "", "str_31": "a" * 31, "str_32": "b" * 32, "str_255": "c" * 255, "str_256": "d" * 256,
        "str_unicode": "Привіт, світе! ☃ \U0001F426", "str_nul": "a\x00b",
        "bin_empty": b"", "bin_1": b"\x00", "bin_255": bytes(range(255)), "bin_256": bytes(range(256)),
        "bin_vs_str_same_text": [b"abc", "abc"],
        "array_empty": [], "array_15": list(range(15)), "array_16": list(range(16)), "array_300": list(range(300)),
        "map_empty": {}, "map_15": {i: i for i in range(15)}, "map_16": {i: i for i in range(16)},
        "map_int_keys": {0x05: [b"a.txt", b"data"], 0x06: ["png", b"\x89PNG"], 0xFF: None, 0x30: b"\x01" * 32},
        "map_str_keys": {"a": 1, "b": [1, 2, {"c": b"d"}], "e": 1.5},
        "map_mixed_keys": {1: "int", "1": "str", b"1": "bin"},
        "nested": {"x": [[[[]]], {"y": {"z": [None, True, False, 0, -1, 1.0, "s", b"b"]}}]},
        # LXMF payload shape: [timestamp(float64), title(bin), content(bin), fields(map int->any)]
        "lxmf_payload": [ts, "Тема".encode(), "Привіт".encode(), {}],
        "lxmf_payload_fields": [ts, b"t", b"c", {0x05: [[b"f.bin", bytes(range(40))]], 0x08: b"\x00" * 32, 0x40: {0: 1, 1: "x"}}],
        "lxmf_payload_stamp": [ts, b"", b"", {}, det("stamp", 32)],
        "int_vs_float_in_array": [1, 1.0, -1, -1.0, 0, 0.0],
    }
    vectors = []
    for name, obj in objs.items():
        packed = umsgpack.packb(obj)
        back = umsgpack.unpackb(packed)
        assert umsgpack.packb(back) == packed, name
        vectors.append({"name": name, "hex": hx(packed), "tree": to_tree(obj)})

    # Non-canonical encodings Python accepts: decode-only (Dart must decode to the same tree).
    decode_only_hex = {
        "float32": "ca3fc00000",
        "uint8_small": "cc05", "uint16_small": "cd0005", "uint32_small": "ce00000005", "uint64_small": "cf0000000000000005",
        "int8_pos": "d005", "int16_neg_small": "d1ffff", "int32_neg_small": "d2ffffffff", "int64_neg_small": "d3ffffffffffffffff",
        "str8_short": "d90161", "str16_short": "da000161", "str32_short": "db0000000161",
        "bin16_short": "c5000161", "bin32_short": "c6000000010a",
        "array16_short": "dc0002 0102".replace(" ", ""), "array32_short": "dd00000002 0102".replace(" ", ""),
        "map16_short": "de0001 0102".replace(" ", ""), "map32_short": "df00000001 0102".replace(" ", ""),
        "positive_fixint_127": "7f", "trailing_bytes_ignored": "0102", "negative_fixint_-32": "e0",
    }
    decode_only = []
    for name, h in decode_only_hex.items():
        obj = umsgpack.unpackb(bytes.fromhex(h))
        decode_only.append({"name": name, "hex": h, "tree": to_tree(obj), "canonical_hex": hx(umsgpack.packb(obj))})

    # Inputs Python rejects.
    invalid_hex = {
        "reserved_c1": "c1", "truncated_u16": "cd01", "truncated_str": "a3ab", "truncated_array": "9201",
        "invalid_utf8_str": "a1ff", "duplicate_key": "82 01 01 01 02".replace(" ", ""),
        "empty": "",
    }
    invalid = []
    for name, h in invalid_hex.items():
        try:
            umsgpack.unpackb(bytes.fromhex(h))
            raise AssertionError(f"python accepted {name}")
        except AssertionError:
            raise
        except Exception:
            invalid.append({"name": name, "hex": h})

    write("msgpack.json", {"vectors": vectors, "decode_only": decode_only, "invalid": invalid})


# ==========================================================================
# lxmf.json
# ==========================================================================
def lxmf_record(name, lxm, source_ident, dest_ident, note=None, extra=None):
    packed = lxm.packed
    rec = {
        "name": name,
        "destination_identity": dest_ident, "source_identity": source_ident,
        "destination_hash": hx(lxm.destination_hash), "source_hash": hx(lxm.source_hash),
        "timestamp_bits": struct.pack(">d", lxm.timestamp).hex(),
        "title": hx(lxm.title), "content": hx(lxm.content),
        "fields": to_tree(lxm.fields), "stamp": hx(lxm.stamp),
        "packed": hx(packed), "message_hash": hx(lxm.hash), "signature": hx(lxm.signature),
        "method": lxm.method, "desired_method": lxm.desired_method,
        "representation": lxm.representation,
    }
    if note:
        rec["note"] = note
    if extra:
        rec.update(extra)

    # Receiver side: unpack with sender's identity known => signature must validate.
    src = RNS.Identity.recall  # noqa: F841 (documentation anchor)
    return rec


def gen_lxmf():
    alice, bob = IDENTITIES["alice"], IDENTITIES["bob"]
    a_in = dest_in(alice, "lxmf", "delivery")
    b_out = dest_out(bob, "lxmf", "delivery")
    b_in = dest_in(bob, "lxmf", "delivery")

    msgs = []

    def make(name, content, title, fields, method, ts, ticket=None, note=None):
        lxm = LXMessage(b_out, a_in, content=content, title=title, fields=fields, desired_method=method)
        if ticket is not None:
            lxm.defer_stamp = False
            lxm.outbound_ticket = ticket
        with deterministic(now=ts):
            lxm.pack()
        assert lxm.signature_validated
        rec = lxmf_record(name, lxm, "alice", "bob", note)
        rec["content_utf8"] = content if isinstance(content, str) else None
        rec["title_utf8"] = title if isinstance(title, str) else None
        msgs.append((rec, lxm))
        return rec, lxm

    ts0 = 1700000000.5
    make("simple_direct", "Hello Bob", "", None, LXMessage.DIRECT, ts0)
    make("with_title_unicode", "Привіт, Боб! ☃", "Тема", None, LXMessage.DIRECT, ts0 + 1)
    make("opportunistic_short", "ping", "", None, LXMessage.OPPORTUNISTIC, ts0 + 2)
    make("bytes_content", b"\x00\xff raw bytes content", b"\x01\x02", None, LXMessage.DIRECT, ts0 + 3)
    make("empty_message", "", "", None, LXMessage.DIRECT, ts0 + 4)
    fields = {
        LXMF.FIELD_FILE_ATTACHMENTS: [["notes.txt", b"file bytes"], ["bin.dat", bytes(range(64))]],
        LXMF.FIELD_IMAGE: ["webp", det("img", 80)],
        LXMF.FIELD_THREAD: det("thread", 32),
        LXMF.FIELD_REACTION: {0: det("react/target", 32), 1: "\U0001F44D"},
        LXMF.FIELD_CUSTOM_TYPE: b"kestrel.test",
        LXMF.FIELD_CUSTOM_DATA: {"cmd_id": "00000000-0000-4000-8000-000000000001", "n": -7, "f": 0.25, "ok": True, "none": None},
        LXMF.FIELD_DEBUG: [1, 2.0, -3],
        0x7F: {1: {2: {3: [b"deep"]}}},
    }
    make("custom_fields", "see attachments", "files", fields, LXMessage.DIRECT, ts0 + 5)
    make("fields_only_int_keys", "", "", {0x01: 1, 0x02: 2.0, 0x03: [3], 0xFE: b"", 0xFF: ""}, LXMessage.DIRECT, ts0 + 6)
    make("integral_timestamp", "int-valued float timestamp", "", None, LXMessage.DIRECT, 1700000000.0)
    big = "L" * 700
    make("large_resource_rep", big, "", None, LXMessage.DIRECT, ts0 + 8,
         note="content exceeds link packet MDU => representation RESOURCE (Phase 3)")
    # Stamped via outbound ticket => deterministic stamp in payload[4].
    ticket = det("ticket", 16)
    make("ticket_stamp", "stamped by ticket", "", None, LXMessage.DIRECT, ts0 + 9, ticket=ticket)
    msgs[-1][0]["ticket"] = hx(ticket)
    assert msgs[-1][1].stamp is not None

    # Opportunistic wire form + encrypted packet + propagation form.
    wire = []
    for idx, (rec, lxm) in enumerate(msgs):
        if rec["name"] not in ("opportunistic_short", "simple_direct", "with_title_unicode", "custom_fields"):
            continue
        eph = det(f"lxmf/eph/{idx}", 32)
        iv = det(f"lxmf/iv/{idx}", 16)
        opp_payload = lxm.packed[LXMessage.DESTINATION_LENGTH:]
        with deterministic(ephemeral=eph, iv=iv):
            enc = b_out.encrypt(opp_payload)
        # Full RNS DATA packet for opportunistic delivery (HEADER_1, SINGLE dest, context NONE)
        pk = RNS.Packet(b_out, opp_payload, create_receipt=False)
        try:
            with deterministic(ephemeral=eph, iv=iv):
                pk.pack()
        except OSError:
            pk = None  # too big for a single packet (> MTU)
        # Propagated form (propagation_packed = [timestamp, [dest_hash + encrypted(packed[16:])]]).
        lxm_p = LXMessage(b_out, a_in, content=rec["content_utf8"] or "", title=rec["title_utf8"] or "",
                          fields=lxm.fields, desired_method=LXMessage.PROPAGATED)
        lxm_p.timestamp = lxm.timestamp
        with deterministic(ephemeral=eph, iv=iv, now=ts0 + 100):
            lxm_p.pack()
        assert lxm_p.packed == lxm.packed
        wire.append({
            "message": rec["name"],
            "opportunistic_payload": hx(opp_payload),
            "encrypted_payload": hx(enc),
            "ephemeral_private": hx(eph), "iv": hx(iv),
            "packet_raw": hx(pk.raw) if pk else None, "packet_hash": hx(pk.packet_hash) if pk else None,
            "propagation_now": ts0 + 100,
            "propagation_packed": hx(lxm_p.propagation_packed),
            "transient_id": hx(lxm_p.transient_id),
        })

    # Parse vectors: unpack_from_bytes with / without known source identity.
    # (Python's unpack_from_bytes resolves identities through Identity.recall; we emulate "known" by
    # remembering alice's public key.)
    parsed = []
    IM.Identity.known_destinations.clear()
    for rec, lxm in msgs:
        u = LXMessage.unpack_from_bytes(lxm.packed)
        assert u.signature_validated is False and u.unverified_reason == LXMessage.SOURCE_UNKNOWN
        assert u.hash == lxm.hash
    RNS.Identity.remember(None, a_in.hash, alice.get_public_key())
    RNS.Identity.remember(None, b_out.hash, bob.get_public_key())
    for rec, lxm in msgs:
        u = LXMessage.unpack_from_bytes(lxm.packed)
        assert u.signature_validated is True, rec["name"]
        assert u.hash == lxm.hash and u.stamp == lxm.stamp
        assert u.timestamp == lxm.timestamp and u.fields == lxm.fields
        parsed.append(rec["name"])
    # Tampered signature / content
    first = msgs[0][1].packed
    t_sig = bytearray(first)
    t_sig[32 + 1] ^= 1
    t_content = bytearray(first)
    t_content[-2] ^= 1
    invalid = []
    for name, raw in (("tampered_signature", bytes(t_sig)), ("tampered_content", bytes(t_content))):
        u = LXMessage.unpack_from_bytes(raw)
        assert u.signature_validated is False and u.unverified_reason == LXMessage.SIGNATURE_INVALID
        invalid.append({"name": name, "packed": hx(raw), "unverified_reason": u.unverified_reason})
    IM.Identity.known_destinations.clear()

    write("lxmf.json", {
        "identities": [identity_json("alice", alice), identity_json("bob", bob)],
        "app_name": LXMF.APP_NAME,
        "destination_length": LXMessage.DESTINATION_LENGTH, "signature_length": LXMessage.SIGNATURE_LENGTH,
        "lxmf_overhead": LXMessage.LXMF_OVERHEAD,
        "encrypted_packet_max_content": LXMessage.ENCRYPTED_PACKET_MAX_CONTENT,
        "link_packet_max_content": LXMessage.LINK_PACKET_MAX_CONTENT,
        "methods": {"OPPORTUNISTIC": 1, "DIRECT": 2, "PROPAGATED": 3, "PAPER": 5},
        "fields": {k: getattr(LXMF, k) for k in dir(LXMF) if k.startswith("FIELD_")},
        "messages": [r for r, _ in msgs],
        "wire_forms": wire,
        "unverified_source_unknown": parsed,
        "invalid_signatures": invalid,
    })



# ==========================================================================
# network.json  (stamps, link crypto, request packing, resource advertisement)
# ==========================================================================
STAMPS_MOD = sys.modules["RNS.Stamps"]


def gen_network():
    from RNS.Cryptography import X25519PrivateKey, X25519PublicKey, Ed25519PrivateKey
    import bz2

    out = {}

    # ---- stamps ----
    S = STAMPS_MOD
    costs = [0, 1, 4, 8, 9.5, 12.5, 15.8, 23.5, 25.0, 99.5, 100]
    out["stamp_tab"] = [f"{v:x}" for v in S.TAB]
    out["stamp_costs"] = [
        {"cost": c, "fp": S.cost_to_fp(c), "bytes": hx(S.cost_to_bytes(c)),
         "target": f"{S.target_from_cost(c):064x}", "quantized": S.quantize_cost(c)}
        for c in costs
    ]
    values = []
    for i in range(12):
        material = det(f"stamp/material/{i}", 40 + 3 * i)
        stamp = det(f"stamp/stamp/{i}", 14)
        wb = S.stamp_workblock(material, expand_rounds=0)
        values.append({
            "material": hx(material), "stamp": hx(stamp), "value": S.stamp_value(wb, stamp),
            "valid_at": {str(c): S.stamp_valid(stamp, c, wb) for c in (0, 2, 4, 6, 8, 12)},
        })
    out["stamp_values"] = values
    # deterministic mined stamps (counter search) at costs that are cheap to verify
    mined = []
    for i, cost in enumerate((6, 8, 9.5)):
        material = det(f"stamp/mined/{i}", 42)
        wb = S.stamp_workblock(material, expand_rounds=0)
        n = 0
        while True:
            st = n.to_bytes(14, "big")
            if S.stamp_valid(st, cost, wb):
                break
            n += 1
        mined.append({"material": hx(material), "cost": cost, "stamp": hx(st), "value": S.stamp_value(wb, st)})
    out["stamp_mined"] = mined

    # ---- stamped announce ----
    alice = IDENTITIES["alice"]
    d = dest_in(alice, "kestrel", "net", "stamped")
    d._target_value = 8.0  # keep the (cheap) mined stamp instead of regenerating at cost 25
    wb = S.stamp_workblock(d.stamp_material(), expand_rounds=0)
    n = 0
    while not S.stamp_valid(n.to_bytes(14, "big"), 8, wb):
        n += 1
    stamp = n.to_bytes(14, "big")
    d.stamp = stamp
    d.stamp_value = S.stamp_value(wb, stamp)
    saved_val = RNS.Transport.DESTINATION_VALUE
    RNS.Transport.DESTINATION_VALUE = 8.0
    RNS.Transport.STAMP_DESTINATIONS = True
    try:
        random_hash = det("netann/rh", 16)
        now = 1700001234
        for app_data in (None, b"stamped-app"):
            with deterministic(now=now, random_hash=random_hash):
                p = d._announce(app_data=app_data, send=False)
            p.hops = 0
            p.pack()
            raw = p.raw
            IM.Identity._reset_validation_caches()
            IM.Identity.known_destinations.clear()
            q = RNS.Packet(None, raw)
            assert q.unpack()
            ok_low = RNS.Identity.validate_announce(q, required_value=8.0)
            known = IM.Identity.known_destinations.get(d.hash)
            out.setdefault("stamped_announces", []).append({
                "identity": "alice", "app_name": "kestrel", "aspects": ["net", "stamped"],
                "destination_hash": hx(d.hash), "app_data": hx(app_data), "stamp": hx(stamp),
                "stamp_value": d.stamp_value, "random_hash_seed5": hx(random_hash[:5]),
                "timestamp": now, "raw": hx(raw), "packet_hash": hx(p.packet_hash),
                "python_valid_at_8": ok_low is True,
                "stored_app_data": hx(known[3]) if known else None,
                "stored_stamp_value": known[6] if known else None,
                "stored_lr_cost": known[7] if known else None,
            })
    finally:
        RNS.Transport.DESTINATION_VALUE = saved_val
        RNS.Transport.STAMP_DESTINATIONS = False

    # ---- link key agreement ----
    bob = IDENTITIES["bob"]
    bob_dest = dest_out(bob, "kestrel", "net", "linkdest")
    init_x = det("link/init/x25519", 32)
    init_sig_seed = det("link/init/sig", 32)
    init_pub = X25519PrivateKey.from_private_bytes(init_x).public_key().public_bytes()
    init_sig_pub = Ed25519PrivateKey.from_private_bytes(init_sig_seed).public_key().public_bytes()
    resp_x = det("link/resp/x25519", 32)
    resp_pub = X25519PrivateKey.from_private_bytes(resp_x).public_key().public_bytes()

    links = []
    for mtu in (500, 16384, 262144):
        sig_b = RNS.Link.signalling_bytes(mtu, RNS.Link.MODE_AES256_CBC)
        req_data = init_pub + init_sig_pub + sig_b
        lr = RNS.Packet(bob_dest, req_data, packet_type=RNS.Packet.LINKREQUEST)
        lr.pack()
        link_id = RNS.Link.link_id_from_lr_packet(lr)
        lr_no_sig = RNS.Packet(bob_dest, init_pub + init_sig_pub, packet_type=RNS.Packet.LINKREQUEST)
        lr_no_sig.pack()

        def mk(prv, peer_pub):
            l = object.__new__(RNS.Link)
            l.status = RNS.Link.PENDING
            l.prv = X25519PrivateKey.from_private_bytes(prv)
            l.peer_pub = X25519PublicKey.from_public_bytes(peer_pub)
            l.mode = RNS.Link.MODE_AES256_CBC
            l.link_id = link_id
            l.token = None
            l.handshake()
            return l

        resp_link = mk(resp_x, init_pub)
        init_link = mk(init_x, resp_pub)
        assert resp_link.derived_key == init_link.derived_key
        signed = link_id + resp_pub + bob.get_public_key()[32:64] + sig_b
        signature = bob.sign(signed)
        proof_data = signature + resp_pub + sig_b
        iv = det(f"link/iv/{mtu}", 16)
        plaintext = det(f"link/plain/{mtu}", 77)
        with deterministic(iv=iv):
            ct = init_link.encrypt(plaintext)
        rtt = 0.0123 + mtu / 1e7
        init_link.token = None
        with deterministic(iv=iv):
            rtt_ct = init_link.encrypt(umsgpack.packb(rtt))
        mdu_link = object.__new__(RNS.Link)
        mdu_link.mtu = mtu
        mdu_link.update_mdu()
        links.append({
            "mtu": mtu, "signalling": hx(sig_b), "mdu": mdu_link.mdu,
            "initiator_x25519_private": hx(init_x), "initiator_sig_seed": hx(init_sig_seed),
            "initiator_pub": hx(init_pub), "initiator_sig_pub": hx(init_sig_pub),
            "responder_x25519_private": hx(resp_x), "responder_pub": hx(resp_pub),
            "destination_identity": "bob", "destination_hash": hx(bob_dest.hash),
            "link_request_raw": hx(lr.raw), "link_request_without_signalling_raw": hx(lr_no_sig.raw),
            "link_id": hx(link_id), "link_id_without_signalling": hx(RNS.Link.link_id_from_lr_packet(lr_no_sig)),
            "shared_key": hx(init_link.shared_key), "derived_key": hx(init_link.derived_key),
            "proof_signed_data": hx(signed), "proof_data": hx(proof_data),
            "iv": hx(iv), "plaintext": hx(plaintext), "ciphertext": hx(ct),
            "rtt": rtt, "rtt_ciphertext": hx(rtt_ct),
            "mtu_from_lr": RNS.Link.mtu_from_lr_packet(lr),
        })
    out["links"] = links
    out["signalling"] = [
        {"mtu": m, "mode": 1, "bytes": hx(RNS.Link.signalling_bytes(m, 1))} for m in (500, 1000, 8192, 16384, 262144, 2097151)
    ]
    out["keepalive"] = [
        {"rtt": r, "keepalive": max(min(r * (RNS.Link.KEEPALIVE_MAX / RNS.Link.KEEPALIVE_MAX_RTT), RNS.Link.KEEPALIVE_MAX), RNS.Link.KEEPALIVE_MIN)}
        for r in (0.001, 0.05, 0.5, 1.75, 10.0)
    ]

    # ---- request / response packing ----
    reqs = []
    for i, (path, data) in enumerate([
        ("/echo", b"\x01\x02"), ("/status", None), ("/get", {"a": 1, "b": [1, 2, b"x"]}),
        ("/long/path/name", "text"), ("/n", 12345678901),
    ]):
        ph = RNS.Identity.truncated_hash(path.encode("utf-8"))
        ts = 1700000000.25 + i
        packed = umsgpack.packb([ts, ph, data])
        body = det(f"req/body/{i}", 48 + 16 * i)
        raw = bytes([0x0C, 0x00]) + bytes.fromhex(links[1]["link_id"]) + bytes([RNS.Packet.REQUEST]) + body
        q = RNS.Packet(None, raw)
        assert q.unpack()
        rid = q.getTruncatedHash()
        resp = umsgpack.packb([rid, {"ok": True, "n": i}])
        reqs.append({
            "path": path, "path_hash": hx(ph), "timestamp": ts, "data": to_tree(data),
            "packed": hx(packed), "request_packet_raw": hx(raw), "request_id": hx(rid),
            "response_obj": to_tree({"ok": True, "n": i}), "packed_response": hx(resp),
        })
    out["requests"] = reqs

    # ---- resource ----
    RA = RNS.ResourceAdvertisement

    class FakeLink:
        type = RNS.Destination.LINK
        status = RNS.Link.ACTIVE
        rtt = 0.05
        traffic_timeout_factor = 6

        def __init__(self, mtu):
            self.mtu = mtu
            self.link_id = det("resource/linkid", 16)
            self.hash = self.link_id
            self.mdu = ((mtu - 1 - 19 - 48) // 16) * 16 - 1

        def encrypt(self, p):
            return p  # identity: advertisement/hashmap structure (not link crypto) is under test

    def make_resource(data, mtu, compress, label, **kw):
        fl = FakeLink(mtu)
        seq = iter([det(f"{label}/prefix", 16), det(f"{label}/rh", 16)])
        saved = RNS.Identity.get_random_hash
        RNS.Identity.get_random_hash = staticmethod(lambda: next(seq))
        try:
            res = RNS.Resource(data, fl, advertise=False, auto_compress=compress, **kw)
        finally:
            RNS.Identity.get_random_hash = saved
        return fl, res

    resources = []
    cases = [
        ("small_uncompressed", 1000, 500, False, "random"),
        ("multi_part_hmu", 60000, 500, False, "random"),
        ("compressible", 3000, 500, True, "text"),
        ("large_mtu_single_part", 5000, 16384, False, "random"),
    ]
    for name, n, mtu, compress, kind in cases:
        data = det(f"resource/{name}", n) if kind == "random" else (b"kestrel resource " * 400)[:n]
        fl, res = make_resource(data, mtu, compress, f"resource/{name}")
        adv = RA(res, mdu=fl.mdu)
        rec = {
            "name": name, "mtu": mtu, "link_mdu": fl.mdu, "auto_compress": compress,
            "data_sha256": hashlib.sha256(data).hexdigest(), "data": hx(data),
            "data_len": n,
            "random_prefix": hx(det(f"resource/{name}/prefix", 16)[:4]),
            "random_hash": hx(res.random_hash), "hash": hx(res.hash), "original_hash": hx(res.original_hash),
            "expected_proof": hx(res.expected_proof), "compressed": res.compressed,
            "size": res.size, "total_size": res.total_size, "sdu": res.sdu, "parts": [hx(p.data) for p in res.parts],
            "hashmap": hx(res.hashmap), "flags": adv.f, "adv": hx(adv.pack()),
        }
        if res.total_parts > RA.HASHMAP_MAX_LEN:
            rec["adv_segment_1"] = hx(adv.pack(segment=1))
            seg = RA.HASHMAP_MAX_LEN
            rec["hmu_segment_1"] = hx(res.hash + umsgpack.packb([1, res.hashmap[seg * 4:2 * seg * 4]]))
        resources.append(rec)
    out["resources"] = resources
    out["resource_constants"] = {
        "hashmap_max_len": RA.HASHMAP_MAX_LEN,
        "collision_guard_size": RA.COLLISION_GUARD_SIZE,
        "max_efficient_size": RNS.Resource.MAX_EFFICIENT_SIZE,
    }
    flagged = []
    for is_resp in (False, True):
        fl, res = make_resource(det("resource/flag/data", 600), 500, False, "resource/flag",
                                request_id=det("resource/flag/rid", 16), is_response=is_resp)
        adv = RA(res, mdu=fl.mdu)
        flagged.append({"is_response": is_resp, "request_id": hx(res.request_id), "flags": adv.f, "adv": hx(adv.pack())})
    out["resource_flagged"] = flagged
    out["bz2"] = [
        {"plain": hx(pl), "compressed": hx(bz2.compress(pl))}
        for pl in (b"a", det("bz2/random", 700), (b"abcabcabd" * 3000))
    ]

    write("network.json", out)


def main():
    gen_identity()
    gen_token()
    gen_vault()
    gen_destination()
    gen_packet()
    gen_announce()
    gen_hdlc()
    gen_kiss()
    gen_msgpack()
    gen_lxmf()
    gen_network()
    print(f"RNS {RNS.__version__ if hasattr(RNS, '__version__') else '?'}; LXMF {LXMF.__version__ if hasattr(LXMF, '__version__') else '?'}")


if __name__ == "__main__":
    main()
