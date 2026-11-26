"""Integration helper: the second device B2 (paired by B1 through a QR payload).

usage: python -m tests.it_client_b2 <config_dir> <identity_file> <bridge_pubkey_hex> <peer_hash_hex>
Prints "RESULT <name> <json>" lines. B2 is not known to the bridge's config: it works only because B1 approved it.
It reports what it sees (hello, device list, the messages B1 sent), subscribes, then waits until the bridge closes
its Link (B1 revoked it) and checks that it is refused afterwards.
"""
import os
import sys
import time

import msgpack
import RNS

from tests.it_client_b import connect, find_path, out, request, wait


def main() -> None:
    cfgdir, idfile, s_pub, peer = sys.argv[1:5]
    RNS.Reticulum(configdir=cfgdir, loglevel=int(os.environ.get("IT_RNS_LOG", RNS.LOG_WARNING)))
    b2 = RNS.Identity.from_file(idfile)
    s_ident = RNS.Identity(create_keys=False)
    s_ident.load_public_key(bytes.fromhex(s_pub))
    dest = RNS.Destination(s_ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "kestrel", "bridge")
    find_path(dest, 35)

    box = {}
    link = RNS.Link(dest, established_callback=lambda l: box.update(up=True),
                    closed_callback=lambda l: box.update(closed=True))
    wait(lambda: box.get("up") or box.get("closed"), 60, "link")
    pushes = []
    link.set_packet_callback(lambda data, pkt: pushes.append(msgpack.unpackb(data, raw=False)))
    link.set_resource_strategy(RNS.Link.ACCEPT_ALL)
    link.set_resource_concluded_callback(lambda r: pushes.append(msgpack.unpackb(r.data.read(), raw=False)))
    link.identify(b2)
    time.sleep(1.0)
    out("b2_hello", request(link, "/hello", {"protocol_version": 2, "client": "it-b2"}))
    out("b2_devices", request(link, "/devices/list", {}))
    out("b2_messages", request(link, "/get_messages", {"peer": peer, "limit": 20}))
    out("b2_subscribe", request(link, "/subscribe", {"topics": ["lxmf", "vault"], "profile": "full"}))
    out("B2_READY", True)

    # B1 revokes this device now: the bridge tells it why (kestrel.reject device_revoked), then closes the Link
    wait(lambda: box.get("closed"), 90, "link closed by the bridge")
    out("b2_live_reject", [p for p in pushes if p.get("t") == "kestrel.reject"])
    out("B2_CLOSED", True)

    # and the revoked key is refused on a new Link
    retry = None
    try:
        retry = connect(dest)
        retry_packets = []
        retry.set_packet_callback(lambda data, pkt: retry_packets.append(msgpack.unpackb(data, raw=False)))
        retry.identify(b2)
        wait(lambda: retry_packets, 15, "kestrel.reject on reconnect")
        out("b2_retry_reject", retry_packets)
        try:
            out("b2_after", request(retry, "/hello", {"protocol_version": 2}, timeout=10))
        except Exception as e:      # the Link may already be gone: that is a refusal too
            out("b2_after", {"ok": False, "error": {"code": "link_closed", "message": type(e).__name__}})
    finally:
        if retry is not None:
            try:
                retry.teardown()
            except Exception:
                pass
    out("DONE", True)


if __name__ == "__main__":
    main()
