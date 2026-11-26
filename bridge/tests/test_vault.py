"""Vault storage, group-key epochs and the reference client-side crypto envelope (protocol v2)."""
import os
import unittest

from kestrel_bridge import codec, errors
from kestrel_bridge.service import Ctx
from tests.helpers import PHONE_ID, RealDevice
from tests.test_devices import approve_args, make_pairing
from tests.test_service import ServiceBase


def blob_id() -> str:
    return os.urandom(16).hex()


class VaultBase(ServiceBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.d1 = Ctx(device_id=PHONE_ID, transport="link")
        self.dev2 = RealDevice()
        self.registry.add(self.dev2.public_key, "tablet", "ios", [], PHONE_ID)
        self.d2 = Ctx(device_id=self.dev2.device_id, transport="link")
        self.published.clear()

    def put_args(self, device_id=PHONE_ID, seq=1, data=b"opaque", epoch=1, bid=None):
        return {"blob_id": bid or blob_id(), "device_id": device_id, "seq": seq, "key_epoch": epoch,
                "ciphertext": data}

    async def put(self, ctx=None, **kw):
        args = self.put_args(**{"device_id": (ctx or self.d1).device_id, **kw})
        return args, await self.call("/vault/put", args, ctx or self.d1)

    async def activate(self):
        keys = {d.device_id: b"wrapped-" + d.device_id.encode()[:6] for d in self.registry.trusted_devices()}
        r = await self.call("/vault/set_keys", {"key_epoch": 1, "wrapped_group_keys": keys}, self.d1)
        self.assertTrue(r["ok"], r)
        return keys


class VaultBlobTest(VaultBase):
    async def test_put_list_get_round_trip(self):
        args, r = await self.put(data=b"\x00\x01ciphertext" * 10)
        self.assertTrue(r["ok"], r)
        m = r["result"]
        self.assertEqual((m["blob_id"], m["device_id"], m["seq"], m["key_epoch"], m["size"], m["duplicate"]),
                         (args["blob_id"], PHONE_ID, 1, 1, 120, False))
        self.assertEqual(m["vcursor"], 1)
        self.assertEqual(len(m["sha256"]), 64)
        # another device lists and fetches it
        r = (await self.call("/vault/list", {}, self.d2))["result"]
        self.assertEqual([b["blob_id"] for b in r["blobs"]], [args["blob_id"]])
        self.assertNotIn("ciphertext", r["blobs"][0])                 # list is metadata only
        self.assertEqual((r["cursor"], r["more"], r["key_epoch"]), (1, False, 1))
        r = (await self.call("/vault/get", {"blob_ids": [args["blob_id"], "00" * 16]}, self.d2))["result"]
        self.assertEqual(r["blobs"][0]["ciphertext"], args["ciphertext"])
        self.assertEqual((r["missing"], r["truncated"]), (["00" * 16], []))

    async def test_put_is_idempotent_for_retries_and_rejects_conflicts(self):
        args, r = await self.put(seq=1)
        again = await self.call("/vault/put", args, self.d1)             # the response was lost, client retries
        self.assertTrue(again["ok"], again)
        self.assertTrue(again["result"]["duplicate"])
        self.assertEqual(again["result"]["vcursor"], r["result"]["vcursor"])
        self.assertEqual(self.state.query("SELECT COUNT(*) FROM vault_blobs")[0][0], 1)
        # same blob_id, different content / different seq: refused
        for patch in ({"ciphertext": b"other"}, {"seq": 2}):
            r = await self.call("/vault/put", {**args, **patch}, self.d1)
            self.assertEqual(r["error"]["code"], errors.BLOB_CONFLICT, patch)

    async def test_seq_must_follow_the_last_one_of_the_device(self):
        await self.put(seq=1)
        _, r = await self.put(seq=3)                                       # gap
        self.assertEqual((r["error"]["code"], r["error"]["details"]["last_seq"]), (errors.SEQ_CONFLICT, 1))
        _, r = await self.put(seq=1)                                       # reuse with a new blob_id
        self.assertEqual(r["error"]["code"], errors.SEQ_CONFLICT)
        _, r = await self.put(seq=2)
        self.assertTrue(r["ok"])
        _, r = await self.put(self.d2, seq=1)                              # seq is per device
        self.assertTrue(r["ok"])

    async def test_only_the_owner_uploads(self):
        _, r = await self.put(device_id=self.dev2.device_id)               # d1 uploads in the name of d2
        self.assertEqual(r["error"]["code"], errors.FORBIDDEN)
        r = await self.call("/vault/put", {**self.put_args(), "device_id": None}, self.d1)
        self.assertEqual(r["error"]["code"], errors.FORBIDDEN)

    async def test_validation(self):
        base = self.put_args()
        for patch in ({"blob_id": "xyz"}, {"blob_id": "AB" * 16}, {"seq": 0}, {"seq": "1"}, {"seq": True},
                      {"key_epoch": 0}, {"ciphertext": b""}, {"ciphertext": "text"}, {"ciphertext": None}):
            r = await self.call("/vault/put", {**base, **patch}, self.d1)
            self.assertEqual(r["error"]["code"], errors.BAD_REQUEST, patch)

    async def test_size_limit(self):
        self.cfg.limits.vault_max_blob_bytes = 1024
        _, r = await self.put(data=b"x" * 1025)
        self.assertEqual((r["error"]["code"], r["error"]["details"]["max"]), (errors.BLOB_TOO_LARGE, 1024))
        _, r = await self.put(data=b"x" * 1024)
        self.assertTrue(r["ok"])

    async def test_device_quota(self):
        self.cfg.limits.vault_device_quota_bytes = 2500
        for seq in (1, 2):
            _, r = await self.put(seq=seq, data=b"x" * 1000)
            self.assertTrue(r["ok"])
        _, r = await self.put(seq=3, data=b"x" * 1000)
        d = r["error"]["details"]
        self.assertEqual((r["error"]["code"], d["scope"], d["used"], d["quota"]), (errors.QUOTA_EXCEEDED, "device", 2000, 2500))
        _, r = await self.put(seq=3, data=b"x" * 500)                      # exactly at the quota is fine
        self.assertTrue(r["ok"])
        _, r = await self.put(self.d2, seq=1, data=b"x" * 1000)            # other devices have their own quota
        self.assertTrue(r["ok"])
        self.assertEqual(self.svc.vault.usage(PHONE_ID), 2500)

    async def test_total_quota(self):
        self.cfg.limits.vault_total_quota_bytes = 1500
        _, r = await self.put(seq=1, data=b"x" * 1000)
        self.assertTrue(r["ok"])
        _, r = await self.put(self.d2, seq=1, data=b"x" * 600)
        self.assertEqual((r["error"]["code"], r["error"]["details"]["scope"]), (errors.QUOTA_EXCEEDED, "total"))

    async def test_a_rejected_put_stores_nothing(self):
        self.cfg.limits.vault_device_quota_bytes = 10
        await self.put(data=b"x" * 11)
        self.assertEqual(self.state.query("SELECT COUNT(*) FROM vault_blobs")[0][0], 0)

    async def test_list_cursor_paging_and_filter(self):
        ids = []
        for seq in range(1, 6):
            args, _ = await self.put(self.d1, seq=seq, data=f"d1-{seq}".encode())
            ids.append(args["blob_id"])
            args, _ = await self.put(self.d2, seq=seq, data=f"d2-{seq}".encode())
            ids.append(args["blob_id"])
        got, cursor, pages = [], 0, 0
        while True:
            r = (await self.call("/vault/list", {"cursor": cursor, "limit": 3}, self.d2))["result"]
            got += [b["blob_id"] for b in r["blobs"]]
            self.assertGreaterEqual(r["cursor"], cursor)
            cursor, pages = r["cursor"], pages + 1
            if not r["more"]:
                break
        self.assertEqual(got, ids)                       # upload order, no gaps, no repeats
        self.assertEqual(pages, 4)
        r = (await self.call("/vault/list", {"cursor": cursor}, self.d1))["result"]
        self.assertEqual((r["blobs"], r["cursor"], r["more"]), ([], cursor, False))   # up to date: cursor kept
        r = (await self.call("/vault/list", {"device_id": PHONE_ID}, self.d2))["result"]
        self.assertEqual([b["seq"] for b in r["blobs"]], [1, 2, 3, 4, 5])
        # a device that was offline resumes with its old cursor
        await self.put(self.d1, seq=6)
        r = (await self.call("/vault/list", {"cursor": cursor}, self.d2))["result"]
        self.assertEqual([(b["device_id"], b["seq"]) for b in r["blobs"]], [(PHONE_ID, 6)])
        for bad in ({"cursor": -1}, {"limit": 0}, {"device_id": "zz"}):
            self.assertEqual((await self.call("/vault/list", bad, self.d2))["error"]["code"], errors.BAD_REQUEST)

    async def test_get_limits_and_budget(self):
        a, _ = await self.put(seq=1, data=b"a" * 100_000)
        b, _ = await self.put(seq=2, data=b"b" * 100_000)
        c, _ = await self.put(seq=3, data=b"c" * 100)
        ids = [a["blob_id"], b["blob_id"], c["blob_id"]]
        r = (await self.call("/vault/get", {"blob_ids": ids}, self.d2))["result"]
        self.assertEqual([x["blob_id"] for x in r["blobs"]], [a["blob_id"], b["blob_id"], c["blob_id"]])
        self.cfg.limits.max_response_bytes = 150_000
        r = (await self.call("/vault/get", {"blob_ids": ids}, self.d2))["result"]
        self.assertEqual([x["blob_id"] for x in r["blobs"]], [a["blob_id"], c["blob_id"]])
        self.assertEqual(r["truncated"], [b["blob_id"]])                     # ask again with fewer ids
        self.cfg.limits.vault_get_max_ids = 2
        for bad in ({"blob_ids": ids}, {"blob_ids": []}, {"blob_ids": ["zz"]}, {"blob_ids": "x"}, {}):
            self.assertEqual((await self.call("/vault/get", bad, self.d2))["error"]["code"], errors.BAD_REQUEST)

    async def test_rate_limit_link_only_and_push(self):
        self.cfg.limits.vault_put_rate_per_minute = 2
        await self.put(seq=1)
        await self.put(seq=2)
        _, r = await self.put(seq=3)
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)
        ev = [e for e in self.published if e["event"] == "vault.blob"]
        self.assertEqual(len(ev), 2)
        self.assertEqual(set(ev[0]["data"]), {"blob_id", "device_id", "seq", "key_epoch", "size", "vcursor"})
        self.assertNotIn("ciphertext", ev[0]["data"])
        lx = Ctx(device_id=PHONE_ID, transport="lxmf", journal_reserved=True)
        for path in ("/vault/put", "/vault/list", "/vault/get", "/vault/key", "/vault/set_keys"):
            self.assertEqual((await self.call(path, {}, lx))["error"]["code"], errors.UNSUPPORTED_TRANSPORT, path)

    async def test_duplicate_put_pushes_nothing(self):
        args, _ = await self.put()
        await self.call("/vault/put", args, self.d1)
        self.assertEqual(len([e for e in self.published if e["event"] == "vault.blob"]), 1)

    async def test_revoked_device_data_stays_but_it_cannot_upload(self):
        await self.put(self.d2, seq=1)
        await self.call("/devices/revoke", {"device_id": self.dev2.device_id}, self.d1)
        _, r = await self.put(self.d2, seq=2, epoch=2)
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)
        r = (await self.call("/vault/list", {}, self.d1))["result"]
        self.assertEqual(len(r["blobs"]), 1)


