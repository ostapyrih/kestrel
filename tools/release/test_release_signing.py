"""Tests for sign.py / verify.py. Run: python -m unittest discover -s tools/release"""

import base64
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sign  # noqa: E402
import verify  # noqa: E402


def make_key():
    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return key, pem


class SigningTest(unittest.TestCase):
    def test_roundtrip_and_tamper(self):
        key, _ = make_key()
        pub = sign.public_key_b64(key)
        sig = sign.sign_bytes(key, b"abc")
        self.assertEqual(len(base64.b64decode(sig)), 64)
        self.assertTrue(verify.verify_bytes(pub, b"abc", sig))
        self.assertFalse(verify.verify_bytes(pub, b"abd", sig))
        other, _ = make_key()
        self.assertFalse(verify.verify_bytes(sign.public_key_b64(other), b"abc", sig))
        self.assertFalse(verify.verify_bytes(pub, b"abc", "not base64!"))
        short = base64.b64encode(b"short").decode()
        self.assertFalse(verify.verify_bytes(pub, b"abc", short))

    def test_cli_sign_then_verify_files(self):
        key, pem = make_key()
        pub = sign.public_key_b64(key)
        with tempfile.TemporaryDirectory() as d:
            art = os.path.join(d, "kestrel-1.0.0.zip")
            with open(art, "wb") as f:
                f.write(b"payload")
            sums = os.path.join(d, "SHA256SUMS.txt")
            with open(sums, "w") as f:
                f.write(f"{hashlib.sha256(b'payload').hexdigest()}  kestrel-1.0.0.zip\n")
            env = dict(os.environ, RELEASE_SIGNING_KEY=pem.decode())
            r = subprocess.run(
                [sys.executable, os.path.join(HERE, "sign.py"), sums],
                env=env, capture_output=True, text=True,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            sig_path = sums + ".sig"
            ok = [sums, sig_path, "--public-key", pub, "--check-files", d]
            self.assertEqual(verify.main(ok), 0)
            with open(art, "wb") as f:
                f.write(b"tampered")
            self.assertEqual(verify.main(ok), 1)
            other, _ = make_key()
            wrong = [sums, sig_path, "--public-key", sign.public_key_b64(other)]
            self.assertEqual(verify.main(wrong), 1)

    def test_missing_key(self):
        env = {k: v for k, v in os.environ.items() if k != "RELEASE_SIGNING_KEY"}
        r = subprocess.run(
            [sys.executable, os.path.join(HERE, "sign.py"), __file__],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
