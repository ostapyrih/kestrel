"""upstream_step / LogThrottle in __main__: rate-limited wait_ready timeout logging."""
from __future__ import annotations

import unittest

from kestrel_bridge import errors
from kestrel_bridge.__main__ import LogThrottle, upstream_step
from kestrel_bridge.errors import BridgeError

from .helpers import FakeClock


class _Client:
    version = None

    def __init__(self):
        self.ready = False

    async def wait_ready(self, timeout=None):
        if not self.ready:
            raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "MeshChatX did not become ready")


class _Service:
    compat_ok = False

    def __init__(self):
        self.rechecks = 0

    async def recheck_compat(self):
        self.rechecks += 1
        self.compat_ok = True
        return True

    async def refresh(self, force=False):
        pass


class UpstreamStepTest(unittest.IsolatedAsyncioTestCase):
    def test_throttle(self):
        clock = FakeClock(0.0)
        t = LogThrottle(60.0, clock=clock)
        self.assertTrue(t.ready())
        clock.t = 59.0
        self.assertFalse(t.ready())
        clock.t = 61.0
        self.assertTrue(t.ready())

    async def test_wait_timeout_logged_once_per_minute(self):
        clock = FakeClock(0.0)
        throttle = LogThrottle(60.0, clock=clock)
        client, svc = _Client(), _Service()
        with self.assertLogs("kestrel", "INFO") as lg:
            for t in (0.0, 5.0, 10.0, 65.0):
                clock.t = t
                self.assertEqual(await upstream_step(svc, client, throttle), 5)
        self.assertEqual(len(lg.output), 2)
        self.assertIn("not ready", lg.output[0])
        self.assertEqual(svc.rechecks, 0)

    async def test_ready_runs_check_then_slow_recheck(self):
        client, svc = _Client(), _Service()
        client.ready = True
        self.assertEqual(await upstream_step(svc, client, LogThrottle()), 300)
        self.assertEqual(svc.rechecks, 1)
        self.assertEqual(await upstream_step(svc, client, LogThrottle()), 300)
        self.assertEqual(svc.rechecks, 2)
