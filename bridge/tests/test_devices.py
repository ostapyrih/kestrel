"""Device registry, QR pairing, revocation, bootstrap precedence (protocol v2)."""
import os
import tempfile
import threading
import unittest
from types import SimpleNamespace

from kestrel_bridge import codec, errors
from kestrel_bridge.devices import (DeviceRegistry, decode_pairing_qr, device_id_of, encode_pairing_qr,
                                    pairing_sign_message)
from kestrel_bridge.config import DeviceSeed
from kestrel_bridge.service import Ctx
from kestrel_bridge.state import State
from tests.helpers import OTHER_KEY, PHONE_ID, PHONE_KEY, FakeClock, RealDevice, make_registry, raw_config
from tests.test_service import ServiceBase


class RegistryTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock(1000.0)
        self.cfg = raw_config()
        self.state, self.reg = make_registry(self.cfg, clock=self.clock)
        self.addCleanup(self.state.close)

    def test_device_id_is_the_rns_identity_hash(self):
        d = RealDevice()
        self.assertEqual(d.device_id, d.identity.hash.hex())
        self.assertEqual(device_id_of(bytes.fromhex(d.public_key)), d.device_id)

    def test_bootstrap_device_loaded(self):
        dev = self.reg.trusted(PHONE_ID)
        self.assertEqual((dev.name, dev.platform, dev.bootstrap, dev.added_by), ("phone-1", "android", True, "config"))
        self.assertIs(self.reg.trusted_by_pubkey(PHONE_KEY), dev)
        self.assertIsNone(self.reg.trusted_by_pubkey(OTHER_KEY))
        self.assertIsNone(self.reg.by_pubkey("zz"))

    def test_add_validates_and_limits(self):
        with self.assertRaises(errors.BridgeError) as c:
            self.reg.add(OTHER_KEY, "", "ios", [], PHONE_ID)
        self.assertEqual(c.exception.code, errors.BAD_REQUEST)
        with self.assertRaises(errors.BridgeError):
            self.reg.add(OTHER_KEY, "x", "Not Valid", [], PHONE_ID)
        with self.assertRaises(errors.BridgeError):
            self.reg.add(OTHER_KEY, "x", "ios", ["root"], PHONE_ID)
        self.reg.max_devices = 2
        self.reg.add(OTHER_KEY, "second", "ios", ["field"], PHONE_ID)
        with self.assertRaises(errors.BridgeError) as c:
            self.reg.add("ef" * 64, "third", "ios", [], PHONE_ID)
        self.assertEqual(c.exception.code, errors.TOO_MANY_DEVICES)
        with self.assertRaises(errors.BridgeError) as c:
            self.reg.add(OTHER_KEY, "dup", "ios", [], PHONE_ID)
        self.assertEqual(c.exception.code, errors.DEVICE_EXISTS)

    def test_state_survives_reload(self):
        self.reg.add(OTHER_KEY, "second", "ios", ["field"], PHONE_ID)
        again = DeviceRegistry(self.state, 16)
        d = again.trusted(device_id_of(OTHER_KEY))
        self.assertEqual((d.name, d.roles, d.added_by, d.bootstrap), ("second", ("field",), PHONE_ID, False))

    def test_last_seen_is_throttled(self):
        self.reg.touch_seen(PHONE_ID)
        self.assertEqual(self.reg.get(PHONE_ID).last_seen, 1000.0)
        self.clock.advance(10)
        self.reg.touch_seen(PHONE_ID)
        self.assertEqual(self.reg.get(PHONE_ID).last_seen, 1010.0)                  # in memory: always fresh
        self.assertEqual(self.state.query("SELECT last_seen FROM devices")[0][0], 1000.0)   # on disk: once a minute
        self.clock.advance(60)
        self.reg.touch_seen(PHONE_ID)
        self.assertEqual(self.state.query("SELECT last_seen FROM devices")[0][0], 1070.0)

    def test_listeners_are_told(self):
        got = []
        self.reg.subscribe(lambda ev, d: got.append((ev, d.device_id)))
        d = self.reg.add(OTHER_KEY, "second", "ios", [], PHONE_ID)
        self.reg.update(d.device_id, name="renamed")
        self.reg.revoke(d.device_id, PHONE_ID)
        self.assertEqual([g[0] for g in got], ["added", "updated", "revoked"])


