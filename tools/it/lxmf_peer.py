#!/usr/bin/env python3
"""Scriptable LXMF reference peer for the Kestrel integration tests.

Starts RNS (the pinned reference implementation) with a TCPServerInterface on
127.0.0.1:<port> plus an ``LXMF.LXMRouter`` with one ``lxmf.delivery``
identity, and exposes a JSON-lines protocol (same shape as ``rns_peer.py``):

* stdout: ``{"event": ..., ...}`` per line, first event is ``ready``.
* stdin: ``{"cmd": ..., ...}`` per line.

Events: ``ready``, ``announced``, ``announce_received``, ``received``
(hash, source, title, content or content_sha256/size, signature_validated,
method, stamp_valid), ``outbound_state`` (hash, state), ``delivered``,
``failed``, ``error``.

Commands: ``announce``, ``send`` (dest_hash, content | size, title, method
``opportunistic|direct|propagated``), ``set_node`` (hash: outbound propagation
node), ``sync`` (download the inbox from the selected node; emits
``sync_done``), ``announce_node`` (re-announce the propagation node),
``quit``.

Propagation: ``--propagation`` makes this process an LXMF propagation node
(``enable_propagation``; options ``--pn-name``, ``--pn-cost``, ``--pn-flex``,
``--pn-limit`` KB per message, ``--pn-sync-limit`` KB per transfer) and
announces it shortly after start. ``--connect PORT`` additionally connects to
a local TCP server (another peer or node). Extra events: ``pn_announce``.

Options: ``--port N``, ``--transport yes|no``, ``--dir PATH``,
``--name TEXT`` (display name), ``--stamp-cost C`` (inbound stamp cost to
require and announce), ``--enforce-stamps``.
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
import LXMF

OUT_LOCK = threading.Lock()
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


def pseudo_random(n, seed=b"kestrel-lxmf"):
    out = b""
    c = 0
    while len(out) < n:
        out += hashlib.sha256(seed + c.to_bytes(4, "big")).digest()
        c += 1
    return out[:n]


STATE_NAMES = {
    LXMF.LXMessage.GENERATING: "generating",
    LXMF.LXMessage.OUTBOUND: "outbound",
    LXMF.LXMessage.SENDING: "sending",
    LXMF.LXMessage.SENT: "sent",
    LXMF.LXMessage.DELIVERED: "delivered",
    LXMF.LXMessage.REJECTED: "rejected",
    LXMF.LXMessage.CANCELLED: "cancelled",
    LXMF.LXMessage.FAILED: "failed",
}


class Peer:
    def __init__(self, args):
        self.args = args
        self.configdir = args.dir or tempfile.mkdtemp(prefix="kestrel-lxmf-")
        os.makedirs(self.configdir, exist_ok=True)
        self.port = args.port or free_port()
        self.write_config()
        RNS.Transport.STAMP_DESTINATIONS = False
        self.reticulum = RNS.Reticulum(configdir=self.configdir, loglevel=int(os.environ.get("KESTREL_PY_LOGLEVEL", RNS.LOG_WARNING)))
        self.identity = RNS.Identity()
        self.router = LXMF.LXMRouter(
            identity=self.identity,
            storagepath=os.path.join(self.configdir, "lxmf"),
            autopeer=False,
            enforce_stamps=args.enforce_stamps,
            name=args.pn_name,
            propagation_cost=args.pn_cost,
            propagation_cost_flexibility=args.pn_flex,
            propagation_limit=args.pn_limit,
            sync_limit=args.pn_sync_limit,
        )
        self.dest = self.router.register_delivery_identity(
            self.identity, display_name=args.name, stamp_cost=args.stamp_cost
        )
        self.router.register_delivery_callback(self.on_message)
        RNS.Transport.register_announce_handler(AnnounceHandler())
        RNS.Transport.register_announce_handler(PnAnnounceHandler())
        if args.propagation:
            LXMF.LXMRouter.NODE_ANNOUNCE_DELAY = 1
            self.router.enable_propagation()
            self.router.announce_propagation_node()

    def write_config(self):
        transport = "Yes" if self.args.transport == "yes" else "No"
        cfg = f"""[reticulum]
  enable_transport = {transport}
  share_instance = No
  panic_on_interface_error = No

[logging]
  loglevel = 2

[interfaces]
  [[Kestrel LXMF IT Server]]
    type = TCPServerInterface
    interface_enabled = True
    listen_ip = 127.0.0.1
    listen_port = {self.port}
"""
        if self.args.connect:
            cfg += f"""
  [[Kestrel LXMF IT Client]]
    type = TCPClientInterface
    interface_enabled = True
    target_host = 127.0.0.1
    target_port = {self.args.connect}
