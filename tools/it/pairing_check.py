#!/usr/bin/env python3
"""Cross-check of the Dart pairing codec against the bridge's own implementation.

usage: pairing_check.py sign <qr_text> <approver_device_id_hex>
         -> prints the bytes the approver must sign (hex), computed by the bridge from the QR text
       pairing_check.py encode <pubkey_hex> <name> <platform> <nonce_hex> <ts>
         -> prints the QR text produced by the bridge's encoder
       pairing_check.py parse <qr_text>
         -> prints the bridge's parse of the payload as JSON
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "bridge"))
from kestrel_bridge.devices import (decode_pairing_qr, encode_pairing_qr, pairing_sign_message,  # noqa: E402
                                    parse_pairing_payload)


def main():
    mode = sys.argv[1]
    if mode == "sign":
        payload = decode_pairing_qr(sys.argv[2])
        print(pairing_sign_message(payload, sys.argv[3]).hex())
    elif mode == "encode":
        print(encode_pairing_qr(bytes.fromhex(sys.argv[2]), sys.argv[3], sys.argv[4], bytes.fromhex(sys.argv[5]),
                                float(sys.argv[6])))
    elif mode == "parse":
        print(json.dumps(parse_pairing_payload(decode_pairing_qr(sys.argv[2])), default=str))


main()
