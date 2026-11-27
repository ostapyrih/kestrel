"""Q5 - delivery proofs and duplicates.

Scenario: X (path holder) receives message m but its delivery proof is lost (X's Packet.prove is patched to a
no-op). Before the peer's LXMF retry (every ~10 s) Y announces and takes over the path, so the retry - the SAME
LXMF message, same hash - arrives at Y and Y delivers it as well. Both devices (separate LXMF stores) deliver the
message. What does the sender see, and what are the message hashes on X and Y?
Ratchets are shared (X's file merged into Y's).
Run: python tools/spikes/device_group/exp5_dupes.py
"""
import time
from harness import Net, dest_of, hdr, row, merge_ratchet_files

with Net() as net:
    A, _ = dest_of(net, "A")
    peer = net.add("peer", a_key=net.key("P"), a_name="peer")
    X = net.add("X", a_key=net.key("A"), a_name="Alice")
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice")
    X.call("announce"); time.sleep(3)
    merge_ratchet_files([Y.call("ratchet_file"), X.call("ratchet_file")], net.key("A"), Y.call("ratchet_file"))
    Y.call("reload_ratchets")
    X.call("noprove")                                  # X's proofs get "lost"
    t0 = time.time()
    peer.call("send", id="d1", to=A, content="same message")
    time.sleep(3)
    Y.call("announce")                                 # takeover before the first retry
    time.sleep(40)
    hdr("results")
    rx_x, rx_y = X.evs("rx"), Y.evs("rx")
    row("X rx:", [(e["hash"][:12], "+%.1fs" % (e["t"] - t0)) for e in rx_x])
    row("Y rx:", [(e["hash"][:12], "+%.1fs" % (e["t"] - t0)) for e in rx_y])
    row("same LXMF hash on both devices:", bool(rx_x and rx_y and rx_x[0]["hash"] == rx_y[0]["hash"]))
    dl = peer.evs("msg_delivered", id="d1")
    row("sender: delivered callbacks =", len(dl), "| state =", peer.call("msg_state", id="d1"),
        "| delivered at +%.1fs" % (dl[0]["t"] - t0) if dl else "")
    # a second duplicate to the SAME device: LXMF drops it silently (per-router store), but still proves it
    peer.call("send", id="d2", to=A, content="same device twice")
    time.sleep(6)
    print("\nDONE exp5")
