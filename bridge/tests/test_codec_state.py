import unittest

from kestrel_bridge import codec, errors
from kestrel_bridge.errors import BridgeError
from kestrel_bridge.state import State
from tests.helpers import FakeClock


class CodecTest(unittest.TestCase):
    def test_round_trip(self):
        obj = {"ok": True, "result": {"a": [1, 2.5, "x", None, True], "b": {"c": "é"}}, "bin": b"\x00\x01"}
        self.assertEqual(codec.unpack(codec.pack(obj)), obj)

    def test_rejects_garbage_and_oversize(self):
        with self.assertRaises(BridgeError) as c:
            codec.unpack(b"\xc1\xc1\xc1")
        self.assertEqual(c.exception.code, errors.BAD_REQUEST)
        with self.assertRaises(BridgeError) as c:
            codec.unpack(codec.pack({"x": "y" * 500}), max_bytes=100)
        self.assertEqual(c.exception.code, errors.TOO_LARGE)
        with self.assertRaises(BridgeError):
            codec.unpack("not bytes")

    def test_envelopes_and_clamp(self):
        self.assertEqual(codec.ok({"a": 1}), {"ok": True, "result": {"a": 1}})
        e = codec.err(errors.REPLAY, "m", cached=1)
        self.assertEqual(e["error"], {"code": "replay", "message": "m", "details": {"cached": 1}})
        big = codec.ok({"t": "x" * 5000})
        clamped = codec.clamp_response(big, 1000)
        self.assertEqual(clamped["error"]["code"], errors.RESPONSE_TOO_LARGE)
        self.assertIs(codec.clamp_response(codec.ok({}), 1000)["ok"], True)


class StateTest(unittest.TestCase):
    def test_cursor_changes_only_on_change(self):
        s = State()
        self.assertEqual(s.cursor(), 0)
        self.assertTrue(s.touch_conv("lxmf:a", "1"))
        self.assertFalse(s.touch_conv("lxmf:a", "1"))
        self.assertTrue(s.touch_conv("lxmf:a", "1", force=True))
        self.assertTrue(s.touch_conv("rrc:h:r", "0|0"))
        self.assertEqual(s.cursor(), 3)
        keys, more = s.convs_since(1, "", 10)
        self.assertEqual(keys, ["lxmf:a", "rrc:h:r"])
        self.assertFalse(more)
        keys, more = s.convs_since(0, "", 1)
        self.assertEqual((keys, more), (["lxmf:a"], True))
        self.assertEqual(s.convs_since(0, "rrc:", 10)[0], ["rrc:h:r"])

    def test_last_id_monotonic(self):
        s = State()
        s.touch_conv("lxmf:a", "1")
        s.set_last_id("lxmf:a", 10)
        s.set_last_id("lxmf:a", 5)
        self.assertEqual(s.get_last_id("lxmf:a"), 10)

    def test_journal(self):
        clock = FakeClock()
        s = State(clock=clock)
        self.assertTrue(s.journal_reserve("p", "c1", 1.0))
        self.assertFalse(s.journal_reserve("p", "c1", 1.0))
        self.assertTrue(s.journal_reserve("q", "c1", 1.0))   # per phone
        s.journal_store("p", "c1", b"resp")
        self.assertEqual(s.journal_get("p", "c1"), b"resp")
        s.journal_release("p", "c1")
        self.assertTrue(s.journal_reserve("p", "c1", 1.0))
        clock.advance(1000)
        self.assertGreaterEqual(s.journal_prune(500), 2)
        self.assertTrue(s.journal_reserve("p", "c1", 1.0))

    def test_pending(self):
        s = State()
        s.pending_put("cmd1", "p", "h1", "peer", "outbound")
        self.assertEqual(s.pending_by_hash("h1")["cmd_id"], "cmd1")
        s.pending_update("h1", "sent")
        self.assertEqual(s.pending_by_hash("h1")["state"], "sent")
        s.pending_update("h1", "delivered")
        self.assertIsNone(s.pending_by_hash("h1"))


if __name__ == "__main__":
    unittest.main()
