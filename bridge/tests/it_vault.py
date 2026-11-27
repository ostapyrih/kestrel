"""Reference client-side crypto envelope of the vault (docs/bridge-protocol.md section 9.4), written against Python RNS.

Used by the integration helpers (and the unit tests) in the role of the app: the bridge never sees any of this.
"""
import RNS
import RNS.vendor.umsgpack as umsgpack
from RNS.Cryptography import Token, hkdf

SALT = b"kestrel-vault-v1"


def pack_chain(keys: dict) -> bytes:
    return umsgpack.packb({"v": 1, "keys": {str(e): k for e, k in sorted(keys.items())}})


def unpack_chain(data: bytes) -> dict:
    m = umsgpack.unpackb(data)
    assert m["v"] == 1
    return {int(e): bytes(k) for e, k in m["keys"].items()}


def wrap_identity(chain: dict, public_key: bytes) -> bytes:
    ident = RNS.Identity(create_keys=False)
    ident.load_public_key(public_key)
    return ident.encrypt(pack_chain(chain))


def unwrap_identity(wrapped: bytes, identity) -> dict:
    return unpack_chain(identity.decrypt(wrapped))


def invite_key(secret: bytes) -> bytes:
    return hkdf(length=64, derive_from=secret, salt=SALT, context=b"invite")


def wrap_invite(chain: dict, secret: bytes) -> bytes:
    return Token(invite_key(secret)).encrypt(pack_chain(chain))


def unwrap_invite(wrapped: bytes, secret: bytes) -> dict:
    return unpack_chain(Token(invite_key(secret)).decrypt(wrapped))


def epoch_key(group_key: bytes, epoch: int) -> bytes:
    return hkdf(length=64, derive_from=group_key, salt=SALT, context=b"epoch:%d" % epoch)


def encrypt_blob(group_key, blob_id, device_id, seq, epoch, kind, data, ts=1700000000.0) -> bytes:
    plain = umsgpack.packb({"v": 1, "blob_id": blob_id, "device_id": device_id, "seq": seq, "key_epoch": epoch,
                            "kind": kind, "ts": ts, "data": data})
    return Token(epoch_key(group_key, epoch)).encrypt(plain)


def decrypt_blob(chain: dict, meta: dict, ciphertext: bytes) -> dict:
    """Decrypts and checks the inner metadata against the outer one (the bridge's `meta`)."""
    plain = umsgpack.unpackb(Token(epoch_key(chain[meta["key_epoch"]], meta["key_epoch"])).decrypt(ciphertext))
    for k in ("blob_id", "device_id", "seq", "key_epoch"):
        if plain[k] != meta[k]:
            raise ValueError(f"blob metadata mismatch: {k}")
    return plain
