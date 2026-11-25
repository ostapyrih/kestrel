import asyncio
import os
import unittest

from kestrel_bridge.meshchatx_client import MeshChatXClient
from kestrel_bridge.ws_events import UNWANTED_TOPICS, WsEvents
from tests.fake_meshchatx import PASSWORD, FakeMeshChatX
from tests.helpers import start_fake


class WsEventsTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        os.environ["KESTREL_TEST_PASSWORD"] = PASSWORD
        self.fake = FakeMeshChatX()
        self.server, self.cfg = await start_fake(self.fake)
        self.client = MeshChatXClient(self.cfg.meshchatx)
        self.events, self.resyncs = [], 0

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()

    async def until(self, cond, timeout=5.0):
        end = asyncio.get_running_loop().time() + timeout
        while not cond():
            if asyncio.get_running_loop().time() > end:
                self.fail("condition not reached")
            await asyncio.sleep(0.02)

    async def test_subscribes_only_lxmf_rrc_filters_and_resyncs_after_reconnect(self):
        async def on_event(ev):
            self.events.append(ev["type"])

        async def on_resync():
            self.resyncs += 1

        ws = WsEvents(self.client, on_event, on_resync, ping_interval=0.05, backoff_base=0.05)
        task = asyncio.create_task(ws.run())
        await self.until(lambda: len(self.fake.ws_clients) == 1)
        await self.until(lambda: any(m.get("type") == "ws.unsubscribe" for m in self.fake.ws_inbound))
        unsub = next(m for m in self.fake.ws_inbound if m.get("type") == "ws.unsubscribe")
        self.assertEqual(unsub["topics"], UNWANTED_TOPICS)
        self.assertNotIn("lxmf", unsub["topics"])
        self.assertNotIn("rrc", unsub["topics"])
        await self.until(lambda: any(m.get("type") == "ping" for m in self.fake.ws_inbound))   # keepalive
        self.assertEqual(self.resyncs, 0)                       # first connect: no resync needed

        await self.fake.emit({"type": "announce", "announce": {}})            # ignored
        await self.fake.emit({"type": "lxmf.delivery", "lxmf_message": {}})
        await self.until(lambda: self.events == ["lxmf.delivery"])

        # connection drops AND the session was invalidated: reconnect must re-login, then resync
        self.fake.kill_sessions()
        for c in list(self.fake.ws_clients):
            await c.close()
        await self.until(lambda: self.resyncs == 1 and len(self.fake.ws_clients) == 1, timeout=10)
        self.assertEqual(self.fake.logins, 2)
        self.assertNotIn("/api/v1/auth/logout", [p for _, p in self.fake.calls])
        ws.stop()
        await self.fake.ws_clients[0].close()
        await asyncio.wait_for(task, 5)


if __name__ == "__main__":
    unittest.main()
