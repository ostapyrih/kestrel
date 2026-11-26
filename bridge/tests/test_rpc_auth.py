import unittest
from types import SimpleNamespace

from kestrel_bridge.rpc import device_of
from tests.helpers import OTHER_KEY, PHONE_ID, PHONE_KEY, make_registry, raw_config


def ident(key_hex):
    return SimpleNamespace(get_public_key=lambda: bytes.fromhex(key_hex))


class DeviceOfTest(unittest.TestCase):
    def setUp(self):
        self.state, self.reg = make_registry(raw_config())
        self.addCleanup(self.state.close)

    def test_trusted(self):
        self.assertEqual(device_of(ident(PHONE_KEY), self.reg).device_id, PHONE_ID)

    def test_unknown_key_rejected(self):
        self.assertIsNone(device_of(ident(OTHER_KEY), self.reg))

    def test_revoked_key_rejected(self):
        self.reg.add(OTHER_KEY, "second", "ios", [], PHONE_ID)
        self.assertIsNotNone(device_of(ident(OTHER_KEY), self.reg))
        self.reg.revoke(device_of(ident(OTHER_KEY), self.reg).device_id, PHONE_ID)
        self.assertIsNone(device_of(ident(OTHER_KEY), self.reg))

    def test_unidentified_rejected(self):
        self.assertIsNone(device_of(None, self.reg))

    def test_broken_identity_rejected(self):
        def boom():
            raise ValueError
        self.assertIsNone(device_of(SimpleNamespace(get_public_key=boom), self.reg))

    def test_identity_hash_alone_is_not_enough(self):
        # the registry holds FULL public keys; a 16-byte identity hash must never match
        short = SimpleNamespace(get_public_key=lambda: bytes.fromhex(PHONE_KEY)[:16])
        self.assertIsNone(device_of(short, self.reg))


if __name__ == "__main__":
    unittest.main()
