#!/usr/bin/env python3
"""Scriptable Reticulum reference peer for the Kestrel integration tests.

Starts RNS (the pinned reference implementation) with a TCPServerInterface on
127.0.0.1:<port> in a temporary config directory and exposes a small
JSON-lines protocol on stdin/stdout:

* stdout: one JSON object per line, ``{"event": ..., ...}`` (first event is
  ``ready``). Everything else RNS logs goes to stderr.
* stdin: one JSON command per line, ``{"cmd": ..., ...}``.

The peer owns a SINGLE destination ``kestrel.it.peer`` with request handlers
``/echo`` (returns the request data), ``/big`` (50 KB incompressible bytes),
``/big_text`` (200 KB compressible) and ``/whoami`` (hex hash of the identified
remote identity or null), accepts links, resources (ACCEPT_ALL), proves
packets, and can initiate links/packets/resources towards Dart destinations.

Run from the repo root, inside ``tools/.venv``::

    python tools/it/rns_peer.py --transport no

Options: ``--port N`` (0 = random free port), ``--transport yes|no``
(``enable_transport``), ``--dir PATH`` (default: temp dir), ``--stamps`` (emit
announce stamps; slow at the default cost) and ``--dest-cost C`` (stamp value
the peer requires to treat received announce stamps as valid).
"""

import argparse
import hashlib
import json
import os
import socket
import sys
import tempfile
import threading
import time

import RNS
import RNS.vendor.umsgpack as umsgpack

OUT_LOCK = threading.Lock()
# RNS logs with print(); keep stdout reserved for the JSON event stream.
EVENT_OUT = sys.stdout
sys.stdout = sys.stderr


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
    """Deterministic incompressible bytes."""
    out = b""
    c = 0
    while len(out) < n:
        out += hashlib.sha256(seed + c.to_bytes(4, "big")).digest()
        c += 1
    return out[:n]


