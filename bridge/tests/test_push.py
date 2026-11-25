import unittest

from kestrel_bridge import codec
from kestrel_bridge.push import (CONSTRAINED, FULL, PushHub, Subscriber, classify_interface, filter_event,
                                 more_restrictive, truncate_utf8)
from tests.helpers import PEER, PHONE_KEY, FakeClock, raw_config

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
        self.cfg = raw_config()
        self.clock = FakeClock()
        self.got = []

    def hub(self, path_profile=None, offline=None):
        return PushHub(self.cfg, profile_of=lambda p: path_profile, offline_send=offline, clock=self.clock)

    def sub(self, hub, hint=FULL, topics=("lxmf", "rrc")):
        s = Subscriber(PHONE_KEY, lambda b: self.got.append(codec.unpack(b)) or True, topics, hint)
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
        h = self.hub(FULL, offline=lambda phone, wire: sent.append((phone, codec.unpack(wire))))
        h.publish(DM)               # no live link -> LXMF fallback, truncated
        h.publish(RRC)              # room chatter is never pushed offline
        h.publish(MENTION)
        self.assertEqual([s[1]["event"] for s in sent], ["lxmf.message", "rrc.message"])
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


if __name__ == "__main__":
    unittest.main()