class VaultEpochTest(VaultBase):
    async def test_epoch_starts_at_one_and_uploads_must_match(self):
        r = (await self.call("/hello", {"protocol_version": 2}, self.d1))["result"]["vault"]
        self.assertEqual((r["key_epoch"], r["in_use"]), (1, False))
        _, r = await self.put(epoch=2)
        self.assertEqual((r["error"]["code"], r["error"]["details"]["key_epoch"]), (errors.KEY_EPOCH_STALE, 1))

    async def test_set_keys_activates_the_vault(self):
        r = (await self.call("/vault/key", {}, self.d1))["result"]
        self.assertEqual((r["key_epoch"], r["in_use"], r["wrapped_group_key"]), (1, False, None))
        keys = await self.activate()
        for ctx, dev in ((self.d1, PHONE_ID), (self.d2, self.dev2.device_id)):
            r = (await self.call("/vault/key", {}, ctx))["result"]
            self.assertEqual((r["key_epoch"], r["in_use"], r["wrapped_epoch"], r["wrapped_group_key"]),
                             (1, True, 1, keys[dev]))
        r = await self.call("/vault/set_keys", {"key_epoch": 1, "wrapped_group_keys": keys}, self.d1)
        self.assertEqual(r["error"]["code"], errors.KEYS_ALREADY_SET)

    async def test_set_keys_validation(self):
        both = {PHONE_ID: b"a", self.dev2.device_id: b"b"}
        cases = [
            ({"key_epoch": 1, "wrapped_group_keys": {PHONE_ID: b"a"}}, errors.BAD_REQUEST),            # incomplete
            ({"key_epoch": 1, "wrapped_group_keys": {**both, "00" * 16: b"c"}}, errors.BAD_REQUEST),   # unknown device
            ({"key_epoch": 1, "wrapped_group_keys": {PHONE_ID: b"a", self.dev2.device_id: "str"}}, errors.BAD_REQUEST),
            ({"key_epoch": 1, "wrapped_group_keys": {PHONE_ID: b"a", self.dev2.device_id: b"x" * 5000}}, errors.BAD_REQUEST),
            ({"key_epoch": 1, "wrapped_group_keys": [1]}, errors.BAD_REQUEST),
            ({"key_epoch": 2, "wrapped_group_keys": both}, errors.KEY_EPOCH_STALE),
            ({"wrapped_group_keys": both}, errors.BAD_REQUEST),
        ]
        for args, code in cases:
            self.assertEqual((await self.call("/vault/set_keys", args, self.d1))["error"]["code"], code, args)
        self.assertFalse(self.svc.vault.in_use())
        inc = (await self.call("/vault/set_keys", cases[0][0], self.d1))["error"]["details"]
        self.assertEqual(inc["missing"], [self.dev2.device_id])

    async def test_revocation_bumps_the_epoch_and_rotates_keys(self):
        await self.activate()
        third = RealDevice()
        self.registry.add(third.public_key, "laptop", "linux", [], PHONE_ID)
        self.svc.vault.store_device_key(third.device_id, b"wrapped-third")
        # the vault is in use: the revoking device must supply keys for the new epoch for everybody remaining
        r = await self.call("/devices/revoke", {"device_id": self.dev2.device_id}, self.d1)
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)
        remaining = {PHONE_ID: b"new-1", third.device_id: b"new-3"}
        for args in ({"key_epoch": 1, "wrapped_group_keys": remaining}, {"key_epoch": 3, "wrapped_group_keys": remaining},
                     {"key_epoch": 2, "wrapped_group_keys": {PHONE_ID: b"new-1"}},
                     {"key_epoch": 2, "wrapped_group_keys": {**remaining, self.dev2.device_id: b"old"}}):
            r = await self.call("/devices/revoke", {"device_id": self.dev2.device_id, **args}, self.d1)
            self.assertFalse(r["ok"], args)
        self.assertIsNotNone(self.registry.trusted(self.dev2.device_id))     # nothing happened
        self.assertEqual(self.svc.vault.epoch(), 1)
        r = await self.call("/devices/revoke", {"device_id": self.dev2.device_id, "key_epoch": 2,
                                                "wrapped_group_keys": remaining}, self.d1)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["key_epoch"], 2)
        self.assertEqual(self.svc.vault.epoch(), 2)
        self.assertEqual(self.svc.vault.keys_epoch(), 2)
        k = (await self.call("/vault/key", {}, self.d1))["result"]
        self.assertEqual((k["key_epoch"], k["wrapped_epoch"], k["wrapped_group_key"]), (2, 2, b"new-1"))
        k = (await self.call("/vault/key", {}, Ctx(device_id=third.device_id, transport="link")))["result"]
        self.assertEqual(k["wrapped_group_key"], b"new-3")
        self.assertEqual(self.state.query("SELECT COUNT(*) FROM device_keys")[0][0], 2)    # revoked device's key gone
        # blobs of the old epoch are refused, the new epoch is accepted
        _, r = await self.put(seq=1, epoch=1)
        self.assertEqual(r["error"]["code"], errors.KEY_EPOCH_STALE)
        _, r = await self.put(seq=1, epoch=2)
        self.assertTrue(r["ok"])

    async def test_revocation_without_vault_just_bumps_the_epoch(self):
        r = await self.call("/devices/revoke", {"device_id": self.dev2.device_id}, self.d1)
        self.assertEqual(r["result"]["key_epoch"], 2)
        self.assertFalse(self.svc.vault.in_use())
        third = RealDevice()
        self.registry.add(third.public_key, "laptop", "linux", [], PHONE_ID)
        r = await self.call("/devices/revoke", {"device_id": third.device_id, "wrapped_group_keys": {PHONE_ID: b"k"},
                                                "key_epoch": 3}, self.d1)
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)         # nothing to rotate yet

    async def test_pairing_hands_over_the_wrapped_group_key(self):
        approver = RealDevice()
        self.registry.add(approver.public_key, "approver", "android", [], PHONE_ID)
        actx = Ctx(device_id=approver.device_id, transport="link")
        newdev = RealDevice()
        # vault not in use: no key may be passed
        r = await self.call("/devices/approve", approve_args(approver, make_pairing(newdev, self.clock),
                                                             wrapped_group_key=b"k", key_epoch=1), actx)
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)
        await self.activate_with(approver)
        # now it is mandatory, and for the current epoch
        pay = make_pairing(newdev, self.clock)
        r = await self.call("/devices/approve", approve_args(approver, pay), actx)
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)
        r = await self.call("/devices/approve", approve_args(approver, pay, wrapped_group_key=b"k", key_epoch=7), actx)
        self.assertEqual(r["error"]["code"], errors.KEY_EPOCH_STALE)
        self.assertIsNone(self.registry.get(newdev.device_id))
        r = await self.call("/devices/approve", approve_args(approver, pay, wrapped_group_key=b"wrapped-for-new",
                                                             key_epoch=1), actx)
        self.assertTrue(r["ok"], r)
        k = (await self.call("/vault/key", {}, Ctx(device_id=newdev.device_id, transport="link")))["result"]
        self.assertEqual((k["wrapped_epoch"], k["wrapped_group_key"]), (1, b"wrapped-for-new"))

    async def activate_with(self, approver):
        keys = {d.device_id: b"w" for d in self.registry.trusted_devices()}
        r = await self.call("/vault/set_keys", {"key_epoch": 1, "wrapped_group_keys": keys}, self.d1)
        self.assertTrue(r["ok"], r)


