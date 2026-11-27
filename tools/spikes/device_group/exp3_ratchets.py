"""Q3 - ratchets: can Y decrypt a message the peer encrypted to X's announced ratchet R_x?

Cases (fresh network each). "Peer frozen" = the peer stops updating its ratchet cache after it heard X; this
simulates a peer that was offline / missed Y's announce while the transport already routes A to Y.
  C0  control: peer hears Y's announce (R_y)                                   -> works
  C1  no sharing, peer holds R_x, route goes to Y                               -> expected FAIL
  C2  X's ratchet file merged into Y's file BEFORE Y announces, Y reloads       -> expected OK
  C3  live OVERWRITE of Y's file with X's list while Y runs (Y's R_y is lost)   -> shows data loss
  C4  live MERGE (Y's list first, then X's) while Y runs, peer holds R_x        -> RNS reloads the file itself
  C5  ratchets switched off on X and Y after the peer already cached R_x         -> peer keeps using R_x (30 days)
  C6  ratchets disabled everywhere from the start (fresh peer)                  -> works (base-key encryption)
  C7  Y adopts X's list verbatim and holds rotation (announces the same R_x)  -> works, peer sees no change
Run: python tools/spikes/device_group/exp3_ratchets.py
"""
import os, shutil, time
from harness import Net, dest_of, hdr, row, merge_ratchet_files


def mk(net, ratchets=True):
    A, _ = dest_of(net, "A")
    peer = net.add("peer", a_key=net.key("P"), a_name="peer")
    X = net.add("X", a_key=net.key("A"), a_name="Alice")
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice")
    if not ratchets:
        X.call("ratchets_off"); Y.call("ratchets_off")
    return A, peer, X, Y


def try_send(peer, Y, A, tag, wait=25):
    t = time.time()
    peer.call("send", id=tag, to=A, content=tag)
    e = Y.wait(lambda e: e["ev"] == "rx" and e["content"] == tag, wait, since=t)
    if e:
        return "OK after %.1fs (ratchet_id=%s)" % (e["t"] - t, (e["ratchet_id"] or "none")[:8])
    return "NOT received in %ds" % wait


def short(l): return [x[:8] for x in l]


hdr("C0 control: peer hears Y's own announce")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(3.5); Y.call("announce"); time.sleep(2.5)
    row("R_x", short(X.call("ratchets"))[:1], "R_y", short(Y.call("ratchets"))[:1], "peer knows", (peer.call("known_ratchet", dest=A) or "")[:8])
    row("send:", try_send(peer, Y, A, "c0"))

hdr("C1 no sharing: peer frozen on R_x, route goes to Y")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(2.5); peer.call("freeze_ratchet")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("R_x", short(X.call("ratchets"))[:1], "R_y", short(Y.call("ratchets"))[:1], "peer uses", (peer.call("known_ratchet", dest=A) or "")[:8],
        "| transport path via", net.transport.call("paths")[A]["iface"][-14:])
    row("send (opportunistic):", try_send(peer, Y, A, "c1", wait=40))
    row("peer msg state:", peer.call("msg_state", id="c1"))
    log = open(os.path.join(Y.dir, "rns.log"), errors="replace").read()
    row("Y log has 'Decryption with ratchets failed':", "Decryption with ratchets failed" in log)

hdr("C2 merge X's ratchet file into Y's before Y announces")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(2.5); peer.call("freeze_ratchet")
    n = merge_ratchet_files([Y.call("ratchet_file"), X.call("ratchet_file")], net.key("A"), Y.call("ratchet_file"))
    Y.call("reload_ratchets")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("merged list length", n, "Y list", short(Y.call("ratchets")), "peer uses", (peer.call("known_ratchet", dest=A) or "")[:8])
    row("send:", try_send(peer, Y, A, "c2"))

hdr("C3 live OVERWRITE of Y's ratchet file with X's (Y's own ratchet is lost)")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(3.5); Y.call("announce"); time.sleep(2.5)   # peer holds R_y (not frozen)
    ry = Y.call("ratchets")[0]
    shutil.copyfile(X.call("ratchet_file"), Y.call("ratchet_file"))
    row("peer uses R_y =", (peer.call("known_ratchet", dest=A) or "")[:8], "; Y's file overwritten with X's list")
    row("send (peer encrypts to R_y):", try_send(peer, Y, A, "c3", wait=15))
    Y.call("reload_ratchets"); row("Y list after reload:", short(Y.call("ratchets")), "| R_y present:", ry in Y.call("ratchets"))
    row("send again (peer still encrypts to R_y):", try_send(peer, Y, A, "c3b", wait=25))

hdr("C4 live MERGE on a running Y; peer frozen on R_x")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(2.5); peer.call("freeze_ratchet")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("before merge:", try_send(peer, Y, A, "c4a", wait=14))
    merge_ratchet_files([Y.call("ratchet_file"), X.call("ratchet_file")], net.key("A"), Y.call("ratchet_file"))
    time.sleep(0.5)
    # no explicit reload: RNS reloads the file by itself on the next failed decryption (Destination.decrypt)
    row("after merge, next message (auto-reload on decrypt failure):", try_send(peer, Y, A, "c4b", wait=25))
    time.sleep(15)
    row("earlier message c4a also arrived via the peer's retry?", bool(Y.evs("rx", content="c4a")), "| sender state of c4a:", peer.call("msg_state", id="c4a"))
    row("Y list:", short(Y.call("ratchets")))

hdr("C5 ratchets switched off on both devices AFTER the peer cached R_x")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(2.5)
    rx_list = short(X.call("ratchets"))
    X.call("ratchets_off"); Y.call("ratchets_off")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("peer still uses cached ratchet:", (peer.call("known_ratchet", dest=A) or "none")[:8], "| R_x was", rx_list)
    row("send:", try_send(peer, Y, A, "c5", wait=30))

hdr("C6 ratchets disabled everywhere from the start (fresh peer)")
with Net() as net:
    A, peer, X, Y = mk(net, ratchets=False)
    X.call("announce"); time.sleep(3.5); Y.call("announce"); time.sleep(2.5)
    row("peer ratchet:", peer.call("known_ratchet", dest=A))
    row("send:", try_send(peer, Y, A, "c6"))
hdr("C7 Y ADOPTS X's list verbatim and does not rotate: Y announces the same R_x (nothing changes for the peer)")
with Net() as net:
    A, peer, X, Y = mk(net)
    X.call("announce"); time.sleep(2.5); peer.call("freeze_ratchet")
    shutil.copyfile(X.call("ratchet_file"), Y.call("ratchet_file")); Y.call("reload_ratchets"); Y.call("hold_rotation")
    time.sleep(1.1); Y.call("announce"); time.sleep(2.5)
    row("R_x", short(X.call("ratchets")), "Y list", short(Y.call("ratchets")), "peer uses", (peer.call("known_ratchet", dest=A) or "")[:8])
    row("send:", try_send(peer, Y, A, "c7"))
print("\nDONE exp3")
