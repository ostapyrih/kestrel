import unittest

from kestrel_bridge import codec
from kestrel_bridge.push import (CONSTRAINED, FULL, PushHub, Subscriber, classify_interface, classify_link,
                                 filter_event, more_restrictive, truncate_utf8)
from tests.helpers import OTHER_ID, OTHER_KEY, PEER, PHONE_ID, PHONE_KEY, FakeClock, make_registry, raw_config

DM = {"event": "lxmf.message", "data": {"peer": PEER, "hash": "h", "incoming": True, "ts": 1.0,
                                         "text": "x" * 500, "title": "t", "attachments": True, "name": "N" * 80}}
OUT = {"event": "lxmf.message", "data": {"peer": PEER, "hash": "h", "incoming": False, "text": "mine"}}
RRC = {"event": "rrc.message", "data": {"hub": "h", "room": "r", "seq": 1, "nick": "a", "text": "hello", "mention": False}}
MENTION = {"event": "rrc.message", "data": {**RRC["data"], "mention": True}}
STATE_MINE = {"event": "lxmf.state", "data": {"hash": "h", "state": "delivered", "cmd_id": "c", "progress": 100}}
STATE_PROGRESS = {"event": "lxmf.state", "data": {"hash": "h", "state": "sending", "cmd_id": "c"}}
STATE_OTHER = {"event": "lxmf.state", "data": {"hash": "h", "state": "delivered"}}


class FilterTest(unittest.TestCase):
    def test_classify_interface(self):
        fast = raw_config().push.fast_interfaces
        self.assertTrue(classify_interface("TCPInterface[Public/203.0.113.1:4242]", fast))
        self.assertTrue(classify_interface("BackboneInterface[x]", fast))
        self.assertFalse(classify_interface("RNodeInterface[lora]", fast))
        self.assertFalse(classify_interface("AutoInterface[Default]", fast))
        self.assertFalse(classify_interface("None", fast))
        self.assertFalse(classify_interface(None, fast))
        self.assertFalse(classify_interface("RNodeInterface[TCPInterface]", fast))   # class name decides, not the label

    def test_more_restrictive(self):
        self.assertEqual(more_restrictive(FULL, FULL), FULL)
        self.assertEqual(more_restrictive(FULL, CONSTRAINED), CONSTRAINED)

    def test_truncate_utf8_is_safe(self):
        t, cut = truncate_utf8("ж" * 10, 5)     # 2 bytes per char
        self.assertEqual((t, cut), ("жж", True))
        self.assertEqual(truncate_utf8("abc", 5), ("abc", False))

    def test_full_passes_everything(self):
        for ev in (DM, OUT, RRC, STATE_OTHER):
            self.assertIs(filter_event(ev, FULL, 160), ev)

    def test_lora_profile(self):
        d = filter_event(DM, CONSTRAINED, 160)["data"]
        self.assertEqual(len(d["text"]), 160)
        self.assertTrue(d["truncated"])
        self.assertNotIn("title", d)
        self.assertNotIn("attachments", d)
        self.assertEqual(len(d["name"]), 32)
        self.assertIsNone(filter_event(OUT, CONSTRAINED, 160))          # own outgoing: no
        self.assertIsNone(filter_event(RRC, CONSTRAINED, 160))          # room chatter: no
        self.assertEqual(filter_event(MENTION, CONSTRAINED, 160)["data"]["text"], "hello")   # mention: yes
        self.assertIsNotNone(filter_event(STATE_MINE, CONSTRAINED, 160))
        self.assertIsNone(filter_event(STATE_PROGRESS, CONSTRAINED, 160))
        self.assertIsNone(filter_event(STATE_OTHER, CONSTRAINED, 160))   # not sent through the bridge
        self.assertIsNone(filter_event({"event": "rrc.change", "data": {"hub": "h"}}, CONSTRAINED, 160))
        self.assertIsNotNone(filter_event({"event": "resync", "data": {"cursor": 1}}, CONSTRAINED, 160))


