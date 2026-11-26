"""MeshChatX is restarted/recreated (image auto-update): the bridge must recover without a restart.

The fake server is stopped (connections are refused for a while), then a NEW fake process-like instance
(empty sessions, fresh CSRF tokens) comes up on the same host:port, as it would after a container
recreate behind a stable Docker DNS name.
"""
import asyncio
import os
import unittest

from aiohttp.test_utils import TestServer

from kestrel_bridge import errors
from kestrel_bridge.errors import BridgeError
from kestrel_bridge.meshchatx_client import MeshChatXClient
from kestrel_bridge.ws_events import WsEvents
from tests.fake_meshchatx import PASSWORD, FakeMeshChatX, conversation
from tests.helpers import start_fake


class RestartTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        os.environ["KESTREL_TEST_PASSWORD"] = PASSWORD
        self.fake = FakeMeshChatX()
        self.server, self.cfg = await start_fake(self.fake)
        self.port = self.server.port
        self.client = MeshChatXClient(self.cfg.meshchatx)

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()

    async def stop_server(self):
        for ws in list(self.fake.ws_clients):
            await ws.close()
        await self.server.close()

    async def start_new_server(self, **flags) -> FakeMeshChatX:
        fake = FakeMeshChatX()
        for k, v in flags.items():
            setattr(fake, k, v)
        self.server = TestServer(fake.app, host="127.0.0.1", port=self.port)
        await self.server.start_server()
        self.fake = fake
        return fake

    async def until(self, cond, timeout=10.0):
        end = asyncio.get_running_loop().time() + timeout
        while not cond():
            if asyncio.get_running_loop().time() > end:
                self.fail("condition not reached")
            await asyncio.sleep(0.02)

    async def test_http_recovers_after_server_restart(self):
        self.fake.conversations.append(conversation("aa" * 16))
        self.assertEqual(len(await self.client.list_conversations()), 1)
        old_csrf = self.client._csrf

        await self.stop_server()
        for _ in range(2):                        # server down: clean, retryable error, no crash
            with self.assertRaises(BridgeError) as c:
                await self.client.list_conversations()
            self.assertEqual(c.exception.code, errors.UPSTREAM_UNAVAILABLE)
        with self.assertRaises(BridgeError) as c:
            await self.client.send_lxmf("bb" * 16, "hi", None)
        self.assertEqual(c.exception.code, errors.UPSTREAM_UNAVAILABLE)

        fake = await self.start_new_server()      # new process: no sessions, new CSRF secret
        fake.conversations.append(conversation("cc" * 16))
        convs = await self.client.list_conversations()        # old cookie -> 401 -> re-login
        self.assertEqual([c["destination_hash"] for c in convs], ["cc" * 16])
        self.assertEqual(fake.logins, 1)
        self.assertNotEqual(self.client._csrf, old_csrf)
        lm = await self.client.send_lxmf("bb" * 16, "after restart", "direct")   # POST works with the new CSRF
        self.assertTrue(lm["hash"])
        self.assertEqual([s["text"] for s in fake.sent], ["after restart"])
        self.assertNotIn("/api/v1/auth/logout", [p for _, p in fake.calls])

    async def test_post_after_restart_when_server_answers_csrf_invalid_first(self):
        await self.client.list_conversations()
        await self.stop_server()
        fake = await self.start_new_server(csrf_before_auth=True)   # stale cookie + POST -> 403, not 401
        lm = await self.client.send_lxmf("bb" * 16, "hi", None)
        self.assertTrue(lm["hash"])
        self.assertEqual(fake.logins, 1)

    async def test_open_ws_recovers_after_server_restart(self):
        ws = await self.client.open_ws()
        await ws.close()
        await self.stop_server()
        with self.assertRaises(BridgeError) as c:
            await self.client.open_ws()
        self.assertEqual(c.exception.code, errors.UPSTREAM_UNAVAILABLE)
        fake = await self.start_new_server()
        ws = await self.client.open_ws()          # handshake 401 with the stale cookie -> re-login -> ok
        self.assertFalse(ws.closed)
        self.assertEqual(fake.logins, 1)
        await ws.close()

    async def test_ws_layer_reconnects_and_resyncs_after_restart(self):
        events, resyncs = [], []

        async def on_event(ev):
            events.append(ev["type"])

        async def on_resync():
            resyncs.append(1)

        ws = WsEvents(self.client, on_event, on_resync, ping_interval=0.05, backoff_base=0.05, backoff_max=0.2)
        task = asyncio.create_task(ws.run())
        await self.until(lambda: len(self.fake.ws_clients) == 1)
        await self.fake.emit({"type": "lxmf.delivery", "lxmf_message": {}})
        await self.until(lambda: events == ["lxmf.delivery"])

        await self.stop_server()
        await self.until(lambda: not ws.connected)
        await asyncio.sleep(0.3)                  # several refused reconnect attempts
        self.assertEqual(resyncs, [])
        fake = await self.start_new_server()
        await self.until(lambda: len(fake.ws_clients) == 1 and ws.connected)
        await self.until(lambda: len(resyncs) == 1)
        await fake.emit({"type": "lxmf.delivery", "lxmf_message": {}})
        await self.until(lambda: events == ["lxmf.delivery", "lxmf.delivery"])
        self.assertEqual(fake.logins, 1)
        ws.stop()
        await fake.ws_clients[0].close()
        await asyncio.wait_for(task, 5)


if __name__ == "__main__":
    unittest.main()
