"""Spike agent: one RNS instance (+ up to two LXMF routers) controlled over stdin/stdout.

Not meant to be run by hand; the experiment scripts spawn it via harness.py.
Protocol: one JSON object per line on stdin; events/replies on stdout prefixed with '@@'.
"""
import argparse, json, os, sys, threading, time, traceback

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True)
ap.add_argument("--role", choices=["transport", "node", "pn"], required=True)
ap.add_argument("--name", default="agent")
ap.add_argument("--serve", type=int, action="append", default=[], help="TCP server port(s)")
ap.add_argument("--serve-mode", default="full", help="interface mode of TCP server interfaces")
ap.add_argument("--connect", type=int, action="append", default=[], help="TCP client port(s)")
ap.add_argument("--a-key", help="identity file for destination A (shared by devices)")
ap.add_argument("--b-key", help="identity file for destination B (per device)")
ap.add_argument("--a-name", default=None)
ap.add_argument("--b-name", default=None)
ap.add_argument("--pn", help="propagation node destination hash (hex)")
ap.add_argument("--loglevel", type=int, default=6)
ap.add_argument("--stamp-value", type=float, default=8.0, help="announce stamp cost (RNS default 25 = ~1 min of Python CPU; lowered for speed)")
args = ap.parse_args()

os.makedirs(os.path.join(args.dir, "rns"), exist_ok=True)
cfg = ["[reticulum]",
       "  enable_transport = %s" % ("yes" if args.role == "transport" else "no"),
       "  share_instance = no", "  panic_on_interface_error = no",
       "[logging]", "  loglevel = %d" % args.loglevel, "[interfaces]"]
for i, p in enumerate(args.serve):
    cfg += ["  [[Server%d]]" % i, "    type = TCPServerInterface", "    interface_enabled = yes",
            "    listen_ip = 127.0.0.1", "    listen_port = %d" % p, "    mode = %s" % args.serve_mode]
for i, p in enumerate(args.connect):
    cfg += ["  [[Client%d]]" % i, "    type = TCPClientInterface", "    interface_enabled = yes",
            "    target_host = 127.0.0.1", "    target_port = %d" % p]
with open(os.path.join(args.dir, "rns", "config"), "w") as f:
    f.write("\n".join(cfg) + "\n")

import RNS, LXMF  # noqa: E402

_out = sys.stdout
_lock = threading.Lock()


def emit(ev, **kw):
    kw.update(ev=ev, t=time.time(), who=args.name)
    with _lock:
        _out.write("@@" + json.dumps(kw, default=lambda o: o.hex() if isinstance(o, bytes) else str(o)) + "\n")
        _out.flush()


RNS.Transport.DESTINATION_VALUE = args.stamp_value
RNS.Transport.DESTINATION_COST = min(RNS.Transport.DESTINATION_COST, args.stamp_value)
RNS.logdest = RNS.LOG_FILE
RNS.logfile = os.path.join(args.dir, "rns.log")
ret = RNS.Reticulum(configdir=os.path.join(args.dir, "rns"), loglevel=args.loglevel)

H = lambda b: b.hex()
routers, dests, idents, msgs = {}, {}, {}, {}


def setup(which, keyfile, name):
    ident = RNS.Identity.from_file(keyfile)
    r = LXMF.LXMRouter(identity=ident, storagepath=os.path.join(args.dir, "lxmf_" + which.lower()),
                       enforce_stamps=False)
    d = r.register_delivery_identity(ident, display_name=name)

    def cb(m, which=which):
        emit("rx", via=which, hash=H(m.hash), src=H(m.source_hash), content=m.content_as_string(),
             method=m.method, ratchet_id=H(m.ratchet_id) if m.ratchet_id else None)
    r.register_delivery_callback(cb)
    routers[which], dests[which], idents[which] = r, d, ident
    if args.pn:
        r.set_outbound_propagation_node(bytes.fromhex(args.pn))
    emit("ready_dest", which=which, dest=H(d.hash), identity=H(ident.hash))


if args.role == "node":
    if args.a_key: setup("A", args.a_key, args.a_name)
    if args.b_key: setup("B", args.b_key, args.b_name)

pn_router = None
if args.role == "pn":
    pn_router = LXMF.LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(args.dir, "lxmf_pn"),
                               propagation_limit=256, enforce_stamps=False)
    pn_router.enable_propagation()
    emit("ready_pn", dest=H(pn_router.propagation_destination.hash))


class Ann:
    aspect_filter = "lxmf.delivery"
    receive_path_responses = True

    def received_announce(self, destination_hash, announced_identity, app_data, announce_packet_hash):
        name = None
        try: name = LXMF.display_name_from_app_data(app_data)
        except Exception: pass
        r = RNS.Identity.current_ratchet_id(destination_hash)
        emit("announce_rx", dest=H(destination_hash), display_name=name,
             ratchet_id=H(r) if r else None, app_data=app_data)


RNS.Transport.register_announce_handler(Ann())


def ratchet_ids(which="A"):
    d = dests[which]
    return [H(RNS.Identity._get_ratchet_id(RNS.Identity._ratchet_public_bytes(r))) for r in (d.ratchets or [])]


