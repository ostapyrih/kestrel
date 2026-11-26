#!/usr/bin/env python3
"""Bridge test environment for the Dart integration test (app/test/bridge_integration_test.dart).

Starts, as subprocesses of ``bridge/`` (reusing its integration helpers):
a Reticulum transport node on 127.0.0.1 (stands in for MeshChatX's RNS), the fake MeshChatX
(``bridge/tests/fake_meshchatx.py``) and the real ``kestrel-bridge`` sidecar in standalone mode.
The Dart side connects to the transport node like to ``rns.ostapyrih.com``.

usage: bridge_env.py <bootstrap_device_public_key_hex>

stdout: one JSON line per event: ``ready`` first
  {"event":"ready","tcp_port":..,"fake_port":..,"bridge_pub":..,"bridge_dest":..,"bridge_lxmf":..,"peer":..}
stdin (JSON lines): {"cmd":"emit_message","text":..,"id":..}  broadcasts an incoming message through the
fake MeshChatX, {"cmd":"calls"} answers {"event":"calls",...}, {"cmd":"pairing_qr","pubkey":hex,"name":..,
"platform":..} answers {"event":"qr","text":..} (the bridge's own encoder, cross-check),
{"cmd":"pairing_sign","payload_b64":..,"approver":hex} answers {"event":"sign","hex":..},
{"cmd":"quit"}.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE_DIR = os.path.join(ROOT, "bridge")
PEER = "11" * 16
OUT = sys.stdout
sys.stdout = sys.stderr
LOCK = threading.Lock()


def emit(obj):
    with LOCK:
        OUT.write(json.dumps(obj) + "\n")
        OUT.flush()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Proc:
    def __init__(self, name, args):
        self.name = name
        self.lines = []
        self.p = subprocess.Popen([sys.executable, "-u", *args], cwd=BRIDGE_DIR, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.lines.append(line.rstrip())

    def wait_for(self, needle, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if any(needle in l for l in list(self.lines)):
                return
            if self.p.poll() is not None:
                break
            time.sleep(0.1)
        raise RuntimeError(f"{self.name}: {needle!r} not seen:\n" + "\n".join(self.lines[-30:]))

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


def main():
    device_pub = sys.argv[1]
    sys.path.insert(0, BRIDGE_DIR)
    from kestrel_bridge.devices import encode_pairing_qr, pairing_sign_message  # noqa: F401
    d = tempfile.mkdtemp(prefix="kestrel-it-")
    procs = []
    try:
        tcp_port, fake_port = free_port(), free_port()
        transport = Proc("transport", ["-m", "tests.it_transport", os.path.join(d, "transport"), str(tcp_port)])
        procs.append(transport)
        transport.wait_for("TRANSPORT_READY", 60)
        procs.append(Proc("fake", ["-m", "tests.fake_meshchatx", "--port", str(fake_port)]))
        base = f"http://127.0.0.1:{fake_port}"
        for _ in range(100):
            try:
                http("GET", base + "/api/v1/status")
                break
            except Exception:
                time.sleep(0.1)
        http("POST", base + "/_test/seed", {
            "conversations": [{"display_name": "Peer", "custom_display_name": None, "destination_hash": PEER,
                               "is_unread": True, "failed_messages_count": 0, "latest_message_preview": "hello",
                               "latest_message_created_at": "2026-01-01T00:00:00"}],
            "messages": [{"peer": PEER, "text": "earlier message", "incoming": True}]})
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
public_key = "{device_pub}"
name = "Dart one"
platform = "linux"
[rns]
mode = "standalone"
config_dir = "{q(sc)}/rns"
identity_path = "{q(sc)}/identity"
lxmf_storage = "{q(sc)}/lxmf"
announce_interval = 10
log_level = 2
tcp_host = "127.0.0.1"
tcp_port = {tcp_port}
""")
        chk = subprocess.run([sys.executable, "-m", "kestrel_bridge", "--config", toml, "--print-address"],
                             cwd=BRIDGE_DIR, capture_output=True, text=True, timeout=60)
        if chk.returncode != 0:
            raise RuntimeError(chk.stderr)
        vals = {}
        for line in chk.stdout.splitlines():
            vals[line.split("(")[0].split(":")[0].strip()] = line.split()[-1]
        sidecar = Proc("sidecar", ["-m", "kestrel_bridge", "--config", toml])
        procs.append(sidecar)
        sidecar.wait_for("bridge running", 90)
        emit({"event": "ready", "tcp_port": tcp_port, "fake_port": fake_port,
              "bridge_pub": vals["bridge public key"], "bridge_dest": vals["bridge destination"],
              "bridge_lxmf": vals["bridge lxmf.delivery destination"], "peer": PEER})
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            c = json.loads(line)
            cmd = c.get("cmd")
            if cmd == "quit":
                break
            if cmd == "emit_message":
                http("POST", base + "/_test/emit", {
                    "type": "lxmf.delivery", "remote_identity_name": "Peer",
                    "lxmf_message": {"hash": c.get("hash", "ab" * 16), "source_hash": PEER, "state": "delivered",
                                     "content": c["text"], "timestamp": time.time(), "fields": {}}})
                emit({"event": "emitted"})
            elif cmd == "calls":
                emit({"event": "calls", "calls": http("GET", base + "/_test/calls")})
            elif cmd == "pairing_qr":
                emit({"event": "qr", "text": encode_pairing_qr(bytes.fromhex(c["pubkey"]), c["name"], c["platform"],
                                                               bytes.fromhex(c["nonce"]), c["ts"])})
            elif cmd == "pairing_sign":
                payload = base64.urlsafe_b64decode(c["payload_b64"] + "=" * (-len(c["payload_b64"]) % 4))
                emit({"event": "sign", "hex": pairing_sign_message(payload, c["approver"]).hex()})
    except Exception as e:  # noqa: BLE001
        emit({"event": "error", "message": str(e)})
    finally:
        for p in reversed(procs):
            p.stop()


if __name__ == "__main__":
    main()
