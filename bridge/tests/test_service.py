import os
import unittest

from kestrel_bridge import errors
from kestrel_bridge.meshchatx_client import MeshChatXClient
from kestrel_bridge.push import PushHub
from kestrel_bridge.service import Ctx, Service, fetch_after
from kestrel_bridge.state import State
from tests.fake_meshchatx import PASSWORD, FakeMeshChatX, conversation
from tests.helpers import PEER, PHONE_KEY, FakeClock, start_fake

HUB = "ee" * 16


def link_ctx(**kw):
    return Ctx(phone=PHONE_KEY, transport="link", **kw)


class FetchAfterTest(unittest.IsolatedAsyncioTestCase):
    """Cursor gap handling for the MeshChatX 'newest-first + LIMIT' quirk."""

    def make_fetch(self, ids):
        rows = [{"id": i} for i in ids]
        calls = []

        async def fetch(order, after_id, count):
            calls.append((order, after_id, count))
            sel = [m for m in rows if (m["id"] > after_id if order == "asc" else m["id"] < after_id)]
            sel.sort(key=lambda m: m["id"], reverse=True)
            return sel[:count]
        return fetch, calls

    async def test_no_gap_single_call(self):
        fetch, calls = self.make_fetch(range(1, 6))
        msgs, gap = await fetch_after(fetch, 2, page=10)
        self.assertEqual([m["id"] for m in msgs], [3, 4, 5])
        self.assertFalse(gap)
        self.assertEqual(len(calls), 1)

    async def test_gap_is_filled_by_backward_paging(self):
        # ids interleaved with other peers' rows are not in this list; 25 new rows, page of 10
        fetch, calls = self.make_fetch(range(1, 40))
        msgs, gap = await fetch_after(fetch, 14, page=10)
        self.assertEqual([m["id"] for m in msgs], list(range(15, 40)))   # nothing missing in the middle
        self.assertFalse(gap)
        self.assertEqual(calls[0], ("asc", 14, 10))
        self.assertEqual(calls[1][0], "desc")

    async def test_older_rows_are_not_returned(self):
        fetch, _ = self.make_fetch(range(1, 30))
        msgs, _ = await fetch_after(fetch, 25, page=4)
        self.assertEqual([m["id"] for m in msgs], [26, 27, 28, 29])

    async def test_page_cap_reports_gap(self):
        fetch, _ = self.make_fetch(range(1, 500))
        msgs, gap = await fetch_after(fetch, 0, page=10, max_pages=3)
        self.assertTrue(gap)
        self.assertEqual(msgs[-1]["id"], 499)


class ServiceBase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        os.environ["KESTREL_TEST_PASSWORD"] = PASSWORD
        self.fake = FakeMeshChatX()
        self.server, self.cfg = await start_fake(self.fake)
        self.clock = FakeClock(5000.0)
        self.client = MeshChatXClient(self.cfg.meshchatx)
        self.state = State()
        self.published = []
        self.push = PushHub(self.cfg)
        self.push.publish = lambda ev: self.published.append(ev) or 0
        self.svc = Service(self.cfg, self.client, self.state, self.push, clock=self.clock)
        self.svc.compat_ok = True

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        self.state.close()

    async def call(self, path, args=None, ctx=None):
        return await self.svc.dispatch(path, args, ctx or link_ctx())


