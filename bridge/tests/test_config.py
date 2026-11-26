import os
import tempfile
import unittest

from kestrel_bridge.config import ConfigError, load_config, parse_config
from tests.helpers import OTHER_KEY, PHONE_ID, PHONE_KEY, raw_config


class ConfigTest(unittest.TestCase):
    def base(self):
        return {
            "meshchatx": {"base_url": "http://127.0.0.1:8000", "password_env": "X"},
            "devices": [{"public_key": PHONE_KEY, "name": "phone-1", "platform": "android", "roles": ["field"]}],
        }

    def test_valid_defaults(self):
        cfg = parse_config(self.base())
        self.assertEqual([(d.public_key, d.name, d.platform, d.roles) for d in cfg.devices],
                         [(PHONE_KEY, "phone-1", "android", ("field",))])
        self.assertEqual(cfg.warnings, ())
        self.assertEqual(cfg.rns.mode, "standalone")
        self.assertEqual(cfg.push.profile, "auto")
        self.assertEqual(cfg.push.unknown_profile, "constrained")
        self.assertEqual((cfg.push.full_max_rtt, cfg.push.full_min_link_mtu), (1.5, 1000))

    def test_legacy_whitelist_becomes_bootstrap_devices_with_warning(self):
        raw = self.base()
        del raw["devices"]
        raw["whitelist"] = {"phone_public_keys": [PHONE_KEY.upper(), PHONE_KEY, OTHER_KEY]}
        cfg = parse_config(raw)
        self.assertEqual([d.public_key for d in cfg.devices], [PHONE_KEY, OTHER_KEY])   # normalised, deduplicated
        self.assertEqual(cfg.devices[0].name, f"device-{PHONE_ID[:6]}")
        self.assertEqual(cfg.devices[0].roles, ())
        self.assertEqual(len(cfg.warnings), 1)
        self.assertIn("deprecated", cfg.warnings[0])

    def test_bad_legacy_whitelist_key(self):
        for bad in ("abc", "zz" * 64, "ab" * 32, 5):
            raw = self.base()
            del raw["devices"]
            raw["whitelist"] = {"phone_public_keys": [bad]}
            with self.assertRaises(ConfigError, msg=repr(bad)):
                parse_config(raw)

    def test_devices_and_whitelist_are_merged(self):
        raw = self.base()
        raw["whitelist"] = {"phone_public_keys": [PHONE_KEY, OTHER_KEY]}
        cfg = parse_config(raw)
        self.assertEqual([d.public_key for d in cfg.devices], [PHONE_KEY, OTHER_KEY])
        self.assertEqual(cfg.devices[0].name, "phone-1")        # the [[devices]] entry wins

    def test_bad_device_entries(self):
        good = {"public_key": PHONE_KEY, "name": "n", "platform": "ios"}
        for bad in ({**good, "public_key": "abc"}, {**good, "public_key": "zz" * 64}, {**good, "public_key": 5},
                    {**good, "name": ""}, {**good, "name": "a\nb"}, {**good, "platform": "Not Valid"},
                    {**good, "roles": ["admin"]}, {**good, "roles": "field"}, {**good, "extra": 1}):
            raw = self.base()
            raw["devices"] = [bad]
            with self.assertRaises(ConfigError, msg=repr(bad)):
                parse_config(raw)
        raw = self.base()
        raw["devices"] = [good, good]
        with self.assertRaises(ConfigError):
            parse_config(raw)
        raw["devices"] = "x"
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_at_least_one_bootstrap_device(self):
        raw = self.base()
        raw["devices"] = []
        with self.assertRaises(ConfigError):
            parse_config(raw)
        raw["whitelist"] = {"phone_public_keys": []}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_v2_limits(self):
        raw = self.base()
        raw["limits"] = {"pairing_window": 601}
        with self.assertRaises(ConfigError):
            parse_config(raw)
        raw["limits"] = {"pairing_window": 120, "vault_max_blob_bytes": 4096, "max_devices": 4}
        lim = parse_config(raw).limits
        self.assertEqual((lim.pairing_window, lim.vault_max_blob_bytes, lim.max_devices), (120, 4096, 4))

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
        raw["rns"] = {"mode": "shared", "require_shared_instance": False}
        with self.assertRaises(ConfigError):
            parse_config(raw)

    def test_push_profile_override_and_thresholds(self):
        for good in ("auto", "full", "constrained"):
            raw = self.base()
            raw["push"] = {"profile": good, "full_max_rtt": 2, "full_min_link_mtu": 500}
            cfg = parse_config(raw)
            self.assertEqual((cfg.push.profile, cfg.push.full_max_rtt, cfg.push.full_min_link_mtu),
                             (good, 2.0, 500))
        for bad in ({"profile": "lora"}, {"full_max_rtt": 0}, {"full_min_link_mtu": 10}):
            raw = self.base()
            raw["push"] = bad
            with self.assertRaises(ConfigError, msg=repr(bad)):
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
        self.assertEqual(len(cfg.devices), 2)
        self.assertEqual(cfg.warnings, ())

    def test_load_errors(self):
        with self.assertRaises(ConfigError):
            load_config("/nonexistent/file.toml")


if __name__ == "__main__":
    unittest.main()


class StampConfigTest(unittest.TestCase):
    def test_stamping_is_off_by_default(self):
        rns = raw_config().rns
        self.assertEqual((rns.stamps, rns.stamp_destinations, rns.stamp_path_requests, rns.stamp_link_requests),
                         (False, False, False, False))

    def test_stamps_true_enables_all_three(self):
        rns = raw_config(rns={"stamps": True}).rns
        self.assertTrue(rns.stamp_destinations and rns.stamp_path_requests and rns.stamp_link_requests)

    def test_sub_options_override(self):
        rns = raw_config(rns={"stamps": True, "stamp_link_requests": False}).rns
        self.assertTrue(rns.stamp_destinations)
        self.assertFalse(rns.stamp_link_requests)
        rns = raw_config(rns={"stamp_path_requests": True}).rns
        self.assertEqual((rns.stamp_destinations, rns.stamp_path_requests), (False, True))

    def test_must_be_boolean(self):
        with self.assertRaises(ConfigError):
            raw_config(rns={"stamps": "no"})