class VaultCryptoEnvelopeTest(unittest.TestCase):
    """The reference client-side envelope of docs/bridge-protocol.md section 8, with the real RNS primitives."""

    SALT = b"kestrel-vault-v1"

    @staticmethod
    def epoch_key(group_key: bytes, epoch: int) -> bytes:
        from RNS.Cryptography import hkdf
        return hkdf(length=64, derive_from=group_key, salt=VaultCryptoEnvelopeTest.SALT,
                    context=b"epoch:%d" % epoch)

    def test_group_key_wrap_and_blob_round_trip(self):
        import RNS
        from RNS.Cryptography import Token
        new_device = RNS.Identity()
        group_key = os.urandom(32)
        # approving device: wrap the key chain to the new device's identity
        pub_only = RNS.Identity(create_keys=False)
        pub_only.load_public_key(new_device.get_public_key())
        wrapped = pub_only.encrypt(codec.pack({"v": 1, "keys": {"1": group_key}}))
        # new device: unwrap
        chain = codec.unpack(new_device.decrypt(wrapped))
        self.assertEqual(chain["keys"]["1"], group_key)
        # blob: msgpack record bound to its metadata, Token with the per-epoch key
        record = codec.pack({"v": 1, "blob_id": "ab" * 16, "device_id": "cd" * 16, "seq": 1, "key_epoch": 1,
                             "kind": "messages", "ts": 1.0, "data": {"hello": "world"}})
        ciphertext = Token(self.epoch_key(group_key, 1)).encrypt(record)
        self.assertEqual(Token(self.epoch_key(chain["keys"]["1"], 1)).decrypt(ciphertext), record)
        with self.assertRaises(Exception):                              # another epoch's key cannot read it
            Token(self.epoch_key(group_key, 2)).decrypt(ciphertext)
        self.assertIsNone(RNS.Identity().decrypt(wrapped))             # a stranger cannot unwrap the group key


if __name__ == "__main__":
    unittest.main()
