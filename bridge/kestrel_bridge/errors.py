"""Error codes shared by every layer of the bridge (see docs/bridge-protocol.md section 9)."""

# Stable, wire-visible error codes.
BAD_REQUEST = "bad_request"
UNAUTHORIZED = "unauthorized"
UNKNOWN_PATH = "unknown_path"
PROTOCOL_MISMATCH = "protocol_mismatch"
TOO_LARGE = "request_too_large"
RESPONSE_TOO_LARGE = "response_too_large"
RATE_LIMITED = "rate_limited"
REPLAY = "replay"
TS_OUT_OF_WINDOW = "ts_out_of_window"
RRC_COMMAND_REJECTED = "rrc_command_rejected"
UNSUPPORTED_TRANSPORT = "unsupported_transport"
UPSTREAM_UNAVAILABLE = "upstream_unavailable"
UPSTREAM_AUTH = "upstream_auth"
UPSTREAM_INCOMPATIBLE = "upstream_incompatible"
UPSTREAM_ERROR = "upstream_error"
SEND_FAILED = "send_failed"
NOT_FOUND = "not_found"
INTERNAL = "internal"
# protocol v2: devices, pairing, vault
DEVICE_REVOKED = "device_revoked"
DEVICE_NOT_FOUND = "device_not_found"
DEVICE_EXISTS = "device_exists"
LAST_DEVICE = "last_trusted_device"
TOO_MANY_DEVICES = "too_many_devices"
PAIRING_INVALID = "pairing_invalid"
PAIRING_EXPIRED = "pairing_expired"
PAIRING_REPLAY = "pairing_replay"
BAD_SIGNATURE = "bad_signature"
FORBIDDEN = "forbidden"
KEY_EPOCH_STALE = "key_epoch_stale"
KEYS_ALREADY_SET = "keys_already_set"
BLOB_TOO_LARGE = "blob_too_large"
BLOB_CONFLICT = "blob_conflict"
SEQ_CONFLICT = "seq_conflict"
QUOTA_EXCEEDED = "quota_exceeded"

# Errors after which nothing was executed upstream: the phone may retry with the same cmd_id.
RETRYABLE = frozenset({UPSTREAM_UNAVAILABLE, UPSTREAM_AUTH, RATE_LIMITED})


class BridgeError(Exception):
    """An error that is reported to the phone as {"ok": false, "error": {...}}."""

    def __init__(self, code: str, message: str = "", **details):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.details = details

    def to_wire(self) -> dict:
        err = {"code": self.code, "message": self.message}
        if self.details:
            err["details"] = self.details
        return {"ok": False, "error": err}