class HubTest(unittest.TestCase):
    def setUp(self):
        self.cfg = raw_config(devices=[{"public_key": PHONE_KEY, "name": "field-phone", "platform": "android",
                                        "roles": ["field"]},
                                       {"public_key": OTHER_KEY, "name": "desk", "platform": "linux"}])
        self.state, self.registry = make_registry(self.cfg)
        self.addCleanup(self.state.close)
        self.clock = FakeClock()
        self.got = []
        self.online = set()

    def hub(self, path_profile=None, offline=None):
        return PushHub(self.cfg, profile_of=lambda p: path_profile, offline_send=offline, clock=self.clock,
                       registry=self.registry, link_online=lambda d: d in self.online)

    def sub(self, hub, hint=FULL, topics=("lxmf", "rrc"), device_id=PHONE_ID):
        s = Subscriber(device_id, lambda b: self.got.append(codec.unpack(b)) or True, topics, hint)
        hub.subscribe(s)
        return s

    def test_full_profile_delivers_with_sequence(self):
        h = self.hub(FULL)
        self.sub(h)
        h.publish(DM)
        h.publish(RRC)
        self.assertEqual([g["seq"] for g in self.got], [1, 2])
        self.assertEqual(self.got[0]["t"], "push")
        self.assertEqual(len(self.got[0]["data"]["text"]), 500)

    def test_path_profile_constrained_filters(self):
        h = self.hub(CONSTRAINED)
        self.sub(h)
        h.publish(DM)
        h.publish(RRC)
        h.publish(MENTION)
        self.assertEqual([g["event"] for g in self.got], ["lxmf.message", "rrc.message"])
        self.assertTrue(self.got[0]["data"]["truncated"])

    def test_phone_hint_can_only_downgrade(self):
        h = self.hub(CONSTRAINED)
        self.sub(h, hint=FULL)
        h.publish(RRC)
        self.assertEqual(self.got, [])
        h2 = self.hub(FULL)
        self.sub(h2, hint=CONSTRAINED)
        h2.publish(RRC)
        self.assertEqual(self.got, [])

    def test_unknown_path_uses_config_default(self):
        self.cfg.push.unknown_profile = "constrained"
        h = self.hub(None)
        self.sub(h)
        h.publish(RRC)
        self.assertEqual(self.got, [])
        self.cfg.push.unknown_profile = "full"
        h3 = self.hub(None)
        self.sub(h3)
        h3.publish(RRC)
        self.assertEqual(len(self.got), 1)

    def test_topics_respected_and_dead_links_dropped(self):
        h = self.hub(FULL)
        self.sub(h, topics=("lxmf",))
        h.publish(RRC)
        self.assertEqual(self.got, [])
        dead = Subscriber(PHONE_KEY, lambda b: False)
        h.subscribe(dead)
        h.publish(DM)
        self.assertNotIn(dead, h.subscribers())

    def test_offline_push_only_for_dm_and_mentions_with_budget(self):
        sent = []
        h = self.hub(FULL, offline=lambda dev, wire: sent.append((dev, codec.unpack(wire))))
        h.publish(DM)               # no live link -> LXMF fallback (field device only), truncated
        h.publish(RRC)              # room chatter is never pushed offline
        h.publish(MENTION)
        self.assertEqual([s[1]["event"] for s in sent], ["lxmf.message", "rrc.message"])
        self.assertEqual({s[0] for s in sent}, {PHONE_ID})      # the non-field device gets nothing
        self.assertTrue(sent[0][1]["data"]["truncated"])
        self.cfg.push.offline_push_max_per_hour = 3
        for _ in range(10):
            h.publish(DM)
        self.assertEqual(len(sent), 3)
        self.clock.advance(3601)
        h.publish(DM)
        self.assertEqual(len(sent), 4)

    def test_no_offline_push_when_link_is_live(self):
        sent = []
        h = self.hub(FULL, offline=lambda p, w: sent.append(1))
        self.sub(h)
        h.publish(DM)
        self.assertEqual(sent, [])

    def test_no_offline_push_when_device_has_a_link_without_subscription(self):
        sent = []
        h = self.hub(FULL, offline=lambda p, w: sent.append(1))
        self.online.add(PHONE_ID)
        h.publish(DM)
        self.assertEqual(sent, [])

    def test_revoked_field_device_gets_no_offline_push(self):
        sent = []
        h = self.hub(FULL, offline=lambda p, w: sent.append(p))
        self.registry.revoke(PHONE_ID, OTHER_ID)
        h.publish(DM)
        self.assertEqual(sent, [])

    def test_fan_out_to_every_device_link_with_shared_event_id(self):
        h = self.hub(FULL)
        self.sub(h)
        self.sub(h, device_id=OTHER_ID)
        self.sub(h, device_id=OTHER_ID, topics=("rrc",))      # a second link of one device, other topics
        h.publish(DM)
        self.assertEqual(len(self.got), 2)                      # the rrc-only link does not get lxmf events
        self.assertEqual(len({g["id"] for g in self.got}), 1)   # one event id for dedupe
        self.assertEqual(len({g["seq"] for g in self.got}), 2)

    def test_skip_device_and_drop_device(self):
        h = self.hub(FULL)
        self.sub(h, topics=("lxmf", "vault"))
        self.sub(h, device_id=OTHER_ID, topics=("lxmf", "vault"))
        h.publish({"event": "vault.blob", "data": {"blob_id": "x"}}, skip_device=PHONE_ID)
        self.assertEqual(len(self.got), 1)
        h.drop_device(OTHER_ID)
        self.got.clear()
        h.publish({"event": "device_added", "data": {}})       # always delivered, but only to remaining links
        self.assertEqual(len(self.got), 1)

    def test_device_events_topics_and_constrained_filter(self):
        h = self.hub(CONSTRAINED)
        self.sub(h, topics=("lxmf",))
        for name in ("device_added", "device_updated", "device_revoked", "resync"):
            h.publish({"event": name, "data": {"device_id": "x"}})      # topic-independent
        h.publish({"event": "read_state", "data": {"peer": PEER}})       # constrained: dropped
        h.publish({"event": "vault.blob", "data": {}})                    # topic vault not subscribed
        self.assertEqual([g["event"] for g in self.got], ["device_revoked", "resync"])
        self.got.clear()
        h2 = self.hub(FULL)
        self.sub(h2, topics=("lxmf",))
        h2.publish({"event": "read_state", "data": {"peer": PEER, "unread": False}})
        self.assertEqual([g["event"] for g in self.got], ["read_state"])


