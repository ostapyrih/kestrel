import unittest
from types import SimpleNamespace

from kestrel_bridge.rpc import phone_of
from tests.helpers import OTHER_KEY, PHONE_KEY


def ident(key_hex):
    return SimpleNamespace(get_public_key=lambda: bytes.fromhex(key_hex))


class PhoneOfTest(unittest.TestCase):
    wl = frozenset({PHONE_KEY})

    def test_whitelisted(self):
        self.assertEqual(phone_of(ident(PHONE_KEY), self.wl), PHONE_KEY)

    def test_unknown_key_rejected(self):
        self.assertIsNone(phone_of(ident(OTHER_KEY), self.wl))

    def test_unidentified_rejected(self):
        self.assertIsNone(phone_of(None, self.wl))

    def test_broken_identity_rejected(self):
        def boom():
            raise ValueError
        self.assertIsNone(phone_of(SimpleNamespace(get_public_key=boom), self.wl))

    def test_identity_hash_alone_is_not_enough(self):
        # the whitelist holds FULL public keys; a 16-byte identity hash must never match
        short = SimpleNamespace(get_public_key=lambda: bytes.fromhex(PHONE_KEY)[:16])
        self.assertIsNone(phone_of(short, self.wl))


if __name__ == "__main__":
    unittest.main()
