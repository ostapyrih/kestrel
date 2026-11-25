import os
import unittest

from kestrel_bridge import errors
from kestrel_bridge.errors import BridgeError
from kestrel_bridge.meshchatx_client import MeshChatXClient
from tests.fake_meshchatx import PASSWORD, FakeMeshChatX, conversation
from tests.helpers import FakeClock, start_fake


class ClientTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        os.environ["KESTREL_TEST_PASSWORD"] = PASSWORD
        self.fake = FakeMeshChatX()
        self.server, self.cfg = await start_fake(self.fake)
        self.clock = FakeClock()
        self.client = MeshChatXClient(self.cfg.meshchatx, clock=self.clock)

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()

    async def test_login_flow_and_csrf_rotation(self):
        self.fake.conversations.append(conversation("aa" * 16))
        convs = await self.client.list_conversations()
        self.assertEqual(len(convs), 1)
        self.assertEqual(self.fake.logins, 1)
        # a POST only works because the CSRF token was re-fetched after login (it rotates)
        lm = await self.client.send_lxmf("bb" * 16, "hi", "direct")
        self.assertEqual(len(lm["hash"]), 32)
        self.assertEqual(self.fake.sent[0]["method"], "direct")

    async def test_relogin_on_401_and_never_logout(self):
        await self.client.list_conversations()
        self.fake.kill_sessions()
        await self.client.list_conversations()
        self.assertEqual(self.fake.logins, 2)
        await self.client.close()
        self.assertNotIn("/api/v1/auth/logout", [p for _, p in self.fake.calls])
        self.assertFalse(hasattr(self.client, "logout"))

    async def test_csrf_invalid_refreshes_token(self):
        await self.client.list_conversations()
        self.fake.drop_csrf_once = True
        lm = await self.client.send_lxmf("bb" * 16, "hi", None)
        self.assertTrue(lm["hash"])

    async def test_wrong_password_backs_off(self):
        self.fake.password = "other"
        with self.assertRaises(BridgeError) as c:
            await self.client.list_conversations()
        self.assertEqual(c.exception.code, errors.UPSTREAM_AUTH)
        attempts = self.fake.calls.count(("POST", "/api/v1/auth/login"))
        with self.assertRaises(BridgeError) as c:
            await self.client.list_conversations()
        self.assertEqual(c.exception.code, errors.UPSTREAM_UNAVAILABLE)  # in backoff window, no new attempt
        self.assertEqual(self.fake.calls.count(("POST", "/api/v1/auth/login")), attempts)
        self.clock.advance(1000)
        self.fake.password = PASSWORD
        await self.client.list_conversations()   # backoff expired, correct password works
        self.assertEqual(self.fake.logins, 1)

    async def test_backoff_grows_exponentially(self):
        client = MeshChatXClient(self.cfg.meshchatx, clock=self.clock)
        await self.server.close()    # upstream down
        delays = []
        for _ in range(3):
            with self.assertRaises(BridgeError) as c:
                await client.list_conversations()
            delays.append(c.exception.details["retry_after"])
            self.clock.advance(delays[-1] + 0.1)
        await client.close()
        self.assertEqual(delays, [1.0, 2.0, 4.0])
        self.server = type(self.server)(self.fake.app)   # so tearDown can close it
        await self.server.start_server()

    async def test_version_allowlist(self):
        info = await self.client.check_compat()
        self.assertEqual(info, {"version": "4.12.1", "api_version": 2})
        self.fake.version = "4.13.0"
        with self.assertRaises(BridgeError) as c:
            await self.client.check_compat()
        self.assertEqual(c.exception.code, errors.UPSTREAM_INCOMPATIBLE)
        self.fake.version = "4.12.3"
        self.fake.api_version = 3
        with self.assertRaises(BridgeError) as c:
            await self.client.check_compat()
        self.assertIn("api_version", c.exception.message)

    async def test_missing_keys_give_clear_error(self):
        self.fake.hubs.append({"name": "no hub_hash"})
        with self.assertRaises(BridgeError) as c:
            await self.client.rrc_hubs()
        self.assertEqual(c.exception.code, errors.UPSTREAM_INCOMPATIBLE)
        self.assertIn("hub_hash", c.exception.message)

    async def test_send_failure_mapped(self):
        with self.assertRaises(BridgeError) as c:
            await self.client.send_lxmf("f" * 32, "x", None)
        self.assertEqual(c.exception.code, errors.SEND_FAILED)
        self.assertIn("No path", c.exception.message)

    async def test_wait_ready(self):
        client = MeshChatXClient(self.cfg.meshchatx)   # real clock: the timeout must elapse
        self.fake.network_ready = False
        with self.assertRaises(BridgeError):
            await client.wait_ready(poll=0.01, timeout=0.05)
        self.fake.network_ready = True
        st = await client.wait_ready(poll=0.01, timeout=5)
        await client.close()
        self.assertTrue(st["network_ready"])


if __name__ == "__main__":
    unittest.main()
