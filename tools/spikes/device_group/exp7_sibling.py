"""Q7 - sibling channel between the devices' hidden B destinations while each device also holds A.

Each device process runs ONE RNS instance with TWO LXMF routers (LXMF 1.3.1 supports a single delivery identity per
router: LXMRouter.register_delivery_identity refuses a second one), one for A and one for B.
Tests:
  S1 B->B direct (link) after the sibling's B announced
  S2 B->B opportunistic
  S3 B->B propagated through a local PN (receiver syncs)
  S4 pairing-style bootstrap: Y knows X_B only from the public key (RNS.Identity.remember), X_B never announced:
       a) transport in 'full' interface mode  b) after X announces B once
  S5 sanity: messages to A still reach only A's router and messages to B only B's router
Run: python tools/spikes/device_group/exp7_sibling.py
"""
import time
from harness import Net, dest_of, hdr, row, merge_ratchet_files

with Net() as net:
    A, _ = dest_of(net, "A")
    XB, XBpub = dest_of(net, "BX")
    YB, YBpub = dest_of(net, "BY")
    pn = net.add("pn", role="pn")
    pn_hash = pn.wait(lambda e: e["ev"] == "ready_pn")["dest"]
    peer = net.add("peer", a_key=net.key("P"), a_name="peer", pn=pn_hash)
    X = net.add("X", a_key=net.key("A"), b_key=net.key("BX"), a_name="Alice", b_name="hidden-X", pn=pn_hash)
    Y = net.add("Y", a_key=net.key("A"), b_key=net.key("BY"), a_name="Alice", b_name="hidden-Y", pn=pn_hash)
    row("both routers up in one RNS instance:", [e["which"] for e in X.evs("ready_dest")], "B hashes", XB[:8], YB[:8])
    pn.call("announce_pn"); time.sleep(25)

    hdr("S4a bootstrap from public key only, X_B has never announced (transport mode=full)")
    Y.call("remember", dest=XB, pub=XBpub)
    t = time.time(); Y.call("send", **{"from": "B"}, id="s4a", to=XB, method="direct", content="s4a")
    e = X.wait(lambda e: e["ev"] == "rx" and e["content"] == "s4a", 45, since=t)
    row("delivered:", bool(e), "| in %.1fs" % (e["t"] - t) if e else "| sender msg_state:", "" if e else Y.call("msg_state", id="s4a"))

    hdr("S4b after X announces its B destination once")
    X.call("announce", which="B"); time.sleep(3)
    t = time.time(); Y.call("send", **{"from": "B"}, id="s4b", to=XB, method="direct", content="s4b")
    e = X.wait(lambda e: e["ev"] == "rx" and e["content"] == "s4b", 45, since=t)
    row("delivered:", bool(e), "| in %.1fs" % (e["t"] - t) if e else "", "| via router", e["via"] if e else "-")

    hdr("S1/S2 direct + opportunistic both ways (B -> B)")
    Y.call("announce", which="B"); time.sleep(3)
    for method in ("direct", "opportunistic"):
        for a, b, bh in ((X, Y, YB), (Y, X, XB)):
            t = time.time(); mid = "%s-%s-%s" % (method, a.name, b.name)
            a.call("send", **{"from": "B"}, id=mid, to=bh, method=method, content=mid)
            e = b.wait(lambda e: e["ev"] == "rx" and e["content"] == mid, 30, since=t)
            row(mid, "OK %.1fs via router %s src=%s" % (e["t"] - t, e["via"], e["src"][:8]) if e else "FAILED")

    hdr("S3 propagated B -> B (Y offline from the LXMF point of view: it only syncs)")
    X.call("send", **{"from": "B"}, id="s3", to=YB, method="propagated", content="s3")
    for _ in range(60):
        if pn.call("pn_entries"): break
        time.sleep(1)
    row("PN entries:", len(pn.call("pn_entries")), "| sender state:", X.call("msg_state", id="s3"))
    Y.call("sync", which="B")
    e = Y.wait(lambda e: e["ev"] == "rx" and e["content"] == "s3", 40)
    row("Y got it:", bool(e), "via router", e["via"] if e else "-", "| sync status:", Y.call("sync_status", which="B"), "| PN entries after:", len(pn.call("pn_entries")))

    hdr("S5 router separation")
    X.call("announce", which="A"); time.sleep(3)
    peer.call("send", id="s5", to=A, content="to A"); time.sleep(4)
    row("peer->A arrives at X:", [(e["via"], e["content"]) for e in X.evs("rx", content="to A")])
    print("\nDONE exp7")