class DispatchTest(ServiceBase):
    async def test_hello_and_protocol_mismatch(self):
        r = await self.call("/hello", {"protocol_version": 1})
        self.assertTrue(r["ok"])
        self.assertEqual(r["result"]["protocol_version"], 1)
        r = await self.call("/hello", {"protocol_version": 2})
        self.assertEqual(r["error"]["code"], errors.PROTOCOL_MISMATCH)

    async def test_unknown_path_and_bad_args(self):
        self.assertEqual((await self.call("/nope"))["error"]["code"], errors.UNKNOWN_PATH)
        self.assertEqual((await self.call("/sync_chats", [1]))["error"]["code"], errors.BAD_REQUEST)
        r = await self.call("/get_messages", {"peer": "xyz"})
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)

    async def test_incompatible_upstream_blocks_commands_but_not_hello(self):
        self.svc.compat_ok = False
        self.assertTrue((await self.call("/hello", {"protocol_version": 1}))["ok"])
        r = await self.call("/sync_chats", {})
        self.assertEqual(r["error"]["code"], errors.UPSTREAM_INCOMPATIBLE)

    async def test_subscribe_needs_link(self):
        r = await self.call("/subscribe", {}, Ctx(phone=PHONE_KEY, transport="lxmf", journal_reserved=True))
        self.assertEqual(r["error"]["code"], errors.UNSUPPORTED_TRANSPORT)
        got = {}
        r = await self.call("/subscribe", {"topics": ["lxmf"], "profile": "constrained"},
                            link_ctx(subscribe=lambda t, h: got.update(t=t, h=h) or {"topics": t}))
        self.assertTrue(r["ok"])
        self.assertEqual(got, {"t": ["lxmf"], "h": "constrained"})
        r = await self.call("/subscribe", {"topics": ["x"]}, link_ctx(subscribe=lambda t, h: {}))
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)


class SendRrcTest(ServiceBase):
    async def test_rejects_slash_commands(self):
        for text in ("/join #x", "  /ban someone", "/"):
            r = await self.call("/send_rrc", {"cmd_id": "cmd-rrc-0001", "hub": HUB, "room": "general", "text": text})
            self.assertEqual(r["error"]["code"], errors.RRC_COMMAND_REJECTED, text)
        self.assertEqual(self.fake.rrc_sent, [])
        # a rejected command does not burn the cmd_id
        r = await self.call("/send_rrc", {"cmd_id": "cmd-rrc-0001", "hub": HUB, "room": "general", "text": "hello /not"})
        self.assertTrue(r["ok"])
        self.assertEqual(self.fake.rrc_sent[0]["text"], "hello /not")
        self.assertFalse(self.fake.rrc_sent[0]["action"])

    async def test_validation(self):
        base = {"cmd_id": "cmd-rrc-0002", "hub": HUB, "room": "general", "text": "x"}
        for patch in ({"hub": "zz"}, {"room": ""}, {"text": "  "}, {"cmd_id": "short"}, {"text": "x" * 5000}):
            r = await self.call("/send_rrc", {**base, **patch})
            self.assertFalse(r["ok"], patch)


class SendLxmfTest(ServiceBase):
    async def test_ack_with_hash_and_pending(self):
        args = {"cmd_id": "cmd-msg-0001", "to": PEER, "text": "hi", "delivery_method": "propagated"}
        r = await self.call("/send_lxmf", args)
        self.assertTrue(r["ok"], r)
        h = r["result"]["lxmf_hash"]
        self.assertEqual(h, self.fake.messages[PEER][0]["hash"])
        self.assertEqual(self.fake.sent[0]["method"], "propagated")
        self.assertEqual(self.state.pending_by_hash(h)["cmd_id"], "cmd-msg-0001")

    async def test_duplicate_cmd_id_not_executed_twice(self):
        args = {"cmd_id": "cmd-msg-0002", "to": PEER, "text": "hi"}
        first = await self.call("/send_lxmf", args)
        second = await self.call("/send_lxmf", args)
        self.assertEqual(second["error"]["code"], errors.REPLAY)
        self.assertEqual(second["error"]["details"]["cached"], first)   # phone learns the original ack
        self.assertEqual(len(self.fake.sent), 1)

    async def test_failed_send_is_final_but_unavailable_is_retryable(self):
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-msg-0003", "to": "f" * 32, "text": "x"})
        self.assertEqual(r["error"]["code"], errors.SEND_FAILED)
        again = await self.call("/send_lxmf", {"cmd_id": "cmd-msg-0003", "to": "f" * 32, "text": "x"})
        self.assertEqual(again["error"]["code"], errors.REPLAY)
        # upstream down -> nothing was sent -> same cmd_id may be retried
        await self.server.close()
        args = {"cmd_id": "cmd-msg-0004", "to": PEER, "text": "x"}
        r = await self.call("/send_lxmf", args)
        self.assertEqual(r["error"]["code"], errors.UPSTREAM_UNAVAILABLE)
        self.assertTrue(self.state.journal_reserve(PHONE_KEY, "cmd-msg-0004", 1.0))
        self.server = type(self.server)(self.fake.app)
        await self.server.start_server()

    async def test_rate_limit(self):
        self.cfg.limits.send_rate_per_minute = 2
        for i in range(2):
            r = await self.call("/send_lxmf", {"cmd_id": f"cmd-rate-000{i}", "to": PEER, "text": "x"})
            self.assertTrue(r["ok"])
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-rate-0009", "to": PEER, "text": "x"})
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)
        self.clock.advance(61)
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-rate-0009", "to": PEER, "text": "x"})
        self.assertTrue(r["ok"])

    async def test_bad_method(self):
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-msg-0005", "to": PEER, "text": "x", "delivery_method": "pigeon"})
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)


