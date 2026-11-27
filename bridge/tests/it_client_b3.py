"""Integration helper: a new device B3 that joins through an invite (``/devices/invite`` + ``/devices/redeem``).

usage: python -m tests.it_client_b3 <config_dir> <identity_file> <bridge_pubkey_hex> <token_file>
Prints "RESULT <name> <json>" lines. B3 is unknown to the bridge: it checks that a wrong token fails, that the right
token turns its Link into a trusted one (no reconnect), that the token cannot be used twice, and that /hello can set
the device name.
"""
import os
import sys
import time

import msgpack
import RNS

from tests import it_vault as V
from tests.it_client_b import connect, find_path, out, request, wait


def main() -> None:
    cfgdir, idfile, s_pub, token_file = sys.argv[1:5]
    RNS.Reticulum(configdir=cfgdir, loglevel=int(os.environ.get("IT_RNS_LOG", RNS.LOG_WARNING)))
    b3 = RNS.Identity.from_file(idfile)
    s_ident = RNS.Identity(create_keys=False)
    s_ident.load_public_key(bytes.fromhex(s_pub))
    dest = RNS.Destination(s_ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "kestrel", "bridge")
    find_path(dest, 35)
    wait(lambda: os.path.exists(token_file) and os.path.getsize(token_file) > 0, 90, "token file")
    with open(token_file) as f:
        token = bytes.fromhex(f.read().strip())

    def new_link(identity, packets):
        link = connect(dest)
        link.set_packet_callback(lambda data, pkt: packets.append(msgpack.unpackb(data, raw=False)))
        link.identify(identity)
        return link

    # 1. a wrong token: pairing_invalid, then the Link is closed
    packets = []
    link = new_link(b3, packets)
    out("b3_wrong", request(link, "/devices/redeem", {"token": os.urandom(16), "name": "B3", "platform": "linux"},
                            timeout=15))
    out("b3_other_path", request(link, "/devices/list", {}, timeout=15))
    wait(lambda: link.status == RNS.Link.CLOSED, 15, "link closed after a failed redeem")
    out("b3_closed_after_failure", True)

    # 2. the right token on a fresh Link: the same Link is trusted afterwards
    packets = []
    link = new_link(b3, packets)
    out("b3_redeem", request(link, "/devices/redeem", {"token": token, "name": "Invited PC", "platform": "windows"}))
    out("b3_hello", request(link, "/hello", {"protocol_version": 2, "client": "it-b3", "name": "Invited PC 2",
                                              "platform": "windows"}))
    out("b3_list", request(link, "/devices/list", {}))
    # the vault is in use: the invite brought the key chain, wrapped to the secret that was only in the QR code
    with open(os.path.join(os.path.dirname(token_file), "invite.secret")) as f:
        secret = bytes.fromhex(f.read().strip())
    key = request(link, "/vault/key", {})["result"]
    chain = V.unwrap_invite(key["wrapped_group_key"], secret)
    lst = request(link, "/vault/list", {})["result"]
    got = request(link, "/vault/get", {"blob_ids": [m["blob_id"] for m in lst["blobs"]]})["result"]
    plain = V.decrypt_blob(chain, lst["blobs"][0], got["blobs"][0]["ciphertext"])
    out("b3_vault", {"wrap": key["wrap"], "epoch": key["wrapped_epoch"], "in_use": key["in_use"],
                     "chain_epochs": sorted(chain), "records": plain["data"]["records"]})
    time.sleep(6.5)      # longer than the reject grace: the redeemed Link must stay up
    out("b3_still_up", link.status == RNS.Link.ACTIVE)
    out("b3_hello_late", request(link, "/hello", {"protocol_version": 2}))

    # 3. the token cannot be used twice
    other = RNS.Identity()
    link2 = new_link(other, [])
    out("b3_replay", request(link2, "/devices/redeem", {"token": token, "name": "Thief", "platform": "linux"},
                             timeout=15))
    for l in (link, link2):
        try:
            l.teardown()
        except Exception:
            pass
    out("B3_DONE", True)


if __name__ == "__main__":
    main()
