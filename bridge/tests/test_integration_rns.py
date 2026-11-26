"""End-to-end test with real Reticulum. Skipped unless KESTREL_IT=1.

Standalone mode: subprocesses are a Reticulum transport node with a TCPServerInterface on 127.0.0.1
(standing in for MeshChatX's RNS), a fake MeshChatX HTTP/WS server, the sidecar (own RNS instance,
TCP client to the transport node) and a Python client in the role of the phone identity B
(see tests/it_client_b.py), also a TCP client of the transport node.

Protocol v2 (multi-device): the phone B1 is the only bootstrap device in the config. The driver builds the
pairing QR text of a second device B2, B1 approves it over its identified Link, B2 (unknown to the config)
then connects, sees the message B1 sent with origin_device = B1, and B1 revokes it: B2's Link must be closed
and its key refused.

Part 2 kills and restarts the transport node (a MeshChatX container recreate): the sidecar must
reconnect and re-announce by itself, and B must be able to call /hello again.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

from kestrel_bridge.devices import encode_pairing_qr

BRIDGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PEER = "11" * 16


CLIENT_RNS_CONFIG = """[reticulum]
  enable_transport = No
  share_instance = No

[interfaces]
  [[To Test Server]]
    type = TCPClientInterface
    enabled = yes
    target_host = 127.0.0.1
    target_port = {tcp_port}
"""


def _safe(text: str) -> str:
    return text.encode("ascii", "replace").decode("ascii")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Proc:
    def __init__(self, name, args):
        self.name = name
        self.lines: list[str] = []
        self.p = subprocess.Popen([sys.executable, "-u", *args], cwd=BRIDGE_DIR, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.lines.append(line.rstrip())

    def wait_for(self, needle, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for line in list(self.lines):
                if needle in line:
                    return line
            if self.p.poll() is not None:
                break
            time.sleep(0.1)
        raise AssertionError(f"{self.name}: '{needle}' not seen; output:\n" + "\n".join(self.lines[-40:]))

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()


def http(method, url, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"{}")


@unittest.skipUnless(os.environ.get("KESTREL_IT") == "1", "set KESTREL_IT=1 to run the Reticulum integration test")
class IntegrationTest(unittest.TestCase):
    def setUp(self):
        self.procs: list[Proc] = []
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(self.tmp.cleanup)    # cleanups run LIFO: processes are stopped first
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        for p in reversed(self.procs):
            p.stop()

    def _dump_logs(self):
        for p in self.procs:
            keep = [l for l in p.lines if re.search(r"nnounce|path|nterface|link|error|warn|conn", l, re.I)]
            print(_safe(f"---- {p.name} ----\n" + "\n".join((keep or p.lines)[-80:])))

    def spawn(self, name, args):
        p = Proc(name, args)
        self.procs.append(p)
        return p

    def test_end_to_end(self):
        import RNS
        d = self.tmp.name
        tcp_port, fake_port = (free_port() for _ in range(2))

        # identity of the phone B
        b_id = RNS.Identity()
        b_file = os.path.join(d, "b.identity")
        b_id.to_file(b_file)
        b_pub = b_id.get_public_key().hex()
        b_hash = b_id.hash.hex()
        # identity of the second device B2: NOT in the bridge config, it gets in by QR pairing
        b2_id = RNS.Identity()
        b2_file = os.path.join(d, "b2.identity")
        b2_id.to_file(b2_file)
        b2_hash = b2_id.hash.hex()

        # transport node (the "MeshChatX side" Reticulum) and fake MeshChatX
        transport_args = ["-m", "tests.it_transport", os.path.join(d, "transport"), str(tcp_port)]
        transport = self.spawn("transport", transport_args)
        transport.wait_for("TRANSPORT_READY", 60)
        self.spawn("fake", ["-m", "tests.fake_meshchatx", "--port", str(fake_port)])
        base = f"http://127.0.0.1:{fake_port}"
        for _ in range(100):
            try:
                http("GET", base + "/api/v1/status")
                break
            except Exception:
                time.sleep(0.1)
        http("POST", base + "/_test/seed", {
            "conversations": [{"display_name": "Peer", "custom_display_name": None, "destination_hash": PEER,
                               "is_unread": False, "failed_messages_count": 0, "latest_message_preview": "hello",
                               "latest_message_created_at": "2026-01-01T00:00:00"}],
            "messages": [{"peer": PEER, "text": "earlier message", "incoming": True}]})

        # sidecar config
        sc = os.path.join(d, "sidecar")
        os.makedirs(sc)
        pw = os.path.join(sc, "password")
        with open(pw, "w") as f:
            f.write("test-password\n")
        toml = os.path.join(sc, "bridge.toml")
        q = lambda p: p.replace("\\", "/")  # noqa: E731
        with open(toml, "w") as f:
            f.write(f"""state_dir = "{q(sc)}/state"
