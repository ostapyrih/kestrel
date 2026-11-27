"""Q1 - paths: who receives messages for A when several devices holding A announce / stay silent?

Topology: transport T <-TCP-> peer P, devices X, Y, Z (all hold identity A, each its own B).
Ratchets are disabled on A here to isolate routing from ratchet decryption (see exp3 for ratchets).
Run: python tools/spikes/device_group/exp1_paths.py [--mode gateway]
"""
import sys, time
from harness import Net, dest_of, hdr, row

MODE = sys.argv[sys.argv.index("--mode") + 1] if "--mode" in sys.argv else "full"
_n = [0]


def send_and_see(peer, devs, method="opportunistic", n=4, wait=20):
    """peer sends n messages to A; returns {device: count}."""
    t0 = time.time(); ids = []
    for _ in range(n):
        _n[0] += 1; mid = "m%d" % _n[0]; ids.append(mid)
        peer.call("send", id=mid, to=A, method=method, content=mid)
        time.sleep(0.5)
    end = time.time() + wait
    while time.time() < end:
        if sum(len(d.evs("rx", since=t0)) for d in devs) >= n: break
        time.sleep(0.3)
    res = {d.name: len(d.evs("rx", since=t0)) for d in devs}
    dl = len(peer.evs("msg_delivered", since=t0))
    return res, dl


with Net(serve_mode=MODE) as net:
    A, _ = dest_of(net, "A")
    pk = net.key("P")
    P_dest, _ = dest_of(net, "P")
    T = net.transport
    peer = net.add("peer", a_key=pk, a_name="peer")
    devs = [net.add(n, a_key=net.key("A"), b_key=net.key("B_" + n), a_name="Alice-" + n) for n in "XYZ"]
    X, Y, Z = devs
    for d in devs: d.call("ratchets_off")
    # learn which transport interface belongs to which device (announce one by one)
    iface = {}
    for d in (X, Y, Z):
        t = time.time(); d.call("announce"); time.sleep(2.5)
        iface[d.name] = T.call("paths")[A]["iface"]
    row("transport interface per device", iface)
    inv = {v: k for k, v in iface.items()}
    def holder(): return inv.get(T.call("paths").get(A, {}).get("iface"), "?")
    def peer_has(): return peer.call("has_path", dest=A)

    hdr("1. only X announces; Y and Z are online but silent (mode=%s)" % MODE)
    # fresh network state: restart not needed - just announce X last
    time.sleep(1.1); X.call("announce"); time.sleep(2.5)
    row("transport path holder", holder(), "peer path", peer_has())
    res, dl = send_and_see(peer, devs, n=6); row("opportunistic x6 ->", res, "delivered-proofs at peer:", dl)
    res, dl = send_and_see(peer, devs, n=3, method="direct"); row("direct(link) x3 ->", res, "delivered-proofs at peer:", dl)

    hdr("2. Y announces after X (different second) -> last emission wins?")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("transport path holder", holder())
    res, dl = send_and_see(peer, devs, n=4); row("opportunistic x4 ->", res, dl)
    time.sleep(1.1); X.call("announce"); time.sleep(2.5)
    row("X announces again; holder", holder())
    res, dl = send_and_see(peer, devs, n=4); row("opportunistic x4 ->", res, dl)

    hdr("3. X and Y announce in the same second (tie), with an incumbent holder")
    import threading
    wins = {}
    for rnd in range(6):
        inc = (X, Y)[rnd % 2]; other = Y if inc is X else X
        time.sleep(1.2); inc.call("announce"); time.sleep(2.0)      # incumbent holds the path
        time.sleep(1.2)
        ts = [threading.Thread(target=d.call, args=("announce",)) for d in (X, Y)]
        [t.start() for t in ts]; [t.join() for t in ts]
        time.sleep(2.0)
        k = "incumbent kept" if holder() == inc.name else "challenger won"
        wins[k] = wins.get(k, 0) + 1
    row("6 rounds: both announce in the same second while the other one is incumbent", wins)

    hdr("4. Z announces with a +120 s clock skew, then X announces with correct clock")
    Z.call("clock_skew", offset=120); time.sleep(1.1); Z.call("announce"); time.sleep(2.5)
    row("holder after skewed Z announce", holder())
    time.sleep(1.1); X.call("announce"); time.sleep(2.5)
    row("holder after normal X announce (X's emission is 120 s older than Z's)", holder())
    res, dl = send_and_see(peer, devs, n=3, wait=12); row("opportunistic x3 ->", res, dl)

    hdr("5. path request while transport has no path: do silent devices answer?")
    Z.call("clock_skew", offset=0)
    T.call("drop_path", dest=A); peer.call("drop_path", dest=A); time.sleep(0.5)
    t0 = time.time(); peer.call("request_path", dest=A); time.sleep(6)
    row("peer has path after request:", peer_has(), "holder:", holder(),
        "announce_rx events at peer:", len(peer.evs("announce_rx", since=t0)))
    res, dl = send_and_see(peer, devs, n=3, wait=12); row("opportunistic x3 ->", res, dl)
    # repeat a few times to see non-determinism
    h = {}
    for _ in range(5):
        T.call("drop_path", dest=A); peer.call("drop_path", dest=A); time.sleep(21)  # PATH_REQUEST_MI = 20s
        peer.call("request_path", dest=A); time.sleep(5); h[holder()] = h.get(holder(), 0) + 1
    row("holder after 5 repeated path requests (no announces)", h)
    print("\nDONE exp1 mode=%s" % MODE)
