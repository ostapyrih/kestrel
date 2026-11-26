import os
import tempfile
import unittest

from kestrel_bridge.config import ConfigError, RnsConfig, parse_config
from kestrel_bridge.rns_setup import AnnounceWatcher, prepare_rns_config, render_standalone_config
from tests.helpers import FakeClock, raw_config


class FakeInterface:
    def __init__(self, online=True):
        self.online = online
        self.socket = object()

    def drop(self):
        self.online = False

    def reconnect(self):
        self.online = True
        self.socket = object()   # RNS creates a new socket object on every (re)connect


class RenderConfigTest(unittest.TestCase):
    def test_standalone_defaults(self):
        text = render_standalone_config(raw_config().rns)
        self.assertIn("share_instance = No", text)
        self.assertIn("enable_transport = No", text)
        self.assertIn("type = TCPClientInterface", text)
        self.assertIn("target_host = meshchatx", text)
        self.assertIn("target_port = 4242", text)
        self.assertNotIn("passphrase", text)
        self.assertNotIn("network_name", text)

    def test_ifac_and_custom_target(self):
        rns = raw_config(rns={"tcp_host": "10.1.2.3", "tcp_port": 4343, "ifac_name": "my net"}).rns
        text = render_standalone_config(rns, "pass phrase")
        self.assertIn("target_host = 10.1.2.3", text)
        self.assertIn("target_port = 4343", text)
        self.assertIn('network_name = "my net"', text)
        self.assertIn('passphrase = "pass phrase"', text)

    def test_generated_config_parses_with_rns_parser(self):
        from RNS.vendor.configobj import ConfigObj
        rns = raw_config(rns={"ifac_name": "net"}).rns
        c = ConfigObj(render_standalone_config(rns, "p,w #x").splitlines())
        iface = c["interfaces"]["MeshChatX"]
        self.assertEqual(iface["target_host"], "meshchatx")
        self.assertEqual(iface["network_name"], "net")
        self.assertEqual(iface["passphrase"], "p,w #x")    # commas/# survive thanks to quoting
        self.assertEqual(c["reticulum"]["share_instance"], "No")

    def test_passphrase_with_both_quote_kinds_refused(self):
        with self.assertRaises(ConfigError):
            render_standalone_config(RnsConfig(), "a\"b'c")
        with self.assertRaises(ConfigError):
            render_standalone_config(RnsConfig(), "a\nb")


class PrepareConfigTest(unittest.TestCase):
    def test_standalone_regenerated_every_start_with_passphrase_from_file(self):
        with tempfile.TemporaryDirectory() as d:
            pf = os.path.join(d, "ifac")
            with open(pf, "w") as f:
                f.write("s3cret\n")
            rns = raw_config(rns={"config_dir": os.path.join(d, "rns"), "ifac_name": "n",
                                  "ifac_passphrase_file": pf}).rns
            path = prepare_rns_config(rns)
            self.assertIn('passphrase = "s3cret"', open(path).read())
            with open(path, "w") as f:
                f.write("hand edited")
            prepare_rns_config(rns)
            self.assertIn("TCPClientInterface", open(path).read())
            self.assertFalse(os.path.exists(path + ".tmp"))
            if os.name == "posix":
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_missing_or_empty_passphrase_file(self):
        with tempfile.TemporaryDirectory() as d:
            rns = raw_config(rns={"config_dir": d, "ifac_passphrase_file": os.path.join(d, "nope")}).rns
            with self.assertRaises(ConfigError):
                prepare_rns_config(rns)
            empty = os.path.join(d, "empty")
            open(empty, "w").close()
            rns = raw_config(rns={"config_dir": d, "ifac_passphrase_file": empty}).rns
            with self.assertRaises(ConfigError):
                prepare_rns_config(rns)

    def test_shared_mode_keeps_existing_config_and_creates_minimal(self):
        with tempfile.TemporaryDirectory() as d:
            rns = raw_config(rns={"mode": "shared", "config_dir": d}).rns
            path = prepare_rns_config(rns)
            text = open(path).read()
            self.assertIn("share_instance = Yes", text)
            self.assertNotIn("TCPClientInterface", text)
            with open(path, "w") as f:
                f.write("mine")
            prepare_rns_config(rns)
            self.assertEqual(open(path).read(), "mine")


class AnnounceWatcherTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock(0.0)
        self.announced = 0
        self.iface = FakeInterface(online=False)

    def announce(self):
        self.announced += 1

    def watcher(self, interval=1800):
        return AnnounceWatcher(self.announce, lambda: [self.iface], interval, clock=self.clock, follow_ups=())

    def test_announces_once_the_interface_is_online_not_before(self):
        w = self.watcher()
        self.assertFalse(w.tick())
        self.clock.advance(5000)
        self.assertFalse(w.tick())          # offline: never announces, whatever the time
        self.iface.reconnect()
        self.assertTrue(w.tick())           # startup announce as soon as the TCP link is up
        self.assertFalse(w.tick())
        self.assertEqual(self.announced, 1)

    def test_periodic(self):
        self.iface.reconnect()
        w = self.watcher(interval=1800)
        self.assertTrue(w.tick())
        self.clock.advance(1799)
        self.assertFalse(w.tick())
        self.clock.advance(2)
        self.assertTrue(w.tick())
        self.assertEqual(self.announced, 2)

    def test_reannounce_after_reconnect(self):
        self.iface.reconnect()
        w = self.watcher()
        w.tick()
        self.clock.advance(10)
        self.iface.drop()
        self.assertFalse(w.tick())          # offline: nothing to send
        self.clock.advance(10)
        self.iface.reconnect()
        self.assertTrue(w.tick())           # far below the periodic interval, still announced
        self.assertEqual(self.announced, 2)

    def test_reconnect_faster_than_poll_is_detected_by_new_socket(self):
        self.iface.reconnect()
        w = self.watcher()
        w.tick()
        self.iface.drop()
        self.iface.reconnect()              # offline period never observed
        self.assertTrue(w.tick())
        self.assertEqual(self.announced, 2)

    def test_follow_up_announces_after_start_and_after_reconnect(self):
        self.iface.reconnect()
        w = AnnounceWatcher(self.announce, lambda: [self.iface], 1800, clock=self.clock)   # default follow-ups
        self.assertTrue(w.tick())                       # startup
        self.clock.advance(9)
        self.assertFalse(w.tick())
        self.clock.advance(1)
        self.assertTrue(w.tick())                       # +10 s
        self.clock.advance(50)
        self.assertTrue(w.tick())                       # +60 s
        self.clock.advance(500)
        self.assertFalse(w.tick())
        self.assertEqual(self.announced, 3)
        self.iface.drop()
        w.tick()
        self.iface.reconnect()
        self.assertTrue(w.tick())                       # reconnect
        self.clock.advance(10)
        self.assertTrue(w.tick())                       # and its follow-up
        self.assertEqual(self.announced, 5)

    def test_follow_ups_are_dropped_while_offline(self):
        self.iface.reconnect()
        w = AnnounceWatcher(self.announce, lambda: [self.iface], 1800, clock=self.clock)
        w.tick()
        self.iface.drop()
        self.clock.advance(100)
        self.assertFalse(w.tick())
        self.assertEqual(self.announced, 1)

    def test_failed_announce_is_retried_next_tick(self):
        self.iface.reconnect()
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) == 1:
                raise RuntimeError("boom")

        w = AnnounceWatcher(flaky, lambda: [self.iface], 1800, clock=self.clock, follow_ups=())
        self.assertFalse(w.tick())
        self.assertTrue(w.tick())
        self.assertEqual(len(calls), 2)

    def test_untracked_interfaces_means_periodic_only(self):
        w = AnnounceWatcher(self.announce, None, 100, clock=self.clock, follow_ups=())
        self.assertTrue(w.tick())
        self.assertFalse(w.tick())
        self.clock.advance(101)
        self.assertTrue(w.tick())


class ModeConfigTest(unittest.TestCase):
    def base(self):
        return {"meshchatx": {"base_url": "http://meshchatx:8000", "password_env": "X"},
                "whitelist": {"phone_public_keys": ["ab" * 64]}}

    def test_standalone_is_default_with_sane_defaults(self):
        r = parse_config(self.base()).rns
        self.assertEqual((r.mode, r.tcp_host, r.tcp_port), ("standalone", "meshchatx", 4242))
        self.assertEqual(r.announce_interval, 1800)
        self.assertIsNone(r.ifac_name)

    def test_standalone_full(self):
        raw = self.base()
        raw["rns"] = {"mode": "standalone", "tcp_host": "mc.internal", "tcp_port": 4343, "ifac_name": "n",
                      "ifac_passphrase_file": "/run/secrets/ifac", "announce_interval": 600}
        r = parse_config(raw).rns
        self.assertEqual((r.tcp_host, r.tcp_port, r.ifac_name, r.ifac_passphrase_file, r.announce_interval),
                         ("mc.internal", 4343, "n", "/run/secrets/ifac", 600))

    def test_standalone_rejects_bad_values(self):
        for bad in ({"tcp_port": 0}, {"tcp_port": 70000}, {"tcp_port": "4242"}, {"tcp_host": ""},
                    {"tcp_host": "a b"}, {"tcp_host": 'a"b'}, {"mode": "bogus"}, {"ifac_name": "a\nb"},
                    {"ifac_name": "a\"b'c"}, {"require_shared_instance": True}, {"ifac_passphrase": "inline"}):
            raw = self.base()
            raw["rns"] = bad
            with self.assertRaises(ConfigError, msg=repr(bad)):
                parse_config(raw)

    def test_shared_mode(self):
        raw = self.base()
        raw["rns"] = {"mode": "shared"}
        r = parse_config(raw).rns
        self.assertEqual(r.mode, "shared")
        self.assertTrue(r.require_shared_instance)

    def test_shared_mode_rejects_standalone_keys_and_disabled_require(self):
        for bad in ({"tcp_host": "x"}, {"tcp_port": 1}, {"ifac_name": "n"}, {"ifac_passphrase_file": "/f"},
                    {"require_shared_instance": False}):
            raw = self.base()
            raw["rns"] = {"mode": "shared", **bad}
            with self.assertRaises(ConfigError, msg=repr(bad)):
                parse_config(raw)


if __name__ == "__main__":
    unittest.main()
