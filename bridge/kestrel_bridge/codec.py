"""msgpack codec and response envelopes."""
from __future__ import annotations

import msgpack

from . import errors

PROTOCOL_VERSION = 1

# Wire-level markers inside LXMF custom fields (FIELD_CUSTOM_TYPE value).
LXMF_TYPE_CMD = b"kestrel.cmd"
LXMF_TYPE_RESP = b"kestrel.resp"
LXMF_TYPE_PUSH = b"kestrel.push"


def pack(obj) -> bytes:
    return msgpack.packb(obj, use_bin_type=True)


def unpack(data, max_bytes: int = 1 << 20):
    if not isinstance(data, (bytes, bytearray)):
        raise errors.BridgeError(errors.BAD_REQUEST, "payload is not binary")
    if len(data) > max_bytes:
        raise errors.BridgeError(errors.TOO_LARGE, f"payload exceeds {max_bytes} bytes")
    try:
        return msgpack.unpackb(
            bytes(data),
            raw=False,
            strict_map_key=True,
            max_map_len=256,
            max_array_len=5000,
            max_str_len=max_bytes,
            max_bin_len=max_bytes,
        )
    except Exception as e:  # msgpack raises several unrelated exception types
        raise errors.BridgeError(errors.BAD_REQUEST, f"invalid msgpack: {type(e).__name__}") from None


def ok(result: dict) -> dict:
    return {"ok": True, "result": result}


def err(code: str, message: str = "", **details) -> dict:
    return errors.BridgeError(code, message, **details).to_wire()


def clamp_response(resp: dict, max_bytes: int) -> dict:
    """Replace a response that would exceed ``max_bytes`` by a response_too_large error."""
    size = len(pack(resp))
    if size > max_bytes:
        return err(errors.RESPONSE_TOO_LARGE, f"response of {size} bytes exceeds {max_bytes}", size=size, max=max_bytes)
    return resp