class ClassifyLinkTest(unittest.TestCase):
    def test_thresholds(self):
        self.assertEqual(classify_link(0.2, 262144, 1.5, 1000), FULL)
        self.assertEqual(classify_link(1.49, 1000, 1.5, 1000), FULL)
        self.assertEqual(classify_link(1.5, 262144, 1.5, 1000), CONSTRAINED)    # RTT too high (LoRa-like)
        self.assertEqual(classify_link(0.2, 999, 1.5, 1000), CONSTRAINED)       # base 500-byte MTU
        self.assertEqual(classify_link(4.0, 500, 1.5, 1000), CONSTRAINED)

    def test_unmeasured_is_unknown(self):
        self.assertIsNone(classify_link(None, 262144, 1.5, 1000))
        self.assertIsNone(classify_link(0.2, None, 1.5, 1000))
        self.assertIsNone(classify_link(0, 500, 1.5, 1000))


class FakeLink:
    def __init__(self, rtt, mtu):
        self.rtt, self.mtu = rtt, mtu


class LinkProfileTest(unittest.TestCase):
    def setUp(self):
        self.cfg = raw_config()
        self.link = None

    def profile(self, phone=PHONE_ID):
        from kestrel_bridge.rpc import LinkProfile
        return LinkProfile(self.cfg, lambda p: self.link)(phone)

    def test_from_link_measurements(self):
        self.link = FakeLink(0.3, 262144)
        self.assertEqual(self.profile(), FULL)
        self.link = FakeLink(3.0, 500)
        self.assertEqual(self.profile(), CONSTRAINED)

    def test_no_link_is_unknown(self):
        self.assertIsNone(self.profile())

    def test_hub_uses_link_profile_then_unknown_default_and_override(self):
        from kestrel_bridge.rpc import LinkProfile
        got = []
        h = PushHub(self.cfg, profile_of=LinkProfile(self.cfg, lambda p: self.link), clock=FakeClock())
        sub = Subscriber(PHONE_ID, lambda b: got.append(b) or True)
        self.link = FakeLink(3.0, 500)
        self.assertEqual(h.effective_profile(sub), CONSTRAINED)
        sub = Subscriber(PHONE_ID, lambda b: True)
        self.link = FakeLink(0.1, 262144)
        self.assertEqual(h.effective_profile(sub), FULL)
        # config override beats the measurement, the phone hint can still downgrade
        self.cfg.push.profile = "constrained"
        sub = Subscriber(PHONE_ID, lambda b: True)
        self.assertEqual(h.effective_profile(sub), CONSTRAINED)
        self.cfg.push.profile = "full"
        sub = Subscriber(PHONE_ID, lambda b: True)
        self.link = FakeLink(9.0, 500)
        self.assertEqual(h.effective_profile(sub), FULL)
        sub = Subscriber(PHONE_ID, lambda b: True, hint=CONSTRAINED)
        self.assertEqual(h.effective_profile(sub), CONSTRAINED)


if __name__ == "__main__":
    unittest.main()
