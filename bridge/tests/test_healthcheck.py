import contextlib
import io
import json
import os
import tempfile
import time
import unittest

from kestrel_bridge.__main__ import EXIT_DEGRADED, EXIT_OK, EXIT_UNHEALTHY, cmd_healthcheck
from tests.helpers import raw_config


class HealthcheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = raw_config(state_dir=self.tmp.name)

    def beat(self, age=0.0, **fields):
        h = {"ts": time.time(), "rns_online": True, "meshchatx_reachable": True, **fields}
        with open(self.cfg.health_path, "w") as f:
            json.dump(h, f)
        t = time.time() - age
        os.utime(self.cfg.health_path, (t, t))

    def run_check(self, strict=False):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cmd_healthcheck(self.cfg, strict)
        return code, out.getvalue().strip()

    def test_ok(self):
        self.beat()
        self.assertEqual(self.run_check(), (EXIT_OK, "ok"))

    def test_no_heartbeat_or_stale_is_unhealthy(self):
        self.assertEqual(self.run_check()[0], EXIT_UNHEALTHY)
        self.beat(age=200)
        self.assertEqual(self.run_check()[0], EXIT_UNHEALTHY)

    def test_meshchatx_down_is_degraded_but_exit_0(self):
        self.beat(meshchatx_reachable=False)
        code, text = self.run_check()
        self.assertEqual(code, EXIT_OK)                  # Docker must not flap while MeshChatX restarts
        self.assertIn("degraded", text)
        self.assertIn("MeshChatX", text)

    def test_rns_offline_is_degraded(self):
        self.beat(rns_online=False)
        code, text = self.run_check()
        self.assertEqual(code, EXIT_OK)
        self.assertIn("RNS interface offline", text)

    def test_strict_reports_degraded_with_exit_3(self):
        self.beat(meshchatx_reachable=False, rns_online=False)
        code, text = self.run_check(strict=True)
        self.assertEqual(code, EXIT_DEGRADED)
        self.assertIn("RNS interface offline", text)
        self.assertIn("MeshChatX unreachable", text)

    def test_legacy_plain_timestamp_file_counts_as_ok(self):
        with open(self.cfg.health_path, "w") as f:
            f.write(str(time.time()))
        self.assertEqual(self.run_check(), (EXIT_OK, "ok"))


if __name__ == "__main__":
    unittest.main()
