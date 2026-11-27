"""Invite pairing (/devices/invite + /devices/redeem) and the /hello name/platform update."""
import unittest
from types import SimpleNamespace

from kestrel_bridge import errors
from kestrel_bridge.service import Ctx
from tests.helpers import PHONE_ID, RealDevice
from tests.test_devices import RpcLinkTest
from tests.test_service import ServiceBase


class InviteTest(ServiceBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.inviter = Ctx(device_id=PHONE_ID, transport="link")
        self.new = RealDevice()
        self.published.clear()

    async def invite(self):
        r = await self.call("/devices/invite", {}, self.inviter)
        self.assertTrue(r["ok"], r)
        return r["result"]

    def redeem(self, token, device=None, name="Windows PC", platform="windows", who="aa"):
        args = {"token": token, "name": name, "platform": platform}
        return self.svc.redeem_unknown(who, (device or self.new).public_key, args)

    async def test_invite_result(self):
        inv = await self.invite()
        self.assertEqual(len(inv["token"]), 16)
        self.assertIsInstance(inv["token"], bytes)
        self.assertEqual(len(inv["invite_id"]), 32)
        self.assertEqual(inv["expires_at"], self.clock() + self.cfg.limits.invite_ttl)
        # only a hash is kept
        self.assertNotIn(inv["token"], [k.encode() for k in self.svc.invites._invites])
        self.assertEqual(self.svc.invites.open_count(PHONE_ID), 1)

    async def test_valid_redeem(self):
        inv = await self.invite()
        r = await self.redeem(inv["token"])
        self.assertTrue(r["ok"], r)
        d = r["result"]["device"]
        self.assertEqual((d["device_id"], d["name"], d["platform"], d["added_by"], d["bootstrap"], d["roles"]),
                         (self.new.device_id, "Windows PC", "windows", PHONE_ID, False, []))
        self.assertIsNotNone(self.registry.trusted(self.new.device_id))
        added = [e for e in self.published if e["event"] == "device_added"]
        self.assertEqual(len(added), 1)
        self.assertEqual(added[0]["data"]["approved_by"], PHONE_ID)

    async def test_replay(self):
        inv = await self.invite()
        self.assertTrue((await self.redeem(inv["token"]))["ok"])
        other = RealDevice()
        r = await self.redeem(inv["token"], other)
        self.assertEqual(r["error"]["code"], errors.PAIRING_REPLAY)
        self.assertIsNone(self.registry.get(other.device_id))

    async def test_expired(self):
        inv = await self.invite()
        self.clock.advance(self.cfg.limits.invite_ttl + 1)
        r = await self.redeem(inv["token"])
        self.assertEqual(r["error"]["code"], errors.PAIRING_EXPIRED)
        self.assertIn("server_time", r["error"]["details"])
        self.assertIsNone(self.registry.get(self.new.device_id))

    async def test_wrong_or_malformed_token(self):
        await self.invite()
        for token in (b"\x00" * 16, b"short", "x" * 16, None):
            r = await self.redeem(token)
            self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID, token)
        self.assertIsNone(self.registry.get(self.new.device_id))

    async def test_failed_redeem_consumes_nothing(self):
        inv = await self.invite()
        r = await self.redeem(inv["token"], name="")
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)
        self.assertTrue((await self.redeem(inv["token"]))["ok"])

    async def test_invite_dies_with_a_revoked_inviter(self):
        other = RealDevice()
        self.registry.add(other.public_key, "other", "ios", [], PHONE_ID)
        r = await self.call("/devices/invite", {}, Ctx(device_id=other.device_id, transport="link"))
        self.registry.revoke(other.device_id, PHONE_ID)
        r = await self.redeem(r["result"]["token"])
        self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID)

    async def test_redeem_failures_are_rate_limited_per_identity(self):
        limit = self.cfg.limits.redeem_fail_rate_per_minute
        for _ in range(limit):
            self.assertEqual((await self.redeem(b"\x01" * 16, who="mallory"))["error"]["code"], errors.PAIRING_INVALID)
        self.assertEqual((await self.redeem(b"\x01" * 16, who="mallory"))["error"]["code"], errors.RATE_LIMITED)
        inv = await self.invite()
        self.assertEqual((await self.redeem(inv["token"], who="mallory"))["error"]["code"], errors.RATE_LIMITED)
        self.assertTrue((await self.redeem(inv["token"], who="alice"))["ok"])      # others are not affected
        self.clock.advance(61)                                                     # the window slides
        self.assertEqual((await self.redeem(b"\x01" * 16, who="mallory"))["error"]["code"], errors.PAIRING_INVALID)

    async def test_open_invite_limit_and_admin_rate_limit(self):
        for _ in range(self.cfg.limits.max_open_invites):
            await self.invite()
        r = await self.call("/devices/invite", {}, self.inviter)
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)
        self.clock.advance(self.cfg.limits.invite_ttl + 1)                         # expired invites do not count
        self.assertTrue((await self.call("/devices/invite", {}, self.inviter))["ok"])

    async def activate_vault(self):
        keys = {d.device_id: b"wrapped-" + d.device_id.encode()[:6] for d in self.registry.trusted_devices()}
        r = await self.call("/vault/set_keys", {"key_epoch": 1, "wrapped_group_keys": keys}, self.inviter)
        self.assertTrue(r["ok"], r)

    async def test_invite_without_vault_refuses_key_fields(self):
        for extra in ({"wrapped_group_key": b"k"}, {"key_epoch": 1}, {"key_epoch": 1, "wrapped_group_key": b"k"}):
            r = await self.call("/devices/invite", extra, self.inviter)
            self.assertEqual(r["error"]["code"], errors.BAD_REQUEST, extra)
        self.assertEqual(self.svc.invites.open_count(PHONE_ID), 0)
        inv = await self.invite()
        self.assertTrue((await self.redeem(inv["token"]))["ok"])
        k = (await self.call("/vault/key", {}, Ctx(device_id=self.new.device_id, transport="link")))["result"]
        self.assertEqual((k["wrapped_group_key"], k["wrap"]), (None, None))

    async def test_invite_with_vault_requires_epoch_and_wrapped_key(self):
        await self.activate_vault()
        for args in ({}, {"key_epoch": 1}, {"wrapped_group_key": b"w"}, {"key_epoch": 1, "wrapped_group_key": b""}):
            r = await self.call("/devices/invite", args, self.inviter)
            self.assertEqual(r["error"]["code"], errors.BAD_REQUEST, args)
        r = await self.call("/devices/invite", {"key_epoch": 5, "wrapped_group_key": b"w"}, self.inviter)
        self.assertEqual(r["error"]["code"], errors.KEY_EPOCH_STALE)
        self.assertEqual(r["error"]["details"]["key_epoch"], 1)
        self.assertEqual(self.svc.invites.open_count(PHONE_ID), 0)

    async def test_redeem_stores_the_invite_wrapped_key(self):
        await self.activate_vault()
        r = await self.call("/devices/invite", {"key_epoch": 1, "wrapped_group_key": b"chain-for-invite"}, self.inviter)
        self.assertTrue(r["ok"], r)
        self.assertNotIn(b"chain-for-invite", str(r).encode())
        r = await self.redeem(r["result"]["token"])
        self.assertTrue(r["ok"], r)
        k = (await self.call("/vault/key", {}, Ctx(device_id=self.new.device_id, transport="link")))["result"]
        self.assertEqual((k["wrapped_epoch"], k["wrapped_group_key"], k["wrap"], k["in_use"]),
                         (1, b"chain-for-invite", "invite", True))
        k = (await self.call("/vault/key", {}, self.inviter))["result"]
        self.assertEqual(k["wrap"], "identity")

    async def test_vault_activated_after_the_invite_was_made(self):
        inv = await self.invite()
        await self.activate_vault()
        r = await self.redeem(inv["token"])
        self.assertEqual(r["error"]["code"], errors.VAULT_IN_USE)
        self.assertIsNone(self.registry.get(self.new.device_id))

    async def test_revocation_invalidates_open_vault_invites(self):
        await self.activate_vault()
        victim = RealDevice()
        self.registry.add(victim.public_key, "old", "ios", [], PHONE_ID)
        self.svc.vault.store_device_key(victim.device_id, b"w")
        r = await self.call("/devices/invite", {"key_epoch": 1, "wrapped_group_key": b"chain"}, self.inviter)
        token = r["result"]["token"]
        r = await self.call("/devices/revoke", {"device_id": victim.device_id, "key_epoch": 2,
                                                "wrapped_group_keys": {PHONE_ID: b"n"}}, self.inviter)
        self.assertTrue(r["ok"], r)
        r = await self.redeem(token)
        self.assertEqual(r["error"]["code"], errors.KEY_EPOCH_STALE)
        self.assertEqual(r["error"]["details"]["key_epoch"], 2)
        self.assertIsNone(self.registry.get(self.new.device_id))
        r = await self.redeem(token)
        self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID)
        r = await self.call("/devices/invite", {"key_epoch": 2, "wrapped_group_key": b"chain2"}, self.inviter)
        self.assertTrue((await self.redeem(r["result"]["token"]))["ok"])

    async def test_hello_announces_vault_invite(self):
        r = await self.call("/hello", {"protocol_version": 2}, self.inviter)
        self.assertIn("vault_invite", r["result"]["capabilities"])

    async def test_trusted_and_unknown_callers_through_dispatch(self):
        inv = await self.invite()
        # a trusted device redeeming: already paired
        r = await self.call("/devices/redeem", {"token": inv["token"], "name": "x", "platform": "ios"}, self.inviter)
        self.assertEqual(r["error"]["code"], errors.DEVICE_EXISTS)
        # an unknown device id cannot use the normal dispatcher at all
        r = await self.call("/devices/redeem", {"token": inv["token"], "name": "x", "platform": "ios"},
                            Ctx(device_id=self.new.device_id, transport="link"))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)
        r = await self.call("/devices/invite", {}, Ctx(device_id=self.new.device_id, transport="link"))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)
        # over LXMF: link only
        r = await self.call("/devices/invite", {}, Ctx(device_id=PHONE_ID, transport="lxmf"))
        self.assertEqual(r["error"]["code"], errors.UNSUPPORTED_TRANSPORT)

    async def test_capability_and_limit_advertised(self):
        r = await self.call("/hello", {"protocol_version": 2}, self.inviter)
        self.assertIn("pairing_invite", r["result"]["capabilities"])
        self.assertEqual(r["result"]["limits"]["invite_ttl"], self.cfg.limits.invite_ttl)