def send(c):
    which = c.get("from", "A")
    to = bytes.fromhex(c["to"])
    ident = RNS.Identity.recall(to)
    if ident is None:
        emit("send_error", id=c["id"], err="unknown destination identity"); return
    od = RNS.Destination(ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
    method = {"opportunistic": LXMF.LXMessage.OPPORTUNISTIC, "direct": LXMF.LXMessage.DIRECT,
              "propagated": LXMF.LXMessage.PROPAGATED}[c.get("method", "opportunistic")]
    m = LXMF.LXMessage(od, dests[which], c.get("content", "hi"), desired_method=method)
    m.try_propagation_on_fail = False

    def dlv(m, id=c["id"]): emit("msg_delivered", id=id, hash=H(m.hash))

    def fail(m, id=c["id"]): emit("msg_failed", id=id, hash=H(m.hash), attempts=m.delivery_attempts)
    m.register_delivery_callback(dlv); m.register_failed_callback(fail)
    msgs[c["id"]] = m
    routers[which].handle_outbound(m)
    emit("msg_queued", id=c["id"], hash=H(m.hash))


def transport_paths():
    out = {}
    for k, e in list(RNS.Transport.path_table.items()):
        out[H(k)] = dict(ts=e[0], next_hop=H(e[1]), hops=e[2], expires=e[3], iface=str(e[5]))
    return out


def handle(c):
    cmd, cid = c["cmd"], c.get("cid")
    try:
        r = None
        w = c.get("which", "A")
        if cmd == "announce": routers[w].announce(dests[w].hash); r = "ok"
        elif cmd == "announce_pn": pn_router.announce_propagation_node(); r = "ok"
        elif cmd == "send": send(c)
        elif cmd == "sync":
            routers[w].request_messages_from_propagation_node(idents[w]); r = "ok"
        elif cmd == "sync_status":
            ro = routers[w]
            r = dict(state=ro.propagation_transfer_state, progress=ro.propagation_transfer_progress,
                     last_result=ro.propagation_transfer_last_result, dups=ro.propagation_transfer_last_duplicates)
        elif cmd == "stamp_file":
            import RNS.Stamps as S; r = S.destination_stamp_file(dests[w].hash)
        elif cmd == "paths": r = transport_paths()
        elif cmd == "has_path":
            h = bytes.fromhex(c["dest"]); hp = RNS.Transport.has_path(h)
            r = dict(has=hp, hops=RNS.Transport.hops_to(h) if hp else None)
        elif cmd == "drop_path": ret.drop_path(bytes.fromhex(c["dest"])); r = "ok"
        elif cmd == "request_path": RNS.Transport.request_path(bytes.fromhex(c["dest"])); r = "ok"
        elif cmd == "msg_state":
            m = msgs[c["id"]]; r = dict(state=m.state, attempts=m.delivery_attempts, method=m.method)
        elif cmd == "ratchets": r = ratchet_ids(w)
        elif cmd == "ratchet_file":
            r = os.path.join(args.dir, "lxmf_" + w.lower(), "lxmf", "ratchets", H(dests[w].hash) + ".ratchets")
        elif cmd == "known_ratchet":
            x = RNS.Identity.current_ratchet_id(bytes.fromhex(c["dest"])); r = H(x) if x else None
        elif cmd == "freeze_ratchet":
            RNS.Identity._remember_ratchet = staticmethod(lambda *a, **k: None); r = "ok"
        elif cmd == "noprove":
            RNS.Packet.prove = lambda self, *a, **k: None; r = "ok"
        elif cmd == "ratchets_off":
            d = dests[w]; d.ratchets = None; d.ratchets_path = None; r = "ok"
        elif cmd == "enforce": r = dests[w].enforce_ratchets()
        elif cmd == "reload_ratchets":
            d = dests[w]; d._reload_ratchets(d.ratchets_path); r = len(d.ratchets)
        elif cmd == "hold_rotation":
            dests[w].latest_ratchet_time = time.time(); r = "ok"
        elif cmd == "clock_skew":
            import types
            off = float(c["offset"]); real = time
            shim = types.SimpleNamespace(**{k: getattr(real, k) for k in dir(real) if not k.startswith("_")})
            shim.time = lambda: real.time() + off
            sys.modules["RNS.Destination"].time = shim; r = "ok"
        elif cmd == "remember":
            RNS.Identity.remember(None, bytes.fromhex(c["dest"]), bytes.fromhex(c["pub"]), None); r = "ok"
        elif cmd == "pubkey": r = H(idents[w].get_public_key())
        elif cmd == "pn_entries":
            r = [dict(tid=H(k), dest=H(v[0])) for k, v in pn_router.propagation_entries.items()]
        elif cmd == "link_count": r = len(routers[w].direct_links)
        elif cmd == "quit":
            emit("ret", cid=cid, r="bye"); os._exit(0)
        emit("ret", cid=cid, r=r)
    except Exception as e:
        emit("ret", cid=cid, err=repr(e), tb=traceback.format_exc())


emit("ready")
for line in sys.stdin:
    line = line.strip()
    if line:
        threading.Thread(target=handle, args=(json.loads(line),), daemon=True).start()
os._exit(0)
