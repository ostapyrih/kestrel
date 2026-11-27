"""Q2 - handover: announcer X dies, Y takes over A. How long until the peer's messages reach Y?

Ratchet keys are shared (X's file merged into Y's) so that decryption does not confound the timing (see exp3).
Scenarios (each on a fresh network):
  S1  Y announces D seconds after X is killed; peer sends m1 at the kill, m2 before Y's announce, m3 after it.
  S2  Y never announces (stays silent); peer sends m1.  -> how long until the peer gives up?
  S3  same as S1 but with direct (link) messages.
Run: python tools/spikes/device_group/exp2_handover.py
"""
import shutil, sys, time
from harness import Net, dest_of, hdr, row, merge_ratchet_files

D = 6.0


def build(net):
    A, _ = dest_of(net, "A")
    peer = net.add("peer", a_key=net.key("P"), a_name="peer")
    X = net.add("X", a_key=net.key("A"), a_name="Alice")
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice")
    return A, peer, X, Y


def prime(net, A, peer, X, Y):
    X.call("announce"); time.sleep(3)
    # share X's ratchets with Y (merge keeps Y's own, X's older ones follow)
    n = merge_ratchet_files([X.call("ratchet_file"), Y.call("ratchet_file")], net.key("A"), Y.call("ratchet_file"))
    Y.call("reload_ratchets")
    peer.call("send", id="warm", to=A, content="warm"); X.wait(lambda e: e["ev"] == "rx", 15)
    return n


def run(method, y_announces):
    with Net() as net:
        A, peer, X, Y = build(net)
        prime(net, A, peer, X, Y)
        row("warm-up delivered to X:", len(X.evs("rx")) == 1)
        t0 = time.time(); X.kill()
        peer.call("send", id="m1", to=A, method=method, content="m1"); t_m1 = time.time()
        time.sleep(D / 2)
        peer.call("send", id="m2", to=A, method=method, content="m2")
        time.sleep(D / 2)
        t_ann = time.time()
        if y_announces: Y.call("announce")
        time.sleep(1.0)
        peer.call("send", id="m3", to=A, method=method, content="m3")
        end = time.time() + (150 if not y_announces else 120)
        while time.time() < end:
            ds = {i: bool(peer.evs("msg_delivered", id=i) or peer.evs("msg_failed", id=i)) for i in ("m1", "m2", "m3")}
            if all(ds.values()): break
            time.sleep(1)
        for i in ("m1", "m2", "m3"):
            rx = [e for e in Y.evs("rx") if e["content"] == i]
            dl = peer.evs("msg_delivered", id=i); fl = peer.evs("msg_failed", id=i)
            st = peer.call("msg_state", id=i)
            row(i, "Y rx at +%.1fs after kill" % (rx[0]["t"] - t0) if rx else "Y never received",
                "(+%.1fs after Y announce)" % (rx[0]["t"] - t_ann) if rx and y_announces else "",
                "| sender: delivered" if dl else ("| sender: FAILED after %.0fs (attempts=%s)" % (fl[0]["t"] - t0, fl[0]["attempts"]) if fl else "| sender: still pending, state=%s attempts=%s" % (st["state"], st["attempts"])))
        return t0, t_ann


hdr("S1 opportunistic, Y announces %.0fs after X dies" % D); run("opportunistic", True)
hdr("S2 opportunistic, Y stays silent"); run("opportunistic", False)
hdr("S3 direct (link), Y announces %.0fs after X dies" % D); run("direct", True)
print("\nDONE exp2")