class HelloIdentityTest(ServiceBase):
    async def hello(self, **extra):
        return await self.call("/hello", {"protocol_version": 2, **extra}, Ctx(device_id=PHONE_ID, transport="link"))

    async def test_name_and_platform_update_the_own_record(self):
        self.published.clear()
        r = await self.hello(name="Windows PC", platform="windows")
        self.assertEqual((r["result"]["device"]["name"], r["result"]["device"]["platform"]), ("Windows PC", "windows"))
        self.assertEqual(self.registry.get(PHONE_ID).name, "Windows PC")
        self.assertEqual([e["event"] for e in self.published], ["device_updated"])
        self.published.clear()
        await self.hello(name="Windows PC", platform="windows")        # unchanged: no event
        self.assertEqual(self.published, [])
        r = await self.hello(name="Renamed")                           # only the name
        self.assertEqual((r["result"]["device"]["name"], r["result"]["device"]["platform"]), ("Renamed", "windows"))

    async def test_plain_hello_changes_nothing(self):
        before = self.registry.get(PHONE_ID)
        await self.hello()
        after = self.registry.get(PHONE_ID)
        self.assertEqual((after.name, after.platform), (before.name, before.platform))

    async def test_invalid_values_are_refused(self):
        before = self.registry.get(PHONE_ID)
        before = (before.name, before.platform)
        for extra in ({"name": ""}, {"name": 5}, {"platform": "Windows 11"}, {"name": "x" * 65}):
            self.assertEqual((await self.hello(**extra))["error"]["code"], errors.BAD_REQUEST, extra)
        after = self.registry.get(PHONE_ID)
        self.assertEqual((after.name, after.platform), before)