"""
        with open(os.path.join(self.configdir, "config"), "w") as f:
            f.write(cfg)

    def on_message(self, message):
        content = message.content
        info = dict(
            hash=message.hash.hex(),
            source=message.source_hash.hex(),
            title=message.title.decode("utf-8", "replace") if message.title else "",
            size=len(content),
            content_sha256=hashlib.sha256(content).hexdigest(),
            signature_validated=bool(message.signature_validated),
            method=message.method,
            stamp_valid=getattr(message, "stamp_valid", None),
            transport_encrypted=bool(message.transport_encrypted),
        )
        if len(content) <= 2048:
            info["content"] = content.decode("utf-8", "replace")
        emit("received", **info)

    def watch_sync(self):
        end = time.time() + 60
        while time.time() < end:
            time.sleep(0.2)
            st = self.router.propagation_transfer_state
            if st == LXMF.LXMRouter.PR_COMPLETE or st >= 0xF0:
                emit(
                    "sync_done",
                    state=st,
                    result=self.router.propagation_transfer_last_result,
                    duplicates=self.router.propagation_transfer_last_duplicates,
                )
                return
        emit("sync_done", state=-1)

    def handle(self, c):
        cmd = c["cmd"]
        if cmd == "announce":
            self.router.announce(self.dest.hash)
            emit("announced", dest_hash=self.dest.hash.hex())
        elif cmd == "send":
            dest_hash = bytes.fromhex(c["dest_hash"])
            ident = RNS.Identity.recall(dest_hash)
            if ident is None:
                # No announce heard yet: ask the network for the path (the
                # answer carries the announce).
                RNS.Transport.request_path(dest_hash)
                end = time.time() + 20
                while ident is None and time.time() < end:
                    time.sleep(0.2)
                    ident = RNS.Identity.recall(dest_hash)
            if ident is None:
                raise ValueError("unknown destination, no announce received")
            d = RNS.Destination(ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            method = {
                "opportunistic": LXMF.LXMessage.OPPORTUNISTIC,
                "direct": LXMF.LXMessage.DIRECT,
                "propagated": LXMF.LXMessage.PROPAGATED,
            }[c.get("method", "opportunistic")]
            if "size" in c:
                content = pseudo_random(c["size"]).hex()[: c["size"]]
            else:
                content = c["content"]
            lxm = LXMF.LXMessage(d, self.dest, content, c.get("title", ""), desired_method=method)
            if "timestamp" in c:
                # Same timestamp + content => identical message hash, so one
                # message can be sent over two routes (dedup tests).
                lxm.timestamp = c["timestamp"]
            lxm.register_delivery_callback(lambda m: emit("delivered", hash=m.hash.hex()))
            lxm.register_failed_callback(lambda m: emit("failed", hash=m.hash.hex(), state=STATE_NAMES.get(m.state)))
            self.router.handle_outbound(lxm)
            emit("queued", hash=lxm.hash.hex(), method=lxm.method, content_sha256=hashlib.sha256(content.encode()).hexdigest())
        elif cmd == "ensure":
            # Learn a destination: wait for its announce or request the path.
            h = bytes.fromhex(c["dest_hash"])
            RNS.Transport.request_path(h)
            end = time.time() + c.get("timeout", 20)
            while RNS.Identity.recall(h) is None and time.time() < end:
                time.sleep(0.2)
            emit("known", dest_hash=c["dest_hash"], ok=RNS.Identity.recall(h) is not None)
        elif cmd == "set_node":
            self.router.set_outbound_propagation_node(bytes.fromhex(c["hash"]))
            emit("node_set", hash=c["hash"])
        elif cmd == "announce_node":
            self.router.announce_propagation_node()
        elif cmd == "sync":
            self.router.request_messages_from_propagation_node(self.identity)
            threading.Thread(target=self.watch_sync, daemon=True).start()
        elif cmd == "quit":
            emit("bye")
            os._exit(0)
        else:
            emit("error", message=f"unknown command {cmd}")


class PnAnnounceHandler:
    aspect_filter = "lxmf.propagation"
    receive_path_responses = True

    def received_announce(self, destination_hash, announced_identity, app_data, announce_packet_hash=None, is_path_response=False):
        emit("pn_announce", dest_hash=destination_hash.hex(), app_data=app_data.hex() if app_data else None)


class AnnounceHandler:
    aspect_filter = "lxmf.delivery"
    receive_path_responses = True

    def received_announce(self, destination_hash, announced_identity, app_data, announce_packet_hash=None, is_path_response=False):
        emit(
            "announce_received",
            dest_hash=destination_hash.hex(),
            app_data=app_data.hex() if app_data else None,
            display_name=LXMF.display_name_from_app_data(app_data),
            stamp_cost=LXMF.stamp_cost_from_app_data(app_data),
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--transport", choices=["yes", "no"], default="no")
    ap.add_argument("--dir", default=None)
    ap.add_argument("--name", default="Python Peer")
    ap.add_argument("--stamp-cost", type=int, default=None)
    ap.add_argument("--enforce-stamps", action="store_true")
    ap.add_argument("--connect", type=int, default=None)
    ap.add_argument("--propagation", action="store_true")
    ap.add_argument("--pn-name", default=None)
    ap.add_argument("--pn-cost", type=int, default=13)
    ap.add_argument("--pn-flex", type=int, default=3)
    ap.add_argument("--pn-limit", type=int, default=256)
    ap.add_argument("--pn-sync-limit", type=int, default=256 * 40)
    args = ap.parse_args()

    peer = Peer(args)
    emit(
        "ready",
        port=peer.port,
        dest_hash=peer.dest.hash.hex(),
        identity_hash=peer.identity.hash.hex(),
        public_key=peer.identity.get_public_key().hex(),
        lxmf_version=getattr(LXMF, "__version__", None),
        pn_hash=peer.router.propagation_destination.hash.hex() if args.propagation else None,
    )
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            peer.handle(json.loads(line))
        except Exception as e:
            emit("error", message=f"{type(e).__name__}: {e}")
    os._exit(0)


if __name__ == "__main__":
    main()
