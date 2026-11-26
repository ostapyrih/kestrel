"""Integration helper: a Python client in the role of the phone identity B.

usage: python -m tests.it_client_b <config_dir> <identity_file> <bridge_pubkey_hex> <peer_hash_hex> <go_file> <qr_file> <revoke_file>
Prints "RESULT <name> <json>" lines; the test driver reads them.

B1 is the bootstrap device. Phase 1: the usual calls, then (1) it waits for <qr_file> (the pairing QR text of
device B2, written by the driver), approves it over its identified Link and waits for <revoke_file>, then (2)
revokes B2. After that it pauses (RESULT PHASE1) until <go_file> exists, forgets the path to S and calls /hello
again (phase 2: used after the test driver restarted the transport node).
"""
import json
import os
import sys
import time

import msgpack
import RNS

from kestrel_bridge.devices import decode_pairing_qr, pairing_sign_message


T0 = time.time()


def out(name, obj):
    print(f"RESULT {name} {json.dumps(obj, default=str)}", flush=True)
    if os.environ.get("IT_RNS_LOG"):
        print(f"  [{time.time() - T0:.1f}s] after {name}", flush=True)


def wait(cond, timeout, what):
    end = time.time() + timeout
    while not cond():
        if time.time() > end:
            out("TIMEOUT", what)
            sys.exit(3)
        time.sleep(0.1)


def request(link, path, data, timeout=40):
    receipt = link.request(path, data, timeout=timeout)
    wait(lambda: receipt.get_status() in (RNS.RequestReceipt.READY, RNS.RequestReceipt.FAILED), timeout + 5, path)
    if receipt.get_status() != RNS.RequestReceipt.READY:
        return None
    return receipt.get_response()


def connect(dest):
    box = {}
    link = RNS.Link(dest, established_callback=lambda l: box.update(up=True),
                    closed_callback=lambda l: box.update(closed=True))
    wait(lambda: box.get("up") or box.get("closed"), 60, "link")
    return link


def find_path(dest, timeout):
    end = time.time() + timeout
    while not RNS.Transport.has_path(dest.hash):
        if time.time() > end:
            out("TIMEOUT", "path")
            sys.exit(3)
        RNS.Transport.request_path(dest.hash)
        time.sleep(4)