class RedeemLinkTest(RpcLinkTest):
    """The RPC layer: an unknown key may call only /devices/redeem; success turns the Link into a trusted one."""

    def stranger_link(self, n=9):
        self.cfg.limits.reject_grace = 0.2
        stranger = RealDevice()
        link, torn = self.add_link(None, n)
        ident = SimpleNamespace(get_public_key=lambda: bytes.fromhex(stranger.public_key), hash=bytes(16))
        self.rpc._remote_identified(link, ident)
        return stranger, link, torn, ident

    def test_unknown_key_may_call_nothing_but_redeem(self):
        stranger, link, torn, ident = self.stranger_link()
        for path in ("/hello", "/devices/invite", "/devices/list", "/subscribe", "/sync_chats"):
            r = self.rpc._handle(path, {}, link.link_id, ident)
            self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED, path)
        self.assertEqual(len(self.sent[9]), 1)                  # only the reject packet, no data

    def test_redeem_success_promotes_the_link(self):
        self.cfg.limits.reject_grace = 0.2
        inv = self.svc.invites.create(self.registry.trusted_devices()[0].device_id)
        stranger, link, torn, ident = self.stranger_link()
        r = self.rpc._handle("/devices/redeem", {"token": inv["token"], "name": "Mac", "platform": "macos"},
                             link.link_id, ident)
        self.assertTrue(r["ok"], r)
        import time
        time.sleep(0.5)                                         # longer than the reject grace: the Link stays
        self.assertEqual(torn, [])
        st = self.rpc._links[link.link_id]
        self.assertEqual(st.device_id, stranger.device_id)
        r = self.rpc._handle("/hello", {"protocol_version": 2}, link.link_id, ident)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["device"]["name"], "Mac")

    def test_redeem_failure_answers_then_closes(self):
        stranger, link, torn, ident = self.stranger_link()
        r = self.rpc._handle("/devices/redeem", {"token": b"\x00" * 16, "name": "x", "platform": "ios"},
                             link.link_id, ident)
        self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID)
        self.assertEqual(torn, [])                              # the response is not cut off
        self.assertTrue(self.wait_for(lambda: torn == [9], 5))
        self.assertIsNone(self.registry.get(stranger.device_id))

    def test_revoked_key_cannot_redeem(self):
        inv = self.svc.invites.create(self.registry.trusted_devices()[0].device_id)
        self.registry.revoke(self.second.device_id, PHONE_ID)
        link, torn = self.add_link(None, 8)
        ident = SimpleNamespace(get_public_key=lambda: bytes.fromhex(self.second.public_key), hash=bytes(16))
        r = self.rpc._handle("/devices/redeem", {"token": inv["token"], "name": "x", "platform": "ios"},
                             link.link_id, ident)
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)
        self.assertEqual(self.svc.invites.open_count(PHONE_ID), 1)      # not consumed


for _n in [n for n in dir(RpcLinkTest) if n.startswith("test_")]:
    setattr(RedeemLinkTest, _n, None)      # the inherited tests run in test_devices; only the new ones here
del RpcLinkTest

if __name__ == "__main__":
    unittest.main()