[meshchatx]
base_url = "{base}"
password_file = "{q(pw)}"
[[devices]]
public_key = "{b_pub}"
name = "B1"
platform = "linux"
[rns]
mode = "standalone"
config_dir = "{q(sc)}/rns"
identity_path = "{q(sc)}/identity"
lxmf_storage = "{q(sc)}/lxmf"
announce_interval = 15
log_level = {int(os.environ.get("IT_RNS_LOG", "2"))}
tcp_host = "127.0.0.1"
tcp_port = {tcp_port}
""")
        chk = subprocess.run([sys.executable, "-m", "kestrel_bridge", "--config", toml, "--print-address"],
                             cwd=BRIDGE_DIR, capture_output=True, text=True, timeout=60)
        self.assertEqual(chk.returncode, 0, chk.stderr)
        s_pub = next(l.split()[-1] for l in chk.stdout.splitlines() if l.startswith("bridge public key"))

        sidecar = self.spawn("sidecar", ["-m", "kestrel_bridge", "--config", toml])
        sidecar.wait_for("bridge running", 90)

        # phone B. Path discovery over the loopback TCP link is occasionally slow/stuck on some
        # platforms (a Reticulum-level race, not the bridge): retry with a fresh process/connection.
        client = None
        for attempt in range(3):
            bdir = os.path.join(d, f"b{attempt}")
            os.makedirs(bdir)
            with open(os.path.join(bdir, "config"), "w") as f:
                f.write(f"""[reticulum]
  enable_transport = No
  share_instance = No

[interfaces]
  [[To Test Server]]
    type = TCPClientInterface
    enabled = yes
    target_host = 127.0.0.1
    target_port = {tcp_port}
