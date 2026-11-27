"""/delete_chat, the chat_deleted push, tombstones in /sync_chats and MeshChatX-side deletions."""
import os
import unittest

from kestrel_bridge import errors
from kestrel_bridge.errors import BridgeError
from kestrel_bridge.service import Ctx
from tests.fake_meshchatx import conversation
from tests.helpers import PEER, PHONE_ID
from tests.test_service import ServiceBase

OTHER_PEER = "22" * 16


class DeleteChatTest(ServiceBase):
    def seed(self, peer=PEER, n=2):
        self.fake.conversations.append(conversation(peer, "Peer", "t1"))
        for i in range(n):
            self.fake.add_message(peer, f"m{i}", incoming=(i % 2 == 0))

    def deleted_events(self):
        return [e for e in self.published if e["event"] == "chat_deleted"]

    async def test_hello_announces_capability(self):
        r = await self.call("/hello", {"protocol_version": 2})
        self.assertIn("delete_chat", r["result"]["capabilities"])

    async def test_delete_ok_pushes_and_forgets(self):
        self.seed()
        self.seed(OTHER_PEER, 1)
        await self.call("/sync_chats", {"cursor": 0})
        self.state.outbound_put("aa" * 16, PHONE_ID, "cmd-aaaa-0001", PEER)
        self.state.pending_put("cmd-aaaa-0001", PHONE_ID, "aa" * 16, PEER, "outbound")
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["peer"], PEER)
        self.assertGreaterEqual(r["result"]["before_ts"], 5000.0)
        self.assertEqual(self.fake.deleted_conversations, [PEER])
        self.assertNotIn(PEER, self.fake.messages)
        ev = self.deleted_events()
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["data"]["peer"], PEER)
        self.assertEqual(ev[0]["data"]["by_device"], PHONE_ID)
        self.assertEqual(ev[0]["data"]["before_ts"], r["result"]["before_ts"])
        # nothing of the peer is kept except the tombstone; other peers are untouched
        self.assertIsNone(self.state.pending_by_hash("aa" * 16))
        self.assertEqual(self.state.outbound_get_many(["aa" * 16]), {})
        self.assertEqual(self.state.conv_cursor(f"lxmf:{PEER}"), 0)
        self.assertNotEqual(self.state.conv_cursor(f"lxmf:{OTHER_PEER}"), 0)
        self.assertIn(OTHER_PEER, self.svc._lxmf_cache)
        self.assertNotIn(PEER, self.svc._lxmf_cache)

    async def test_unknown_peer(self):
        r = await self.call("/delete_chat", {"peer": OTHER_PEER})
        self.assertEqual(r["error"]["code"], errors.NOT_FOUND)
        self.assertEqual(self.fake.deleted_conversations, [])
        self.assertEqual(self.deleted_events(), [])
        r = await self.call("/delete_chat", {"peer": "xyz"})
        self.assertEqual(r["error"]["code"], errors.BAD_REQUEST)

    async def test_link_only(self):
        self.seed()
        r = await self.call("/delete_chat", {"peer": PEER},
                            Ctx(device_id=PHONE_ID, transport="lxmf", journal_reserved=True))
        self.assertEqual(r["error"]["code"], errors.UNSUPPORTED_TRANSPORT)
        self.assertEqual(self.fake.deleted_conversations, [])

    async def test_upstream_error_mapping(self):
        self.seed()
        self.fake.delete_error = (500, {"error": "boom"})
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertEqual(r["error"]["code"], errors.UPSTREAM_ERROR)
        self.assertEqual(self.deleted_events(), [])
        self.assertIn(PEER, self.fake.messages)
        self.fake.delete_error = (404, {"error": "Conversation not found"})
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertEqual(r["error"]["code"], errors.NOT_FOUND)
        self.fake.delete_error = (429, {"retry_after": 3})
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertEqual(r["error"]["code"], errors.UPSTREAM_UNAVAILABLE)
        self.fake.delete_error = None
        self.clock.advance(61)
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertTrue(r["ok"])

    async def test_rate_limit(self):
        self.cfg.limits.device_admin_rate_per_minute = 2
        for _ in range(2):
            await self.call("/delete_chat", {"peer": OTHER_PEER})     # counted even when the peer is unknown
        r = await self.call("/delete_chat", {"peer": OTHER_PEER})
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)
        self.clock.advance(61)
        r = await self.call("/delete_chat", {"peer": OTHER_PEER})
        self.assertEqual(r["error"]["code"], errors.NOT_FOUND)

    async def test_resync_does_not_resurrect(self):
        self.seed()
        first = (await self.call("/sync_chats", {"cursor": 0}))["result"]
        self.assertEqual([c["peer"] for c in first["lxmf"]], [PEER])
        await self.call("/delete_chat", {"peer": PEER})
        await self.svc.on_resync()
        await self.svc.refresh(force=True)
        # an up-to-date device sees nothing; one that was offline sees the tombstone; a full resync does too
        later = (await self.call("/sync_chats", {"cursor": first["cursor"]}))["result"]
        self.assertEqual(later["lxmf"], [])
        self.assertEqual([d["peer"] for d in later["deleted"]], [PEER])
        full = (await self.call("/sync_chats", {"cursor": 0}))["result"]
        self.assertEqual(full["lxmf"], [])
        self.assertEqual([d["peer"] for d in full["deleted"]], [PEER])
        self.assertEqual(self.state.get_last_id(f"lxmf:{PEER}"), 0)
        msgs = (await self.call("/get_messages", {"peer": PEER}))["result"]["messages"]
        self.assertEqual(msgs, [])
        # a new message starts a fresh chat; the tombstone stays next to it
        self.fake.conversations.append(conversation(PEER, "Peer", "t9"))
        self.fake.add_message(PEER, "new")
        self.clock.advance(5)
        again = (await self.call("/sync_chats", {"cursor": first["cursor"]}))["result"]
        self.assertEqual([c["peer"] for c in again["lxmf"]], [PEER])
        self.assertEqual([d["peer"] for d in again["deleted"]], [PEER])

    async def test_tombstone_is_persisted(self):
        self.seed()
        await self.call("/sync_chats", {"cursor": 0})
        r = await self.call("/delete_chat", {"peer": PEER})
        self.assertEqual(self.state.tombstone_ts(f"del:{PEER}"), r["result"]["before_ts"])

    async def test_deletion_in_meshchatx_ui_is_pushed(self):
        self.seed()
        self.seed(OTHER_PEER, 1)
        await self.call("/sync_chats", {"cursor": 0})
        # the user deletes the conversation in the MeshChatX web UI
        gone = self.fake.messages.pop(PEER)
        self.fake.conversations[:] = [c for c in self.fake.conversations if c["destination_hash"] != PEER]
        await self.svc.on_event({"type": "lxmf_message_deleted", "lxmf_message": {"hash": gone[0]["hash"]}})
        ev = self.deleted_events()
        self.assertEqual([e["data"]["peer"] for e in ev], [PEER])
        self.assertIsNone(ev[0]["data"]["by_device"])
        self.assertIn("lxmf.deleted", [e["event"] for e in self.published])
        r = (await self.call("/sync_chats", {"cursor": 0}))["result"]
        self.assertEqual([c["peer"] for c in r["lxmf"]], [OTHER_PEER])
        self.assertEqual([d["peer"] for d in r["deleted"]], [PEER])

    async def test_vanished_conversation_with_messages_is_not_deleted(self):
        self.seed()
        await self.call("/sync_chats", {"cursor": 0})
        self.fake.conversations.clear()          # list glitch: the messages are still there
        await self.svc.refresh(force=True)
        self.assertEqual(self.deleted_events(), [])


