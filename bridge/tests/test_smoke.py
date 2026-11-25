import subprocess
import sys
import unittest

import kestrel_bridge


class SmokeTest(unittest.TestCase):
    def test_version(self):
        self.assertEqual(kestrel_bridge.__version__, "0.1.0")

    def test_main_prints_version(self):
        out = subprocess.run(
            [sys.executable, "-m", "kestrel_bridge"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn(kestrel_bridge.__version__, out)


if __name__ == "__main__":
    unittest.main()
