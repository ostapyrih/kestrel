#!/usr/bin/env python3
"""NomadNet-compatible node for the Kestrel integration tests.

A real RNS (pinned reference) destination ``nomadnetwork.node`` that mimics the
request handlers of ``nomadnet/Node.py`` (NomadNet 1.x): pages under
``/page/...`` return raw Micron bytes, files under ``/file/...`` return
``[file_handle, {"name": <bytes>}]`` (a file response, delivered as a Resource
with metadata), request data is the ``field_*`` / ``var_*`` dict the NomadNet
browser sends. The announce app_data is the UTF-8 node name, as in
``Node.announce``.

Same JSON-lines protocol and arguments as ``rns_peer.py`` (``ready`` first;
commands on stdin: ``announce``, ``teardown``).

Pages served:
  /page/index.mu     small page with links, a form and a `#!c=` header
  /page/form.mu      echoes the received request data, one ``key=value`` line
  /page/big.mu       ~300 KB page (needs a Resource)
  /page/whoami.mu    the identity hash revealed with identify() (or "none")
  /file/small.txt    a small file
  /file/big.bin      3 MiB of pseudo-random bytes (multi-segment resource)
"""

import argparse
import hashlib
import json
import os
import socket
import sys
import tempfile
import threading

import RNS

OUT_LOCK = threading.Lock()
EVENT_OUT = sys.stdout
sys.stdout = sys.stderr

NODE_NAME = "Kestrel Test Node"
BIG_FILE_SIZE = 3 * 1024 * 1024

INDEX = (
    "#!c=0\n"
    ">Test Node\n"
    "Welcome to the `!test`! node.\n"
    "`[Form`:/page/form.mu`name|color=blue]\n"
    "`<name`>\n"
    "`[Send`:/page/form.mu`*|from=index]\n"
    "`[Big page`:/page/big.mu]\n"
    "`[Small file`:/file/small.txt]\n"
)


def emit(event, **kw):
    kw["event"] = event
    with OUT_LOCK:
        EVENT_OUT.write(json.dumps(kw) + "\n")
        EVENT_OUT.flush()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def pseudo_random(n, seed=b"kestrel-it"):
    chunks = []
    c = 0
    while c * 32 < n:
        chunks.append(hashlib.sha256(seed + c.to_bytes(4, "big")).digest())
        c += 1
    return b"".join(chunks)[:n]


def big_page():
    lines = [">Big page"]
    i = 0
    while sum(len(x) + 1 for x in lines) < 300_000:
        lines.append(f"line {i:06d} " + hashlib.sha256(str(i).encode()).hexdigest())
        i += 1
    lines.append("END-OF-BIG-PAGE")
    return "\n".join(lines).encode("utf-8")


class Node:
    def __init__(self, args):
        self.configdir = args.dir or tempfile.mkdtemp(prefix="kestrel-nn-")
        self.filesdir = os.path.join(self.configdir, "files")
        os.makedirs(self.filesdir, exist_ok=True)
        self.port = args.port or free_port()
        with open(os.path.join(self.configdir, "config"), "w") as f:
            f.write(f"""[reticulum]
  enable_transport = {"Yes" if args.transport == "yes" else "No"}
  share_instance = No
  panic_on_interface_error = No

[logging]
  loglevel = 2

[interfaces]
  [[Kestrel NN Server]]
    type = TCPServerInterface
    interface_enabled = True
    listen_ip = 127.0.0.1
    listen_port = {self.port}
""")
        with open(os.path.join(self.filesdir, "small.txt"), "wb") as f:
            f.write(b"hello from the node\n")
        big_file = pseudo_random(BIG_FILE_SIZE, b"nn-file")
        self.big_file_sha256 = hashlib.sha256(big_file).hexdigest()
        with open(os.path.join(self.filesdir, "big.bin"), "wb") as f:
            f.write(big_file)
        RNS.Transport.STAMP_DESTINATIONS = False
        self.reticulum = RNS.Reticulum(configdir=self.configdir, loglevel=RNS.LOG_WARNING)
        self.identity = RNS.Identity()
        self.dest = RNS.Destination(self.identity, RNS.Destination.IN, RNS.Destination.SINGLE, "nomadnetwork", "node")
        self.dest.set_link_established_callback(self.on_link)
        self.big = big_page()
        allow = RNS.Destination.ALLOW_ALL
        self.dest.register_request_handler("/page/index.mu", self.serve_index, allow=allow)
        self.dest.register_request_handler("/page/form.mu", self.serve_form, allow=allow)
        self.dest.register_request_handler("/page/big.mu", self.serve_big, allow=allow)
        self.dest.register_request_handler("/page/whoami.mu", self.serve_whoami, allow=allow)
        for name in os.listdir(self.filesdir):
            self.dest.register_request_handler("/file/" + name, self.serve_file, allow=allow, auto_compress=32_000_000)

    # Node.serve_page style (6 arguments) ---------------------------------
    def serve_index(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, data=None)
        return INDEX.encode("utf-8")

    def serve_form(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, data=data)
        lines = [">Form result"]
        if isinstance(data, dict):
            for k in sorted(data):
                if isinstance(k, str) and (k.startswith("field_") or k.startswith("var_")):
                    lines.append(f"{k}={data[k]}")
        return "\n".join(lines).encode("utf-8")

    def serve_big(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, data=None)
        return self.big

    def serve_whoami(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, data=None)
        who = remote_identity.hash.hex() if remote_identity else "none"
        return f">Who\nidentity={who}".encode("utf-8")

    # Node.serve_file style (5 arguments) ---------------------------------
    def serve_file(self, path, data, request_id, remote_identity, requested_at):
        emit("request", path=path, data=None)
        file_path = path.replace("/file", self.filesdir, 1)
        return [open(file_path, "rb"), {"name": os.path.basename(file_path).encode("utf-8")}]

    def on_link(self, link):
        emit("link_established", link_id=link.link_id.hex())
        link.set_link_closed_callback(lambda l: emit("link_closed", link_id=l.link_id.hex()))
        link.set_remote_identified_callback(
            lambda l, ident: emit("remote_identified", link_id=l.link_id.hex(), identity=ident.hash.hex()))

    def announce(self):
        self.dest.announce(app_data=NODE_NAME.encode("utf-8"))
        emit("announced")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--transport", choices=["yes", "no"], default="no")
    ap.add_argument("--dir", default=None)
    args = ap.parse_args()

    node = Node(args)
    emit("ready", port=node.port, dest_hash=node.dest.hash.hex(), identity_hash=node.identity.hash.hex(),
         name=NODE_NAME, big_file_size=BIG_FILE_SIZE,
         big_file_sha256=node.big_file_sha256,
         big_page_size=len(node.big))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
            if cmd.get("cmd") == "announce":
                node.announce()
            elif cmd.get("cmd") == "teardown":
                for l in list(node.dest.links):
                    l.teardown()
        except Exception as e:
            emit("error", message=f"{type(e).__name__}: {e}")
    os._exit(0)


if __name__ == "__main__":
    main()
