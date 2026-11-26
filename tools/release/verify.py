#!/usr/bin/env python3
"""Verify a Kestrel release signature (and optionally the artifacts it covers).

    python tools/release/verify.py SHA256SUMS.txt SHA256SUMS.txt.sig
    python tools/release/verify.py SHA256SUMS.txt SHA256SUMS.txt.sig --check-files DIR

The signature is the base64 of a raw Ed25519 signature over the exact bytes of
SHA256SUMS.txt. With --check-files every listed file found in DIR must match its
SHA-256 (listed files missing from DIR are reported but not fatal).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import os
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

# Release signing public key (raw 32 bytes, base64). Same value as in
# app/lib/update/release_key.dart.
PUBLIC_KEY_B64 = "GeeSuwmBoGEsCARLxFniM3qIlf2w2htnnGT7wYeH7as="


def verify_bytes(public_key_b64: str, data: bytes, sig_b64: str) -> bool:
    try:
        pub = Ed25519PublicKey.from_public_bytes(
            base64.b64decode(public_key_b64, validate=True)
        )
        sig = base64.b64decode(sig_b64.strip(), validate=True)
        if len(sig) != 64:
            return False
        pub.verify(sig, data)
        return True
    except (InvalidSignature, ValueError, binascii.Error):
        return False


def parse_sums(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        digest, _, name = line.partition("  ")
        out[name.lstrip("*")] = digest.lower()
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("file")
    ap.add_argument("sig")
    ap.add_argument(
        "--public-key", default=PUBLIC_KEY_B64, help="base64 raw Ed25519 public key"
    )
    ap.add_argument("--check-files", metavar="DIR")
    args = ap.parse_args(argv)

    with open(args.file, "rb") as f:
        data = f.read()
    with open(args.sig, encoding="ascii") as f:
        sig = f.read()
    if not verify_bytes(args.public_key, data, sig):
        print("BAD SIGNATURE", file=sys.stderr)
        return 1
    print(f"signature OK: {args.file}")

    if args.check_files:
        bad = 0
        for name, digest in parse_sums(data.decode()).items():
            path = os.path.join(args.check_files, name)
            if not os.path.isfile(path):
                print(f"skip (not present): {name}")
                continue
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            if h.hexdigest() == digest:
                print(f"OK  {name}")
            else:
                print(f"MISMATCH  {name}", file=sys.stderr)
                bad += 1
        if bad:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
