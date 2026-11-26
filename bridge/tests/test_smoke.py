import os
import subprocess
import sys
import unittest

import kestrel_bridge

BRIDGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class SmokeTest(unittest.TestCase):
    def test_version(self):
        self.assertRegex(kestrel_bridge.__version__, r"^\d+\.\d+\.\d+$")

    def test_cli_version(self):
        out = subprocess.run([sys.executable, "-m", "kestrel_bridge", "--version"],
                             capture_output=True, text=True, check=True, cwd=BRIDGE_DIR).stdout
        self.assertIn(kestrel_bridge.__version__, out)

    def test_check_config_reports_missing_password_cleanly(self):
        r = subprocess.run([sys.executable, "-m", "kestrel_bridge", "--check-config", "--config",
                            "config.example.toml"], capture_output=True, text=True, cwd=BRIDGE_DIR)
        # the example points at a password file that does not exist -> clean config error, exit 2
        self.assertEqual(r.returncode, 2)
        self.assertIn("password", r.stderr)


if __name__ == "__main__":
    unittest.main()
