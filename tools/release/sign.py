#!/usr/bin/env python3
"""Sign a file with the Kestrel release Ed25519 key.

The private key (PKCS8 PEM) is read from the environment variable named by
--key-env (default RELEASE_SIGNING_KEY) or from --key-file. The output is the
raw 64-byte Ed25519 signature, base64 encoded, written to <file>.sig by default.
"""

from __future__ import annotations

import argparse
import base64
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def load_private_key(pem: bytes) -> Ed25519PrivateKey:
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("not an Ed25519 private key")
    return key


def public_key_b64(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    return base64.b64encode(raw).decode()


def sign_bytes(key: Ed25519PrivateKey, data: bytes) -> str:
    """Base64 of the raw 64-byte signature."""
    return base64.b64encode(key.sign(data)).decode()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("file", help="file to sign (e.g. SHA256SUMS.txt)")
    ap.add_argument("-o", "--out", help="output path (default: <file>.sig)")
    ap.add_argument("--key-env", default="RELEASE_SIGNING_KEY")
    ap.add_argument("--key-file", help="read the PEM key from a file instead")
    args = ap.parse_args(argv)

    if args.key_file:
        with open(args.key_file, "rb") as f:
            pem = f.read()
    else:
        value = os.environ.get(args.key_env)
        if not value:
            print(f"error: ${args.key_env} is not set", file=sys.stderr)
            return 2
        pem = value.encode()
    try:
        key = load_private_key(pem)
    except ValueError as e:
        print(f"error: bad signing key: {e}", file=sys.stderr)
        return 2

    with open(args.file, "rb") as f:
        data = f.read()
    out = args.out or args.file + ".sig"
    with open(out, "w", encoding="ascii", newline="") as f:
        f.write(sign_bytes(key, data) + "\n")
    print(f"signed {args.file} -> {out} (public key {public_key_b64(key)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