class SyncTest(ServiceBase):
    async def test_cursor_sync(self):
        a, b = "aa" * 16, "bb" * 16
        self.fake.conversations += [conversation(a, "Alice", "t1"), conversation(b, "Bob", "t1")]
        r = (await self.call("/sync_chats", {"cursor": 0}))["result"]
        self.assertEqual({c["peer"] for c in r["lxmf"]}, {a, b})
        self.assertEqual(r["cursor"], 2)
        self.assertFalse(r["more"])
        self.clock.advance(5)
        r2 = (await self.call("/sync_chats", {"cursor": r["cursor"]}))["result"]
        self.assertEqual(r2["lxmf"], [])          # nothing changed
        self.fake.conversations[0]["latest_message_created_at"] = "t2"
        self.fake.conversations[0]["is_unread"] = True
        self.clock.advance(5)
        r3 = (await self.call("/sync_chats", {"cursor": r2["cursor"]}))["result"]
        self.assertEqual([c["peer"] for c in r3["lxmf"]], [a])
        self.assertTrue(r3["lxmf"][0]["unread"])
        self.assertEqual(r3["lxmf"][0]["name"], "Alice")

    async def test_paging_and_reset(self):
        for i in range(5):
            self.fake.conversations.append(conversation(f"{i:02d}" * 16))
        r = (await self.call("/sync_chats", {"cursor": 0, "limit": 2}))["result"]
        self.assertTrue(r["more"])
        self.assertEqual(len(r["lxmf"]), 2)
        seen = {c["peer"] for c in r["lxmf"]}
        while r["more"]:
            r = (await self.call("/sync_chats", {"cursor": r["cursor"], "limit": 2}))["result"]
            seen |= {c["peer"] for c in r["lxmf"]}
        self.assertEqual(len(seen), 5)
        r = (await self.call("/sync_chats", {"cursor": 9999}))["result"]   # newer than the server: state was reset
        self.assertTrue(r["reset"])
        self.assertEqual(len(r["lxmf"]), 5)

    async def test_rrc_in_sync_and_list_rooms(self):
        self.fake.hubs.append({"hub_hash": HUB, "display_name": "Hub", "connected": True, "rooms": ["general"],
                               "unread_counts": {"general": 3}, "mention_rooms": ["general"]})
        r = (await self.call("/sync_chats", {}))["result"]
        self.assertEqual(r["rrc"], [{"hub": HUB, "hub_name": "Hub", "room": "general", "unread": 3, "mention": True}])
        rooms = (await self.call("/list_rooms"))["result"]["hubs"][0]
        self.assertEqual(rooms["rooms"], [{"room": "general", "unread": 3, "mention": True}])


