"""Announce stamp cost / portability (found while setting up the harness).

RNS 1.6.1 stamps every announce destination with a proof of work, generated ONCE per destination and persisted
(RNS/Stamps.py store_destination_stamp / load_destination_stamp; default cost RNS.Transport.DESTINATION_VALUE = 25).
The stamp material is hash+public_key+name_hash, so it is identical on every device holding A.
This script measures (with the REAL default cost 25, expect ~1 min of single-core CPU in Python):
  1. time until a first announce of A from X reaches the peer (stamp generated on demand)
  2. copy X's stamp file to Y -> time until Y's announce reaches the peer
Run: python tools/spikes/device_group/exp8_stamp.py
"""
import os, shutil, time
from harness import Net, dest_of, hdr, row

with Net() as net:
    A, _ = dest_of(net, "A")
    peer = net.add("peer", a_key=net.key("P"), a_name="peer")
    kw = dict(stamp_value=25)
    X = net.add("X", a_key=net.key("A"), a_name="Alice", **kw)
    Y = net.add("Y", a_key=net.key("A"), a_name="Alice", **kw)
    hdr("X: first announce, stamp generated on demand")
    t = time.time(); X.call("announce")
    e = peer.wait(lambda e: e["ev"] == "announce_rx" and e["dest"] == A, 400, since=t)
    row("announce reached the peer after %.1fs" % (e["t"] - t) if e else "no announce in 400 s")
    sf = X.call("stamp_file"); row("stamp file on X:", os.path.basename(sf), os.path.getsize(sf), "bytes")
    hdr("Y: copy X's stamp file, announce")
    os.makedirs(os.path.dirname(Y.call("stamp_file")), exist_ok=True)
    shutil.copyfile(sf, Y.call("stamp_file"))
    # Y registered its destination before the file existed; RNS loads the file lazily in _await_stamp
    time.sleep(1.1); t = time.time(); Y.call("announce")
    e = peer.wait(lambda e: e["ev"] == "announce_rx" and e["dest"] == A, 400, since=t)
    row("announce reached the peer after %.1fs" % (e["t"] - t) if e else "no announce in 400 s")
    print("\nDONE exp8")
