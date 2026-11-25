import os
import tempfile
import unittest

from kestrel_bridge.config import ConfigError, load_config, parse_config
from tests.helpers import PHONE_KEY


class ConfigTest(unittest.TestCase):
    def base(self):
        return {
            "meshchatx": {"base_url": "http://127.0.0.1:8000", "password_env": "X"},
            "whitelist": {"phone_public_keys": [PHONE_KEY]},
        }

    def test_valid_defaults(self):
        cfg = parse_config(self.base())
        self.assertEqual(cfg.whitelist, (PHONE_KEY,))
        self.assertTrue(cfg.rns.require_shared_instance)
        self.assertEqual(cfg.push.unknown_profile, "constrained")

    def test_whitelist_normalised_and_deduplicated(self):
        raw = self.base()
        raw["whitelist"]["phone_public_keys"] = [PHONE_KEY.upper(), PHONE_KEY]
        self.assertEqual(parse_config(raw).whitelist, (PHONE_KEY,))

    def test_bad_whitelist_key(self):
        for bad in ("abc", "zz" * 64, "ab" * 32, 5):
            raw = self.base()
            raw["whitelist"]["phone_public_keys"] = [bad]
            with self.assertRaises(ConfigError, msg=repr(bad)):
                parse_config(raw)

    def test_empty_whitelist(self):
        raw = self.base()
        raw["whitelist"]["phone_public_keys"] = []
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_password_source_exactly_one(self):
        raw = self.base()
        raw["meshchatx"]["password_file"] = "/x"
        with self.assertRaises(ConfigError):
            parse_config(raw)
        del raw["meshchatx"]["password_file"], raw["meshchatx"]["password_env"]
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_url_validation(self):
        for bad in ("ftp://x", "not a url", "http://user:pw@host:1"):
            raw = self.base()
            raw["meshchatx"]["base_url"] = bad
            with self.assertRaises(ConfigError, msg=bad):
                parse_config(raw)

    def test_unknown_keys_rejected(self):
        raw = self.base()
        raw["limits"] = {"max_text_byts": 1}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_shared_instance_cannot_be_disabled(self):
        raw = self.base()
        raw["rns"] = {"require_shared_instance": False}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_journal_ttl_must_exceed_window(self):
        raw = self.base()
        raw["limits"] = {"lxmf_ts_window": 1000, "journal_ttl": 500}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_bad_profile_and_numbers(self):
        raw = self.base()
        raw["push"] = {"unknown_profile": "lora"}
        with self.assertRaises(ConfigError):
            parse_config(raw)
        raw = self.base()
        raw["limits"] = {"page_max": 0}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_password_from_file_and_env(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "pw")
            with open(p, "w") as f:
                f.write("s3cret\n")
            raw = self.base()
            raw["meshchatx"] = {"base_url": "http://h:1", "password_file": p}
            self.assertEqual(parse_config(raw).meshchatx.read_password(), "s3cret")
        os.environ["KESTREL_T_PW"] = "envpw"
        raw = self.base()
        raw["meshchatx"] = {"base_url": "http://h:1", "password_env": "KESTREL_T_PW"}
        self.assertEqual(parse_config(raw).meshchatx.read_password(), "envpw")
        del os.environ["KESTREL_T_PW"]
        with self.assertRaises(ConfigError):
            parse_config(raw).meshchatx.read_password()

    def test_example_config_is_valid(self):
        path = os.path.join(os.path.dirname(__file__), "..", "config.example.toml")
        cfg = load_config(path)
        self.assertEqual(len(cfg.whitelist), 1)

    def test_load_errors(self):
        with self.assertRaises(ConfigError):
            load_config("/nonexistent/file.toml")


if __name__ == "__main__":
    unittest.main()
