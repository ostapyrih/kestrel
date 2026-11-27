"""Q4 - propagation: several devices with identity A against one local propagation node (PN).

P1  message for A stored on PN; X syncs, then Y syncs.  Does Y get anything? (PN entry count after each step)
P2  race: X and Y sync at the same moment.
P3  a device WITHOUT the shared ratchets (Z) syncs first: is the message destroyed on the PN?
Also prints what the sender sees for a propagated message.
Ratchets of X and Y are merged (shared); Z has none.
Run: python tools/spikes/device_group/exp4_propagation.py
"""
import threading, time
from harness import Net, dest_of, hdr, row, merge_ratchet_files


def wait_sync(dev, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        s = dev.call("sync_status")
        if s["state"] in (7, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xfe): return s
        time.sleep(0.5)
    return dev.call("sync_status")


with Net() as net:
    A, _ = dest_of(net, "A")
    pn = net.add("pn", role="pn")
    pn_hash = pn.wait(lambda e: e["ev"] == "ready_pn")["dest"]
    kw = dict(pn=pn_hash)
    peer = net.add("peer", a_key=net.key("P"), a_name="peer", **kw)
    X = net.add("X", a_key=net.key("A"), a_name="Alice", **kw)
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice", **kw)
    Z = net.add("Z", a_key=net.key("A"), a_name="Alice", **kw)
    pn.call("announce_pn"); time.sleep(25)             # LXMF delays the PN announce by 20 s (NODE_ANNOUNCE_DELAY)
    X.call("announce"); time.sleep(3)                  # peer learns A and R_x
    merge_ratchet_files([Y.call("ratchet_file"), X.call("ratchet_file")], net.key("A"), Y.call("ratchet_file"))
    Y.call("reload_ratchets")                          # Z is deliberately left without X's ratchets

    hdr("P1 sequential: X syncs, then Y syncs")
    peer.call("send", id="p1", to=A, method="propagated", content="p1")
    time.sleep(15)
    row("sender state (4=SENT, 8=DELIVERED):", peer.call("msg_state", id="p1"), "| delivered event:", bool(peer.evs("msg_delivered", id="p1")))
    row("PN entries:", len(pn.call("pn_entries")))
    X.call("sync"); s = wait_sync(X); row("X sync:", s, "| X rx:", len(X.evs("rx", content="p1")))
    time.sleep(1); row("PN entries after X sync:", len(pn.call("pn_entries")))
    Y.call("sync"); s = wait_sync(Y); row("Y sync:", s, "| Y rx:", len(Y.evs("rx", content="p1")))

    hdr("P2 race: X and Y sync simultaneously")
    peer.call("send", id="p2", to=A, method="propagated", content="p2"); time.sleep(15)
    row("PN entries:", len(pn.call("pn_entries")))
    ts = [threading.Thread(target=d.call, args=("sync",)) for d in (X, Y)]
    [x.start() for x in ts]; [x.join() for x in ts]
    sx, sy = wait_sync(X), wait_sync(Y)
    row("X sync", sx, "| Y sync", sy)
    time.sleep(1)
    row("rx p2 at X:", len(X.evs("rx", content="p2")), "at Y:", len(Y.evs("rx", content="p2")), "| PN entries after:", len(pn.call("pn_entries")))

    hdr("P3 device without ratchets (Z) syncs first, then X")
    peer.call("send", id="p3", to=A, method="propagated", content="p3")
    for _ in range(90):
        if pn.call("pn_entries"): break
        time.sleep(1)
    row("PN entries before:", len(pn.call("pn_entries")), "| sender state:", peer.call("msg_state", id="p3"))
    Z.call("sync"); s = wait_sync(Z); row("Z sync:", s, "| Z rx p3:", len(Z.evs("rx", content="p3")))
    time.sleep(1); row("PN entries after Z's sync:", len(pn.call("pn_entries")))
    X.call("sync"); s = wait_sync(X); row("X sync afterwards:", s, "| X rx p3:", len(X.evs("rx", content="p3")))
print("\nDONE exp4")