class BootstrapPrecedenceTest(unittest.TestCase):
    """Config devices seed the registry; the state database wins for revocation, names and roles."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "bridge.sqlite3")
        self.seeds = [DeviceSeed(PHONE_KEY, "phone-1", "android", ("field",)), DeviceSeed(OTHER_KEY, "desk", "linux")]

    def boot(self, seeds=None):
        state = State(self.path)
        reg = DeviceRegistry(state, 16)
        summary = reg.sync_bootstrap(self.seeds if seeds is None else seeds)
        return state, reg, summary

    def test_revoked_bootstrap_device_stays_revoked_after_restart(self):
        state, reg, summary = self.boot()
        self.assertEqual(len(summary["added"]), 2)
        reg.revoke(PHONE_ID, device_id_of(OTHER_KEY), "lost phone")
        state.close()
        state, reg, summary = self.boot()                  # restart, the config still lists both devices
        self.addCleanup(state.close)
        self.assertEqual(summary["added"], [])
        self.assertIsNone(reg.trusted(PHONE_ID))
        self.assertIsNotNone(reg.get(PHONE_ID).revoked_at)
        self.assertIsNotNone(reg.trusted(device_id_of(OTHER_KEY)))

    def test_config_does_not_overwrite_runtime_edits(self):
        state, reg, _ = self.boot()
        reg.update(PHONE_ID, name="my phone", roles=[])
        state.close()
        seeds = [DeviceSeed(PHONE_KEY, "config-name", "ios", ("field",)), self.seeds[1]]
        state, reg, _ = self.boot(seeds)
        self.addCleanup(state.close)
        d = reg.get(PHONE_ID)
        self.assertEqual((d.name, d.roles, d.platform), ("my phone", (), "android"))

    def test_device_removed_from_config_is_revoked(self):
        state, reg, _ = self.boot()
        state.close()
        state, reg, summary = self.boot([self.seeds[1]])
        self.addCleanup(state.close)
        self.assertEqual(summary["removed"], [PHONE_ID])
        self.assertIsNone(reg.trusted(PHONE_ID))
        self.assertFalse(reg.get(PHONE_ID).bootstrap)

    def test_dynamic_device_becomes_bootstrap_when_listed(self):
        state, reg, _ = self.boot([self.seeds[1]])
        reg.add(PHONE_KEY, "paired", "android", [], device_id_of(OTHER_KEY))
        self.assertFalse(reg.get(PHONE_ID).bootstrap)
        state.close()
        state, reg, summary = self.boot()
        self.addCleanup(state.close)
        self.assertTrue(reg.get(PHONE_ID).bootstrap)
        self.assertEqual(reg.get(PHONE_ID).name, "paired")
        self.assertEqual(summary["added"], [])

    def test_operator_reinstate(self):
        state, reg, _ = self.boot()
        reg.revoke(PHONE_ID, device_id_of(OTHER_KEY))
        reg.reinstate(PHONE_ID)
        self.assertIsNotNone(reg.trusted(PHONE_ID))
        state.close()
        state, reg, _ = self.boot()
        self.addCleanup(state.close)
        self.assertIsNotNone(reg.trusted(PHONE_ID))

    def test_reinstate_cli(self):
        from kestrel_bridge.__main__ import cmd_list_devices, cmd_reinstate
        cfg = raw_config(state_dir=self.tmp.name, devices=[
            {"public_key": s.public_key, "name": s.name, "platform": s.platform} for s in self.seeds])
        state, reg, _ = self.boot()
        reg.revoke(PHONE_ID, device_id_of(OTHER_KEY))
        state.close()
        self.assertEqual(cmd_reinstate(cfg, "00" * 16), 2)           # unknown device
        self.assertEqual(cmd_reinstate(cfg, PHONE_ID.upper()), 0)
        self.assertEqual(cmd_list_devices(cfg), 0)
        state, reg, _ = self.boot()
        self.addCleanup(state.close)
        self.assertIsNotNone(reg.trusted(PHONE_ID))


def make_pairing(newdev, clock, *, ts=None, nonce=None, name="New phone", platform="ios"):
    nonce = nonce if nonce is not None else os.urandom(16)
    qr = encode_pairing_qr(bytes.fromhex(newdev.public_key), name, platform, nonce, clock() if ts is None else ts)
    return decode_pairing_qr(qr)


def approve_args(approver, payload, **extra):
    return {"payload": payload, "signature": approver.sign(pairing_sign_message(payload, approver.device_id)),
            **extra}


class PairingTest(ServiceBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.approver = RealDevice()
        self.registry.add(self.approver.public_key, "approver", "android", [], PHONE_ID)
        self.new = RealDevice()
        self.actx = Ctx(device_id=self.approver.device_id, transport="link")
        self.published.clear()

    def approve(self, args, ctx=None):
        return self.call("/devices/approve", args, ctx or self.actx)

    async def test_valid_pairing(self):
        payload = make_pairing(self.new, self.clock)
        r = await self.approve(approve_args(self.approver, payload))
        self.assertTrue(r["ok"], r)
        d = r["result"]["device"]
        self.assertEqual((d["device_id"], d["public_key"], d["name"], d["platform"], d["roles"], d["bootstrap"],
                          d["added_by"], d["revoked_at"]),
                         (self.new.device_id, self.new.public_key, "New phone", "ios", [], False,
                          self.approver.device_id, None))
        self.assertIsNotNone(self.registry.trusted(self.new.device_id))
        added = [e for e in self.published if e["event"] == "device_added"]
        self.assertEqual(len(added), 1)
        self.assertEqual(added[0]["data"]["device"]["device_id"], self.new.device_id)
        self.assertEqual(added[0]["data"]["approved_by"], self.approver.device_id)

    async def test_name_and_roles_chosen_by_approver(self):
        payload = make_pairing(self.new, self.clock)
        r = await self.approve(approve_args(self.approver, payload, name="Ops tablet", roles=["field"]))
        self.assertEqual((r["result"]["device"]["name"], r["result"]["device"]["roles"]), ("Ops tablet", ["field"]))

    async def test_expired_and_future_timestamps(self):
        w = self.cfg.limits.pairing_window
        for ts in (self.clock() - w - 1, self.clock() + w + 1):
            r = await self.approve(approve_args(self.approver, make_pairing(self.new, self.clock, ts=ts)))
            self.assertEqual(r["error"]["code"], errors.PAIRING_EXPIRED)
            self.assertEqual(r["error"]["details"]["server_time"], self.clock())
        self.assertIsNone(self.registry.get(self.new.device_id))
        fresh = make_pairing(self.new, self.clock, ts=self.clock() - w + 1)       # still inside the window
        self.assertTrue((await self.approve(approve_args(self.approver, fresh)))["ok"])

    async def test_window_follows_the_clock(self):
        payload = make_pairing(self.new, self.clock)
        self.clock.advance(self.cfg.limits.pairing_window + 1)
        r = await self.approve(approve_args(self.approver, payload))
        self.assertEqual(r["error"]["code"], errors.PAIRING_EXPIRED)

    async def test_replayed_nonce(self):
        nonce = os.urandom(16)
        payload = make_pairing(self.new, self.clock, nonce=nonce)
        self.assertTrue((await self.approve(approve_args(self.approver, payload)))["ok"])
        r = await self.approve(approve_args(self.approver, payload))
        self.assertEqual(r["error"]["code"], errors.PAIRING_REPLAY)
        other = RealDevice()                  # the same nonce in a QR of another device is a replay too
        r = await self.approve(approve_args(self.approver, make_pairing(other, self.clock, nonce=nonce)))
        self.assertEqual(r["error"]["code"], errors.PAIRING_REPLAY)
        self.assertIsNone(self.registry.get(other.device_id))

    async def test_bad_signatures(self):
        payload = make_pairing(self.new, self.clock)
        msg = pairing_sign_message(payload, self.approver.device_id)
        stranger = RealDevice()
        tampered = make_pairing(self.new, self.clock, name="Evil")
        cases = {
            "signed by another identity": stranger.sign(msg),
            "signature over another payload": self.approver.sign(pairing_sign_message(tampered, self.approver.device_id)),
            "no approver id in the message": self.approver.sign(payload),
            "other approver id": self.approver.sign(pairing_sign_message(payload, PHONE_ID)),
            "truncated": self.approver.sign(msg)[:63],
            "not bytes": "abcd",
            "missing": None,
        }
        for what, sig in cases.items():
            r = await self.approve({"payload": payload, "signature": sig})
            self.assertEqual(r["error"]["code"], errors.BAD_SIGNATURE, what)
        self.assertIsNone(self.registry.get(self.new.device_id))
        # failed attempts did not consume the nonce
        self.assertTrue((await self.approve(approve_args(self.approver, payload)))["ok"])

    async def test_revoked_approver_is_rejected(self):
        payload = make_pairing(self.new, self.clock)
        self.registry.revoke(self.approver.device_id, PHONE_ID)
        r = await self.approve(approve_args(self.approver, payload))
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)
        self.assertIsNone(self.registry.get(self.new.device_id))

    async def test_unknown_approver_is_rejected(self):
        payload = make_pairing(self.new, self.clock)
        stranger = RealDevice()
        r = await self.approve(approve_args(stranger, payload), Ctx(device_id=stranger.device_id, transport="link"))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)

    async def test_link_only(self):
        payload = make_pairing(self.new, self.clock)
        r = await self.approve(approve_args(self.approver, payload),
                               Ctx(device_id=self.approver.device_id, transport="lxmf", journal_reserved=True))
        self.assertEqual(r["error"]["code"], errors.UNSUPPORTED_TRANSPORT)

    async def test_malformed_payloads(self):
        good = make_pairing(self.new, self.clock)
        bad_maps = [
            {"pubkey": b"short", "name": "n", "platform": "ios", "nonce": os.urandom(16), "ts": self.clock()},
            {"pubkey": bytes.fromhex(self.new.public_key), "name": "n", "platform": "ios", "nonce": b"x", "ts": 1.0},
            {"pubkey": bytes.fromhex(self.new.public_key), "name": "", "platform": "ios", "nonce": os.urandom(16),
             "ts": self.clock()},
            {"pubkey": bytes.fromhex(self.new.public_key), "name": "n", "platform": "ios", "nonce": os.urandom(16),
             "ts": "now"},
            {"pubkey": self.new.public_key, "name": "n", "platform": "ios", "nonce": os.urandom(16),    # hex, not bin
             "ts": self.clock()},
        ]
        payloads = [codec.pack(m) for m in bad_maps] + [b"\xc1garbage", codec.pack([1]), b"", None, "text", b"x" * 2000]
        for payload in payloads:
            r = await self.approve({"payload": payload, "signature": b"\0" * 64})
            self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID, repr(payload)[:40])
        self.assertTrue((await self.approve(approve_args(self.approver, good)))["ok"])

    async def test_qr_text_codec(self):
        qr = encode_pairing_qr(b"\x01" * 64, "n", "ios", b"\x02" * 16, 5)
        self.assertTrue(qr.startswith("kestrel-pair:v1:"))
        self.assertNotIn("=", qr)
        self.assertEqual(codec.unpack(decode_pairing_qr(qr))["ts"], 5)
        for bad in ("kestrel-pair:v2:abcd", "abcd", "kestrel-pair:v1:@@@", None):
            with self.assertRaises(errors.BridgeError) as c:
                decode_pairing_qr(bad)
            self.assertEqual(c.exception.code, errors.PAIRING_INVALID)

    async def test_existing_and_revoked_devices_cannot_be_paired_again(self):
        self.assertTrue((await self.approve(approve_args(self.approver, make_pairing(self.new, self.clock))))["ok"])
        r = await self.approve(approve_args(self.approver, make_pairing(self.new, self.clock)))
        self.assertEqual(r["error"]["code"], errors.DEVICE_EXISTS)
        self.registry.revoke(self.new.device_id, PHONE_ID)
        r = await self.approve(approve_args(self.approver, make_pairing(self.new, self.clock)))
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)

    async def test_device_limit(self):
        self.registry.max_devices = 2
        r = await self.approve(approve_args(self.approver, make_pairing(self.new, self.clock)))
        self.assertEqual(r["error"]["code"], errors.TOO_MANY_DEVICES)
        # the refused attempt must not burn the nonce
        self.registry.max_devices = 3
        self.assertEqual(self.state.query("SELECT COUNT(*) FROM pair_nonces")[0][0], 0)

    async def test_admin_rate_limit(self):
        self.cfg.limits.device_admin_rate_per_minute = 2
        for _ in range(2):
            r = await self.approve({"payload": b"x", "signature": b"x"})
            self.assertEqual(r["error"]["code"], errors.PAIRING_INVALID)
        r = await self.approve({"payload": b"x", "signature": b"x"})
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)


class DeviceAdminTest(ServiceBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.second = RealDevice()
        self.registry.add(self.second.public_key, "second", "ios", [], PHONE_ID)
        self.sctx = Ctx(device_id=self.second.device_id, transport="link")
        self.published.clear()

    async def test_list_rename_set_role(self):
        self.svc.online = lambda d: d == PHONE_ID
        r = (await self.call("/devices/list", {}))["result"]
        self.assertEqual([d["device_id"] for d in r["devices"]], [PHONE_ID, self.second.device_id])
        self.assertEqual([d["online"] for d in r["devices"]], [True, False])
        self.assertEqual(r["key_epoch"], 1)
        r = await self.call("/devices/rename", {"name": "Main phone"})          # default: the caller itself
        self.assertEqual(r["result"]["device"]["name"], "Main phone")
        r = await self.call("/devices/rename", {"device_id": self.second.device_id, "name": "Tablet"})
        self.assertEqual(r["result"]["device"]["name"], "Tablet")
        self.assertEqual(self.published[-1]["event"], "device_updated")
        r = await self.call("/devices/set_role", {"device_id": self.second.device_id, "role": "field", "enabled": True})
        self.assertEqual(r["result"]["device"]["roles"], ["field"])
        r = await self.call("/devices/set_role", {"device_id": self.second.device_id, "role": "field", "enabled": False})
        self.assertEqual(r["result"]["device"]["roles"], [])
        for args, code in (({"name": ""}, errors.BAD_REQUEST), ({"device_id": "zz", "name": "x"}, errors.BAD_REQUEST),
                           ({"device_id": "00" * 16, "name": "x"}, errors.DEVICE_NOT_FOUND)):
            self.assertEqual((await self.call("/devices/rename", args))["error"]["code"], code)
        for args in ({"device_id": PHONE_ID, "role": "admin", "enabled": True},
                     {"device_id": PHONE_ID, "role": "field", "enabled": "yes"}):
            self.assertEqual((await self.call("/devices/set_role", args))["error"]["code"], errors.BAD_REQUEST)

    async def test_revoked_devices_in_list(self):
        await self.call("/devices/revoke", {"device_id": self.second.device_id, "reason": "sold"})
        r = (await self.call("/devices/list", {}))["result"]["devices"]
        self.assertIsNotNone(r[1]["revoked_at"])
        r = (await self.call("/devices/list", {"include_revoked": False}))["result"]["devices"]
        self.assertEqual([d["device_id"] for d in r], [PHONE_ID])
        self.assertEqual(self.state.query("SELECT revoke_reason, revoked_by FROM devices WHERE device_id=?",
                                          (self.second.device_id,))[0], ("sold", PHONE_ID))
        r = await self.call("/devices/rename", {"device_id": self.second.device_id, "name": "x"})
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)

    async def test_revocation_rejects_further_commands(self):
        self.assertTrue((await self.call("/hello", {"protocol_version": 2}, self.sctx))["ok"])
        r = await self.call("/devices/revoke", {"device_id": self.second.device_id})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["key_epoch"], 2)
        for path, args in (("/hello", {"protocol_version": 2}), ("/sync_chats", {}), ("/devices/list", {}),
                           ("/send_lxmf", {"cmd_id": "cmd-rev-0001", "to": "11" * 16, "text": "x"})):
            r = await self.call(path, args, self.sctx)
            self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED, path)
        self.assertEqual(self.fake.sent, [])
        ev = [e for e in self.published if e["event"] == "device_revoked"]
        self.assertEqual(len(ev), 1)
        self.assertEqual((ev[0]["data"]["device_id"], ev[0]["data"]["key_epoch"]), (self.second.device_id, 2))
        # unknown ids are unauthorized, not "revoked"
        r = await self.call("/hello", {"protocol_version": 2}, Ctx(device_id="00" * 16, transport="link"))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)

    async def test_revocation_drops_push_subscriptions(self):
        from kestrel_bridge.push import Subscriber
        hub = self.svc.push
        sub = Subscriber(self.second.device_id, lambda b: True)
        hub._subs.append(sub)
        await self.call("/devices/revoke", {"device_id": self.second.device_id})
        self.assertNotIn(sub, hub.subscribers())

    async def test_last_trusted_device_cannot_be_revoked(self):
        r = await self.call("/devices/revoke", {"device_id": self.second.device_id})
        self.assertTrue(r["ok"])
        r = await self.call("/devices/revoke", {"device_id": PHONE_ID})            # the only device left
        self.assertEqual(r["error"]["code"], errors.LAST_DEVICE)
        self.assertIsNotNone(self.registry.trusted(PHONE_ID))
        self.assertEqual(self.vault_epoch(), 2)                                     # the refused call changed nothing

    async def test_revoke_validation(self):
        for args, code in (({}, errors.BAD_REQUEST), ({"device_id": "00" * 16}, errors.DEVICE_NOT_FOUND),
                           ({"device_id": self.second.device_id, "reason": 5}, errors.BAD_REQUEST),
                           ({"device_id": self.second.device_id, "reason": "x" * 65}, errors.BAD_REQUEST)):
            self.assertEqual((await self.call("/devices/revoke", args))["error"]["code"], code)
        self.assertTrue((await self.call("/devices/revoke", {"device_id": self.second.device_id}))["ok"])
        r = await self.call("/devices/revoke", {"device_id": self.second.device_id})
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)

    async def test_a_device_can_revoke_itself_when_others_remain(self):
        r = await self.call("/devices/revoke", {"device_id": self.second.device_id}, self.sctx)
        self.assertTrue(r["ok"])
        self.assertIsNone(self.registry.trusted(self.second.device_id))

    def vault_epoch(self):
        return self.svc.vault.epoch()


class RpcLinkTest(unittest.TestCase):
    """RpcServer: identification against the registry and closing the Links of a revoked device."""

    def setUp(self):
        from kestrel_bridge.rpc import RpcServer
        self.cfg = raw_config()
        self.state, self.registry = make_registry(self.cfg)
        self.addCleanup(self.state.close)
        self.second = RealDevice()
        self.registry.add(self.second.public_key, "second", "ios", [], PHONE_ID)
        import asyncio
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.addCleanup(lambda: (self.loop.call_soon_threadsafe(self.loop.stop), self.thread.join(5)))
        from kestrel_bridge.push import PushHub
        from kestrel_bridge.service import Service
        self.svc = Service(self.cfg, SimpleNamespace(version="4.12.1", api_version=2), self.state,
                           registry=self.registry)
        self.svc.push = PushHub(self.cfg, registry=self.registry)
        self.rpc = RpcServer(self.cfg, None, self.svc, self.svc.push, self.loop)

    def add_link(self, device, n):
        import RNS
        torn = []
        link = SimpleNamespace(link_id=bytes([n]) * 16, status=RNS.Link.ACTIVE, rtt=0.1, mtu=2000,
                               teardown=lambda: torn.append(n), get_mdu=lambda: 400)
        from kestrel_bridge.rpc import _LinkState
        st = _LinkState(link)
        st.device_id = device.device_id if device is not None else None
        self.rpc._links[link.link_id] = st
        return link, torn

    def identity_of(self, device):
        return SimpleNamespace(get_public_key=lambda: bytes.fromhex(device.public_key))

    def test_revocation_closes_all_links_of_that_device_only(self):
        first = SimpleNamespace(public_key=PHONE_KEY, device_id=PHONE_ID)
        _, torn1 = self.add_link(first, 1)
        _, torn2a = self.add_link(self.second, 2)
        _, torn2b = self.add_link(self.second, 3)
        self.assertTrue(self.rpc.has_link(self.second.device_id))
        r = self.rpc._handle("/devices/revoke", {"device_id": self.second.device_id}, bytes([1]) * 16,
                             self.identity_of(first))
        self.assertTrue(r["ok"], r)
        self.assertEqual((torn1, torn2a, torn2b), ([], [2], [3]))
        # the revoked key is refused on the (not yet torn down) link: nothing is executed
        r = self.rpc._handle("/hello", {"protocol_version": 2}, bytes([2]) * 16, self.identity_of(self.second))
        self.assertEqual(r["error"]["code"], errors.DEVICE_REVOKED)
        self.assertFalse(self.rpc.has_link(self.second.device_id))

    def test_self_revocation_answers_first_and_closes_later(self):
        first = SimpleNamespace(public_key=PHONE_KEY, device_id=PHONE_ID)
        self.add_link(first, 1)
        _, torn = self.add_link(self.second, 2)
        r = self.rpc._handle("/devices/revoke", {"device_id": self.second.device_id}, bytes([2]) * 16,
                             self.identity_of(self.second))
        self.assertTrue(r["ok"], r)             # the response is still delivered on that link
        self.assertTrue(self.wait_for(lambda: torn == [2]))

    def wait_for(self, cond, timeout=5.0):
        import time
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False

    def test_unidentified_unknown_and_mismatching_identities(self):
        self.add_link(None, 1)
        r = self.rpc._handle("/hello", {"protocol_version": 2}, bytes([1]) * 16, None)
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)
        stranger = RealDevice()
        r = self.rpc._handle("/hello", {"protocol_version": 2}, bytes([1]) * 16, self.identity_of(stranger))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)
        # a trusted key on a link that was identified as somebody else is refused
        self.add_link(self.second, 4)
        r = self.rpc._handle("/hello", {"protocol_version": 2}, bytes([4]) * 16,
                             self.identity_of(SimpleNamespace(public_key=PHONE_KEY)))
        self.assertEqual(r["error"]["code"], errors.UNAUTHORIZED)

    def test_remote_identified_rejects_unknown_and_revoked(self):
        link, torn = self.add_link(None, 5)
        self.rpc._remote_identified(link, SimpleNamespace(
            get_public_key=lambda: bytes.fromhex(RealDevice().public_key), hash=b"\x00" * 16))
        self.assertEqual(torn, [5])
        link, torn = self.add_link(None, 6)
        self.rpc._remote_identified(link, SimpleNamespace(
            get_public_key=lambda: bytes.fromhex(self.second.public_key), hash=b"\x00" * 16))
        self.assertEqual(torn, [])
        self.assertEqual(self.rpc._links[link.link_id].device_id, self.second.device_id)
        self.registry.revoke(self.second.device_id, PHONE_ID)
        link, torn = self.add_link(None, 7)
        self.rpc._remote_identified(link, SimpleNamespace(
            get_public_key=lambda: bytes.fromhex(self.second.public_key), hash=b"\x00" * 16))
        self.assertEqual(torn, [7])


if __name__ == "__main__":
    unittest.main()
