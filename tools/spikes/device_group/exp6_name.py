"""Q6 - announce app_data / display name.

Devices X and Y hold the same A but are configured with DIFFERENT display names. We look at what the peer learns
from announces, whether the name travels in messages, and which name wins after handover / path responses.
Run: python tools/spikes/device_group/exp6_name.py
"""
import time
import RNS.vendor.umsgpack as mp
from harness import Net, dest_of, hdr, row

with Net() as net:
    A, _ = dest_of(net, "A")
    peer = net.add("peer", a_key=net.key("P"), a_name="peer")
    X = net.add("X", a_key=net.key("A"), a_name="Alice (laptop)")
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice (phone)")
    for d in (X, Y): d.call("ratchets_off")
    seq = []
    for d in (X, Y, X, Y):
        t = time.time(); d.call("announce"); e = peer.wait(lambda e: e["ev"] == "announce_rx" and e["dest"] == A, 15, since=t)
        seq.append((d.name, e["display_name"], mp.unpackb(bytes.fromhex(e["app_data"])) if e else None))
        time.sleep(1.2)
    hdr("name the peer learns after each announce (last announcer wins)")
    for s in seq: row("announced by", s[0], "-> peer sees", s[1], "| raw app_data =", s[2])
    hdr("name inside messages?")
    X.call("announce"); time.sleep(2.5)
    peer.call("send", id="n1", to=A, content="hello"); time.sleep(3)
    rx = X.evs("rx")[-1]
    row("rx event fields available to the receiver:", sorted(k for k in rx if k not in ("t", "who", "ev")),
        "-> no display name field; LXMessage carries only source hash + title/content/fields")
    print("\nDONE exp6")