class DeleteClientTest(unittest.IsolatedAsyncioTestCase):
    """Contract of the MeshChatX endpoint the bridge uses for deletion."""

    async def asyncSetUp(self):
        from kestrel_bridge.meshchatx_client import MeshChatXClient
        from tests.fake_meshchatx import PASSWORD, FakeMeshChatX
        from tests.helpers import start_fake
        os.environ["KESTREL_TEST_PASSWORD"] = PASSWORD
        self.fake = FakeMeshChatX()
        self.server, self.cfg = await start_fake(self.fake)
        self.client = MeshChatXClient(self.cfg.meshchatx)

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()

    async def test_delete_conversation_uses_delete_with_csrf(self):
        self.fake.add_message(PEER, "x")
        await self.client.delete_conversation(PEER)       # DELETE needs the rotated CSRF token (403 otherwise)
        self.assertIn(("DELETE", f"/api/v1/lxmf-messages/conversation/{PEER}"), self.fake.calls)
        self.assertEqual(self.fake.deleted_conversations, [PEER])

    async def test_404_is_not_found_and_500_is_upstream_error(self):
        with self.assertRaises(BridgeError) as cm:
            await self.client.delete_conversation(PEER)
        self.assertEqual(cm.exception.code, errors.NOT_FOUND)
        self.fake.delete_error = (500, {"error": "boom"})
        with self.assertRaises(BridgeError) as cm:
            await self.client.delete_conversation(PEER)
        self.assertEqual(cm.exception.code, errors.UPSTREAM_ERROR)


if __name__ == "__main__":
    unittest.main()