class MessagesTest(ServiceBase):
    async def test_latest_before_after(self):
        for i in range(30):
            self.fake.add_message(PEER, f"m{i}")
        r = (await self.call("/get_messages", {"peer": PEER, "limit": 10}))["result"]
        ids = [m["id"] for m in r["messages"]]
        self.assertEqual(ids, list(range(21, 31)))     # ascending although MeshChatX is newest-first
        self.assertTrue(r["has_more"])
        r = (await self.call("/get_messages", {"peer": PEER, "limit": 10, "before_id": 21}))["result"]
        self.assertEqual([m["id"] for m in r["messages"]], list(range(11, 21)))
        r = (await self.call("/get_messages", {"peer": PEER, "limit": 10, "after_id": 25}))["result"]
        self.assertEqual([m["id"] for m in r["messages"]], list(range(26, 31)))
        self.assertFalse(r["has_more"])
        self.assertFalse(r["gap"])
        self.assertEqual(self.state.get_last_id(f"lxmf:{PEER}"), 0)   # untouched conv row: no-op, no crash

    async def test_after_id_with_more_than_limit(self):
        for i in range(30):
            self.fake.add_message(PEER, f"m{i}")
        r = (await self.call("/get_messages", {"peer": PEER, "limit": 10, "after_id": 5}))["result"]
        self.assertEqual([m["id"] for m in r["messages"]], list(range(6, 16)))   # oldest first, client pages on
        self.assertTrue(r["has_more"])

    async def test_room_messages_clear_active_room(self):
        self.fake.room_messages[(HUB, "general")] = [
            {"seq": i, "kind": "msg", "nick": "n", "text": f"t{i}", "ts": i, "src": "s", "mention": i == 3}
            for i in range(1, 6)]
        r = (await self.call("/get_room_messages", {"hub": HUB, "room": "general", "limit": 3}))["result"]
        self.assertEqual([m["seq"] for m in r["messages"]], [3, 4, 5])
        self.assertTrue(r["has_more"])
        r = (await self.call("/get_room_messages", {"hub": HUB, "room": "general", "after_seq": 3}))["result"]
        self.assertEqual([m["seq"] for m in r["messages"]], [4, 5])
        self.assertEqual(self.fake.active_cleared, 2)


class EventsTest(ServiceBase):
    async def test_events_become_push(self):
        m = {"hash": "h1", "source_hash": PEER, "state": "delivered", "content": "yo", "timestamp": 1.0,
             "fields": {"image": {}}}
        await self.svc.on_event({"type": "lxmf.delivery", "remote_identity_name": "Peer", "lxmf_message": m})
        ev = self.published[-1]
        self.assertEqual(ev["event"], "lxmf.message")
        self.assertEqual((ev["data"]["peer"], ev["data"]["text"], ev["data"]["attachments"]), (PEER, "yo", True))
        # conversation index changed -> cursor advanced
        self.assertGreaterEqual(self.state.cursor(), 1)

        self.state.pending_put("cmd-x-0001", PHONE_KEY, "h2", PEER, "outbound")
        upd = {"type": "lxmf_message_state_updated", "lxmf_message": {"hash": "h2", "state": "delivered"}}
        await self.svc.on_event(upd)
        await self.svc.on_event(upd)      # duplicate (server rebroadcasts every second) is collapsed
        states = [e for e in self.published if e["event"] == "lxmf.state"]
        self.assertEqual(len(states), 1)
        self.assertEqual(states[0]["data"]["cmd_id"], "cmd-x-0001")
        self.assertIsNone(self.state.pending_by_hash("h2"))       # terminal state clears the pending ack

        await self.svc.on_event({"type": "rrc.message", "hub_hash": HUB, "room": "general", "mention": True,
                                 "message": {"seq": 7, "kind": "msg", "nick": "bob", "text": "@me hi", "ts": 5}})
        ev = self.published[-1]
        self.assertEqual((ev["event"], ev["data"]["mention"], ev["data"]["seq"]), ("rrc.message", True, 7))

    async def test_resync_publishes_and_repolls_pending(self):
        m = self.fake.add_message(PEER, "out", incoming=False, state="delivered")
        self.state.pending_put("cmd-x-0002", PHONE_KEY, m["hash"], PEER, "outbound")
        self.fake.conversations.append(conversation(PEER))
        await self.svc.on_resync()
        names = [e["event"] for e in self.published]
        self.assertIn("lxmf.state", names)
        self.assertEqual(names[-1], "resync")


if __name__ == "__main__":
    unittest.main()