""")
            go_file = os.path.join(d, "go2")
            qr_file = os.path.join(d, "b2.qr")
            revoke_file = os.path.join(d, "revoke")
            client = self.spawn("client_b", ["-m", "tests.it_client_b", bdir, b_file, s_pub, PEER, go_file, qr_file,
                                             revoke_file])
            try:
                client.wait_for("RESULT SUBSCRIBED", 120)
                break
            except AssertionError:
                if attempt < 2 and any("TIMEOUT" in line for line in client.lines):
                    client.stop()
                    continue
                self._dump_logs()
                raise
        try:
            http("POST", base + "/_test/emit", {
                "type": "lxmf.delivery", "remote_identity_name": "Peer",
                "lxmf_message": {"hash": "ab" * 16, "source_hash": PEER, "state": "delivered",
                                 "content": "pushed hello", "timestamp": time.time(), "fields": {}}})
            client.wait_for("RESULT push", 60)

            # B2 shows its pairing QR; B1 (already paired with the bridge) approves it
            with open(qr_file, "w") as f:
                f.write(encode_pairing_qr(b2_id.get_public_key(), "Second device", "linux", os.urandom(16), time.time()))
            client.wait_for("RESULT PAIRED", 60)
            client2 = None
            for attempt in range(3):
                b2dir = os.path.join(d, f"b2-{attempt}")
                os.makedirs(b2dir)
                with open(os.path.join(b2dir, "config"), "w") as f:
                    f.write(CLIENT_RNS_CONFIG.format(tcp_port=tcp_port))
                client2 = self.spawn("client_b2", ["-m", "tests.it_client_b2", b2dir, b2_file, s_pub, PEER])
                try:
                    client2.wait_for("RESULT B2_READY", 120)
                    break
                except AssertionError:
                    if attempt < 2 and any("TIMEOUT" in line for line in client2.lines):
                        client2.stop()
                        continue
                    raise
            open(revoke_file, "w").close()          # B1 revokes B2 now
            client2.wait_for("RESULT B2_CLOSED", 60)
            client2.wait_for("RESULT DONE", 120)
            client.wait_for("RESULT PHASE1", 60)

            # part 2: the "MeshChatX" RNS goes away and comes back (container recreate)
            transport.stop()
            time.sleep(2)
            transport = self.spawn("transport2", transport_args)
            transport.wait_for("TRANSPORT_READY", 60)
            # the reconnect hook fired (a log line distinct from the periodic announce)
            sidecar.wait_for("announce emitted for kestrel.bridge (interface reconnected", 120)
            open(go_file, "w").close()
            client.wait_for("RESULT DONE", 180)
        except AssertionError:
            self._dump_logs()
            raise

        if os.environ.get("IT_RNS_LOG"):
            print(_safe("\n".join(client.lines)))
        res, res2 = {}, {}
        for lines, target in ((client.lines, res), (client2.lines, res2)):
            for line in lines:
                if line.startswith("RESULT "):
                    _, name, payload = line.split(" ", 2)
                    target[name] = json.loads(payload)

        # impostor: refused (error response or link torn down), never a successful /hello
        imp = res["impostor"]
        self.assertTrue(imp is None or imp.get("ok") is False, imp)
        # ... but it is told why: exactly one kestrel.reject packet carrying "unauthorized" and the server time
        rej = res["impostor_reject"]
        self.assertEqual([(r["t"], r["code"]) for r in rej], [("kestrel.reject", "unauthorized")])
        self.assertIsInstance(rej[0]["server_time"], float)
        self.assertEqual(res["pre_identify"]["error"]["code"], "unauthorized")
        self.assertTrue(res["hello"]["ok"])
        self.assertEqual(res["hello"]["result"]["protocol_version"], 2)
        self.assertEqual(res["hello"]["result"]["device"]["device_id"], b_hash)
        self.assertTrue(res["hello"]["result"]["device"]["bootstrap"])
        # a v1 client is told clearly what the bridge supports
        v1 = res["hello_v1"]["error"]
        self.assertEqual(v1["code"], "protocol_mismatch")
        self.assertEqual((v1["details"]["min_version"], v1["details"]["max_version"]), (2, 2))
        self.assertTrue(res["hello"]["result"]["compat"]["ok"])
        self.assertEqual([c["peer"] for c in res["sync"]["result"]["lxmf"]], [PEER])
        self.assertEqual(res["messages"]["result"]["messages"][0]["text"], "earlier message")
        self.assertTrue(res["send"]["ok"])
        self.assertEqual(len(res["send"]["result"]["lxmf_hash"]), 32)
        self.assertEqual(res["send_replay"]["error"]["code"], "replay")
        self.assertEqual(res["rrc_slash"]["error"]["code"], "rrc_command_rejected")
        self.assertTrue(res["subscribe"]["ok"])
        self.assertEqual(res["subscribe"]["result"]["profile"], "full")   # fast TCP link: RTT/MTU thresholds met
        self.assertTrue(res["hello2"]["ok"])                              # after the transport restart
        self.assertEqual(res["hello2"]["result"]["protocol_version"], 2)
        self.assertEqual(res["push"]["data"]["text"], "pushed hello")

        # pairing: B1 approved B2 (listed nowhere in the config)
        self.assertTrue(res["approve"]["ok"], res["approve"])
        dev = res["approve"]["result"]["device"]
        self.assertEqual((dev["device_id"], dev["added_by"], dev["bootstrap"], dev["roles"], dev["name"]),
                         (b2_hash, b_hash, False, ["field"], "Second device"))
        self.assertEqual(res["device_added_push"]["data"]["device"]["device_id"], b2_hash)
        # B2 works on its own identity and sees what B1 sent, attributed to B1
        h2 = res2["b2_hello"]["result"]
        self.assertEqual((h2["device"]["device_id"], h2["device"]["added_by"]), (b2_hash, b_hash))
        self.assertEqual({d["device_id"] for d in res2["b2_devices"]["result"]["devices"]}, {b_hash, b2_hash})
        sent = [m for m in res2["b2_messages"]["result"]["messages"] if m["text"] == "from phone"]
        self.assertEqual(len(sent), 1)
        self.assertEqual((sent[0]["origin_device"], sent[0]["cmd_id"], sent[0]["incoming"]),
                         (b_hash, "it-cmd-000001", False))
        earlier = [m for m in res2["b2_messages"]["result"]["messages"] if m["text"] == "earlier message"]
        self.assertIsNone(earlier[0]["origin_device"])        # not sent through the bridge: MeshChatX itself
        self.assertTrue(res2["b2_subscribe"]["ok"])
        # revocation: B1 revoked B2, the bridge closed B2's Link and refuses its key afterwards
        self.assertTrue(res["revoke"]["ok"], res["revoke"])
        self.assertEqual(res["revoke"]["result"]["key_epoch"], 2)
        self.assertEqual(res["revoked_push"][0]["data"]["device_id"], b2_hash)
        listed = {d["device_id"]: d for d in res["devices_after"]["result"]["devices"]}
        self.assertIsNotNone(listed[b2_hash]["revoked_at"])
        self.assertIsNone(listed[b_hash]["revoked_at"])
        self.assertTrue(res2["B2_CLOSED"])
        # the revoked device learned why on its live Link and again when it reconnected
        self.assertEqual([(r["t"], r["code"]) for r in res2["b2_live_reject"]], [("kestrel.reject", "device_revoked")])
        self.assertEqual([r["code"] for r in res2["b2_retry_reject"]], ["device_revoked"])
        after = res2["b2_after"]
        self.assertTrue(after is None or after.get("ok") is False, after)

        calls = http("GET", base + "/_test/calls")
        self.assertEqual([s["text"] for s in calls["sent"]], ["from phone"])   # exactly once despite the replay
        self.assertEqual(calls["logins"], 1)


if __name__ == "__main__":
    unittest.main()