class Peer:
    def __init__(self, args):
        self.args = args
        self.links = []          # all links (in and out)
        self.last_link = None
        self.pending_out = {}
        self.configdir = args.dir or tempfile.mkdtemp(prefix="kestrel-it-")
        os.makedirs(self.configdir, exist_ok=True)
        self.port = args.port or free_port()
        self.write_config()
        if not args.stamps:
            RNS.Transport.STAMP_DESTINATIONS = False
        if args.dest_cost is not None:
            RNS.Transport.DESTINATION_COST = args.dest_cost
        self.reticulum = RNS.Reticulum(configdir=self.configdir, loglevel=RNS.LOG_WARNING)
        self.identity = RNS.Identity()
        self.dest = RNS.Destination(self.identity, RNS.Destination.IN, RNS.Destination.SINGLE, "kestrel", "it", "peer")
        self.dest.set_proof_strategy(RNS.Destination.PROVE_ALL)
        self.dest.set_link_established_callback(self.on_link)
        self.dest.set_packet_callback(self.on_packet)
        self.dest.register_request_handler("/echo", self.h_echo, allow=RNS.Destination.ALLOW_ALL)
        self.dest.register_request_handler("/big", self.h_big, allow=RNS.Destination.ALLOW_ALL)
        self.dest.register_request_handler("/big_text", self.h_big_text, allow=RNS.Destination.ALLOW_ALL)
        self.dest.register_request_handler("/whoami", self.h_whoami, allow=RNS.Destination.ALLOW_ALL)
        RNS.Transport.register_announce_handler(AnnounceHandler(self))

    def write_config(self):
        transport = "Yes" if self.args.transport == "yes" else "No"
        cfg = f"""[reticulum]
  enable_transport = {transport}
  share_instance = No
  panic_on_interface_error = No

[logging]
  loglevel = 2

[interfaces]
  [[Kestrel IT Server]]
    type = TCPServerInterface
    interface_enabled = True
    listen_ip = 127.0.0.1
    listen_port = {self.port}
"""
        with open(os.path.join(self.configdir, "config"), "w") as f:
            f.write(cfg)

    # ---- handlers -------------------------------------------------------
    def h_echo(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, link_id=link_id.hex())
        return data

    def h_big(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, link_id=link_id.hex())
        return pseudo_random(50_000)

    def h_big_text(self, path, data, request_id, link_id, remote_identity, requested_at):
        emit("request", path=path, link_id=link_id.hex())
        return (b"kestrel reticulum resource test. " * 6200)[:200_000]

    def h_whoami(self, path, data, request_id, link_id, remote_identity, requested_at):
        return remote_identity.hash if remote_identity else None

    def wire_link(self, link, initiator):
        self.links.append(link)
        self.last_link = link
        link.set_link_closed_callback(lambda l: self.on_closed(l))
        link.set_packet_callback(lambda data, pkt, l=link: emit("link_packet", link_id=l.link_id.hex(), data=data.hex()))
        link.set_remote_identified_callback(lambda l, ident: emit("remote_identified", link_id=l.link_id.hex(), identity=ident.hash.hex()))
        link.set_resource_strategy(RNS.Link.ACCEPT_ALL)
        link.set_resource_started_callback(lambda r: emit("resource_started", link_id=link.link_id.hex(), size=r.total_size if hasattr(r, "total_size") else None))
        link.set_resource_concluded_callback(lambda r: self.on_resource(link, r))

    def on_link(self, link):
        self.wire_link(link, False)
        emit("link_established", link_id=link.link_id.hex(), initiator=False, mtu=link.mtu, rtt=link.rtt)

    def on_closed(self, link):
        emit("link_closed", link_id=link.link_id.hex(), reason=getattr(link, "teardown_reason", None))

    def on_packet(self, data, packet):
        emit("packet", data=data.hex(), hops=packet.hops)

    def on_resource(self, link, resource):
        if resource.status == RNS.Resource.COMPLETE:
            data = resource.data.read() if hasattr(resource.data, "read") else resource.data
            emit("resource_concluded", link_id=link.link_id.hex(), size=len(data), sha256=hashlib.sha256(data).hexdigest())
        else:
            emit("resource_failed", link_id=link.link_id.hex(), status=resource.status)

    # ---- commands -------------------------------------------------------
    def out_dest(self, dest_hash_hex, aspects):
        ident = RNS.Identity.recall(bytes.fromhex(dest_hash_hex))
        if ident is None:
            raise ValueError("unknown destination, no announce received")
        return RNS.Destination(ident, RNS.Destination.OUT, RNS.Destination.SINGLE, aspects[0], *aspects[1:])

    def handle(self, c):
        cmd = c["cmd"]
        if cmd == "announce":
            app = bytes.fromhex(c["app_data"]) if c.get("app_data") else None
            self.dest.announce(app_data=app)
            emit("announced", dest_hash=self.dest.hash.hex())
        elif cmd == "link":
            d = self.out_dest(c["dest_hash"], c["aspects"])
            link = RNS.Link(d, established_callback=lambda l: emit("link_established", link_id=l.link_id.hex(), initiator=True, mtu=l.mtu, rtt=l.rtt))
            self.wire_link(link, True)
            emit("link_started", link_id=link.link_id.hex())
        elif cmd == "teardown":
            self.last_link.teardown()
        elif cmd == "identify":
            self.last_link.identify(self.identity)
        elif cmd == "link_send":
            RNS.Packet(self.last_link, bytes.fromhex(c["data"])).send()
        elif cmd == "link_request":
            data = bytes.fromhex(c["data"]) if c.get("data") else None
            link = self.last_link

            def ok(r):
                resp = r.response
                emit("response", path=c["path"], size=len(resp) if resp is not None else None,
                     sha256=hashlib.sha256(resp).hexdigest() if isinstance(resp, bytes) else None,
                     data=resp.hex() if isinstance(resp, bytes) and len(resp) < 1024 else None)
            link.request(c["path"], data=data, response_callback=ok, failed_callback=lambda r: emit("request_failed", path=c["path"]))
        elif cmd == "send_resource":
            n = c["size"]
            data = pseudo_random(n) if not c.get("compressible") else (b"abc" * n)[:n]
            link = self.last_link

            def done(r):
                emit("resource_sent", status=r.status, size=n, sha256=hashlib.sha256(data).hexdigest(),
                     complete=(r.status == RNS.Resource.COMPLETE))
            RNS.Resource(data, link, callback=done)
            emit("resource_sending", size=n, sha256=hashlib.sha256(data).hexdigest())
        elif cmd == "send_packet":
            d = self.out_dest(c["dest_hash"], c["aspects"])
            pkt = RNS.Packet(d, bytes.fromhex(c["data"]))
            receipt = pkt.send()
            if receipt:
                receipt.set_delivery_callback(lambda r: emit("packet_delivered", data=c["data"]))
                receipt.set_timeout_callback(lambda r: emit("packet_timeout", data=c["data"]))
        elif cmd == "request_path":
            RNS.Transport.request_path(bytes.fromhex(c["dest_hash"]))
        elif cmd == "has_path":
            emit("has_path", dest_hash=c["dest_hash"], value=RNS.Transport.has_path(bytes.fromhex(c["dest_hash"])),
                 hops=RNS.Transport.hops_to(bytes.fromhex(c["dest_hash"])))
        elif cmd == "quit":
            emit("bye")
            os._exit(0)
        else:
            emit("error", message=f"unknown command {cmd}")


class AnnounceHandler:
    aspect_filter = None
    receive_path_responses = True

    def __init__(self, peer):
        self.peer = peer

    def received_announce(self, destination_hash, announced_identity, app_data, announce_packet_hash=None, is_path_response=False):
        emit("announce_received", dest_hash=destination_hash.hex(), identity=announced_identity.hash.hex(),
             app_data=app_data.hex() if app_data else None, path_response=is_path_response,
             hops=RNS.Transport.hops_to(destination_hash))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--transport", choices=["yes", "no"], default="no")
    ap.add_argument("--dir", default=None)
    ap.add_argument("--stamps", action="store_true")
    ap.add_argument("--dest-cost", type=float, default=None)
    args = ap.parse_args()

    peer = Peer(args)
    emit("ready", port=peer.port, dest_hash=peer.dest.hash.hex(), identity_hash=peer.identity.hash.hex(),
         public_key=peer.identity.get_public_key().hex(), transport=args.transport,
         rns_version=RNS.__version__ if hasattr(RNS, "__version__") else None)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            peer.handle(json.loads(line))
        except Exception as e:  # keep the peer alive, report to the test
            emit("error", message=f"{type(e).__name__}: {e}")
    os._exit(0)


if __name__ == "__main__":
    main()