def main() -> None:
    cfgdir, idfile, s_pub, peer, go_file, qr_file, revoke_file = sys.argv[1:8]
    RNS.Reticulum(configdir=cfgdir, loglevel=int(os.environ.get("IT_RNS_LOG", RNS.LOG_WARNING)))
    b = RNS.Identity.from_file(idfile)
    s_ident = RNS.Identity(create_keys=False)
    s_ident.load_public_key(bytes.fromhex(s_pub))
    dest = RNS.Destination(s_ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "kestrel", "bridge")
    find_path(dest, 35)

    # 1. an impostor (key not in the whitelist) must not get any service
    bad = connect(dest)
    bad_packets = []
    bad.set_packet_callback(lambda data, pkt: bad_packets.append(msgpack.unpackb(data, raw=False)))
    bad.identify(RNS.Identity())
    # the bridge tells an unknown key why it is not served (one kestrel.reject packet), then closes the Link
    wait(lambda: bad_packets, 15, "kestrel.reject for the impostor")
    out("impostor_reject", bad_packets)
    resp = request(bad, "/hello", {"protocol_version": 2}, timeout=10)
    out("impostor", resp if resp is None else resp)
    try:
        bad.teardown()
    except Exception:
        pass

    # 2. the real phone
    link = connect(dest)
    pushes = []
    link.set_packet_callback(lambda data, pkt: pushes.append(msgpack.unpackb(data, raw=False)))
    link.set_resource_strategy(RNS.Link.ACCEPT_ALL)
    link.set_resource_concluded_callback(lambda r: pushes.append(msgpack.unpackb(r.data.read(), raw=False)))
    # a request before identify() is refused
    out("pre_identify", request(link, "/hello", {"protocol_version": 2}, timeout=10))
    link.identify(b)
    time.sleep(1.0)
    out("hello_v1", request(link, "/hello", {"protocol_version": 1, "client": "old"}))
    out("hello", request(link, "/hello", {"protocol_version": 2, "client": "it"}))
    out("sync", request(link, "/sync_chats", {"cursor": 0}))
    out("messages", request(link, "/get_messages", {"peer": peer, "limit": 10}))
    out("send", request(link, "/send_lxmf", {"cmd_id": "it-cmd-000001", "to": peer, "text": "from phone"}))
    out("send_replay", request(link, "/send_lxmf", {"cmd_id": "it-cmd-000001", "to": peer, "text": "from phone"}))
    out("rrc_slash", request(link, "/send_rrc", {"cmd_id": "it-cmd-000002", "hub": "ee" * 16, "room": "g",
                                                  "text": "/join #evil"}))
    out("subscribe", request(link, "/subscribe", {"topics": ["lxmf", "rrc"], "profile": "full"}))
    out("SUBSCRIBED", True)
    wait(lambda: any(p.get("event") == "lxmf.message" for p in pushes), 60, "push")
    out("push", [p for p in pushes if p.get("event") == "lxmf.message"][0])

    # pairing: approve device B2 from its QR text, over this identified Link
    wait(lambda: os.path.exists(qr_file) and os.path.getsize(qr_file) > 0, 60, "qr file")
    with open(qr_file) as f:
        payload = decode_pairing_qr(f.read().strip())
    my_id = b.hash.hex()
    out("approve", request(link, "/devices/approve", {"payload": payload,
                                                     "signature": b.sign(pairing_sign_message(payload, my_id)),
                                                     "roles": ["field"]}))
    wait(lambda: any(p.get("event") == "device_added" for p in pushes), 30, "device_added push")
    out("device_added_push", [p for p in pushes if p.get("event") == "device_added"][0])
    out("PAIRED", True)
    # invite pairing: create an invite for device B3 (the driver starts it_client_b3 when the token file exists)
    inv = request(link, "/devices/invite", {})
    out("invite", {"ok": inv["ok"], "keys": sorted(inv["result"]) if inv["ok"] else None})
    with open(os.path.join(os.path.dirname(qr_file), "invite.token"), "w") as f:
        f.write(inv["result"]["token"].hex())
    wait(lambda: sum(1 for p in pushes if p.get("event") == "device_added") >= 2, 60, "device_added push for B3")
    out("invite_added_push", [p for p in pushes if p.get("event") == "device_added"][1])
    out("INVITED", True)
    wait(lambda: os.path.exists(revoke_file), 120, "revoke file")
    b2_id = next(p for p in pushes if p.get("event") == "device_added")["data"]["device"]["device_id"]
    out("revoke", request(link, "/devices/revoke", {"device_id": b2_id, "reason": "integration test"}))
    out("devices_after", request(link, "/devices/list", {}))
    wait(lambda: any(p.get("event") == "device_revoked" for p in pushes), 15, "device_revoked push")
    out("revoked_push", [p for p in pushes if p.get("event") == "device_revoked"])
    link.teardown()
    time.sleep(0.5)
    if go_file:
        out("PHASE1", True)
        wait(lambda: os.path.exists(go_file), 180, "go file")
        # the transport node was restarted: its path table is empty; S must be (re)found again.
        # Our own TCP interface may still be reconnecting, so retry with a fresh path lookup.
        link2 = None
        for attempt in range(6):
            RNS.Transport.expire_path(dest.hash)
            find_path(dest, 90)
            box = {}
            cand = RNS.Link(dest, established_callback=lambda l: box.update(up=True),
                            closed_callback=lambda l: box.update(closed=True))
            end = time.time() + 30
            while not (box.get("up") or box.get("closed")) and time.time() < end:
                time.sleep(0.1)
            if box.get("up") and cand.status == RNS.Link.ACTIVE:
                link2 = cand
                break
            out("link2_retry", attempt)
            try:
                cand.teardown()
            except Exception:
                pass
            time.sleep(3)
        if link2 is None:
            out("TIMEOUT", "link after restart")
            sys.exit(3)
        link2.identify(b)
        time.sleep(1.0)
        out("hello2", request(link2, "/hello", {"protocol_version": 2, "client": "it"}))
        link2.teardown()
        time.sleep(0.5)
    out("DONE", True)


if __name__ == "__main__":
    main()
