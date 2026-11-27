"""Vault: opaque, append-only ciphertext storage and group-key epochs (protocol v2, Phase 4b server side).

The bridge never sees plaintext and never holds a group key: it stores blobs it cannot read and, per
device, the group key *wrapped to that device's identity* (also opaque). See docs/bridge-protocol.md,
section 8, for the client-side crypto envelope.
"""
from __future__ import annotations

import hashlib
import re
import time

from . import errors
from .config import Limits
from .errors import BridgeError
from .state import State

HEX32_RE = re.compile(r"^[0-9a-f]{32}$")
WRAPPED_MAX_BYTES = 4096


def _int(args: dict, key: str, minimum: int = 0, required: bool = True) -> int | None:
    v = args.get(key)
    if v is None and not required:
        return None
    if isinstance(v, bool) or not isinstance(v, int) or v < minimum:
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be an integer >= {minimum}")
    return v


def _bytes(args: dict, key: str, max_len: int) -> bytes:
    v = args.get(key)
    if not isinstance(v, (bytes, bytearray)) or not 1 <= len(v) <= max_len:
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be 1-{max_len} bytes (binary)")
    return bytes(v)


def meta_of(row) -> dict:
    return {"vcursor": row[0], "blob_id": row[1], "device_id": row[2], "seq": row[3], "key_epoch": row[4],
            "size": row[5], "sha256": row[6], "ts": row[7]}


_META = "vcursor, blob_id, device_id, seq, key_epoch, size, sha256, ts"


class Vault:
    def __init__(self, state: State, limits: Limits, clock=time.time):
        self.state = state
        self.limits = limits
        self._clock = clock

    # ---- epochs and keys ---------------------------------------------------------------------
    def epoch(self) -> int:
        return int(self.state.meta_get("vault_epoch", "1"))

    def keys_epoch(self) -> int:
        return int(self.state.meta_get("vault_keys_epoch", "0"))

    def in_use(self) -> bool:
        """Group keys were distributed (``/vault/set_keys``); from then on keys_epoch == epoch."""
        return self.keys_epoch() >= 1

    def key_of(self, device_id: str) -> dict:
        rows = self.state.query("SELECT epoch, wrapped, kind FROM device_keys WHERE device_id=?", (device_id,))
        return {"key_epoch": self.epoch(), "in_use": self.in_use(),
                "wrapped_epoch": rows[0][0] if rows else None,
                "wrapped_group_key": bytes(rows[0][1]) if rows else None,
                "wrap": rows[0][2] if rows else None}

    def _check_wrapped(self, wrapped, expected_ids: set[str]) -> dict[str, bytes]:
        if not isinstance(wrapped, dict):
            raise BridgeError(errors.BAD_REQUEST, "wrapped keys must be a map device_id -> binary")
        clean = {}
        for did, blob in wrapped.items():
            if not isinstance(did, str) or not isinstance(blob, (bytes, bytearray)) \
                    or not 1 <= len(blob) <= WRAPPED_MAX_BYTES:
                raise BridgeError(errors.BAD_REQUEST, f"wrapped key for {did!r} must be 1-{WRAPPED_MAX_BYTES} bytes")
            clean[did] = bytes(blob)
        missing, extra = sorted(expected_ids - set(clean)), sorted(set(clean) - expected_ids)
        if missing or extra:
            raise BridgeError(errors.BAD_REQUEST, "wrapped keys must cover exactly the active devices",
                              missing=missing, unexpected=extra)
        return clean

    def validate_revoke_keys(self, args: dict, remaining_ids: set[str]) -> dict[str, bytes] | None:
        """Keys for the epoch after a revocation: required when the vault is in use."""
        if not self.in_use():
            if args.get("wrapped_group_keys") is not None:
                raise BridgeError(errors.BAD_REQUEST, "the vault is not in use: omit 'wrapped_group_keys'")
            return None
        new_epoch = _int(args, "key_epoch", 1)
        if new_epoch != self.epoch() + 1:
            raise BridgeError(errors.KEY_EPOCH_STALE, "'key_epoch' must be the current epoch + 1",
                              key_epoch=self.epoch())
        return self._check_wrapped(args.get("wrapped_group_keys"), remaining_ids)

    def apply_revocation(self, revoked_id: str, wrapped: dict[str, bytes] | None) -> int:
        """Bump the epoch (caller holds the transaction). Returns the new epoch."""
        new = self.epoch() + 1
        self.state.meta_set("vault_epoch", str(new))
        if wrapped is not None:
            now = self._clock()
            self.state.execute("DELETE FROM device_keys")
            for did, blob in wrapped.items():
                self.state.execute("INSERT OR REPLACE INTO device_keys(device_id, epoch, wrapped, updated_at) "
                                   "VALUES(?,?,?,?)", (did, new, blob, now))
            self.state.meta_set("vault_keys_epoch", str(new))
        return new

    def set_keys(self, args: dict, active_ids: set[str]) -> dict:
        """Activate the vault: wrapped group key for every active device."""
        if self.in_use():
            raise BridgeError(errors.KEYS_ALREADY_SET, "group keys are already distributed", key_epoch=self.epoch())
        epoch = _int(args, "key_epoch", 1)
        if epoch != self.epoch():
            raise BridgeError(errors.KEY_EPOCH_STALE, "'key_epoch' must be the current epoch", key_epoch=self.epoch())
        wrapped = self._check_wrapped(args.get("wrapped_group_keys"), active_ids)
        now = self._clock()
        with self.state.transaction():
            for did, blob in wrapped.items():
                self.state.execute("INSERT OR REPLACE INTO device_keys(device_id, epoch, wrapped, updated_at) "
                                   "VALUES(?,?,?,?)", (did, epoch, blob, now))
            self.state.meta_set("vault_keys_epoch", str(epoch))
        return {"key_epoch": epoch}

    def store_device_key(self, device_id: str, wrapped: bytes, kind: str = "identity") -> None:
        self.state.execute("INSERT OR REPLACE INTO device_keys(device_id, epoch, wrapped, updated_at, kind) "
                           "VALUES(?,?,?,?,?)", (device_id, self.epoch(), wrapped, self._clock(), kind))

    def check_invite_key(self, args: dict) -> tuple[int, bytes] | None:
        """``/devices/invite`` while the vault is in use: the chain wrapped to the invite secret (required);
        while it is not in use the fields MUST be omitted. Returns (epoch, wrapped) or None."""
        wrapped = args.get("wrapped_group_key")
        if not self.in_use():
            if wrapped is not None or args.get("key_epoch") is not None:
                raise BridgeError(errors.BAD_REQUEST,
                                  "the vault is not in use: omit 'key_epoch' and 'wrapped_group_key'")
            return None
        if _int(args, "key_epoch", 1) != self.epoch():
            raise BridgeError(errors.KEY_EPOCH_STALE, "'key_epoch' is not the current epoch", key_epoch=self.epoch())
        return self.epoch(), _bytes(args, "wrapped_group_key", WRAPPED_MAX_BYTES)

    def check_approve_key(self, args: dict) -> bytes | None:
        """The wrapped group key an approving device supplies for the new device."""
        wrapped = args.get("wrapped_group_key")
        if not self.in_use():
            if wrapped is not None:
                raise BridgeError(errors.BAD_REQUEST, "the vault is not in use: omit 'wrapped_group_key'")
            return None
        if _int(args, "key_epoch", 1) != self.epoch():
            raise BridgeError(errors.KEY_EPOCH_STALE, "'key_epoch' is not the current epoch", key_epoch=self.epoch())
        return _bytes(args, "wrapped_group_key", WRAPPED_MAX_BYTES)

    # ---- blobs -------------------------------------------------------------------------------
    def usage(self, device_id: str | None = None) -> int:
        if device_id is None:
            rows = self.state.query("SELECT COALESCE(SUM(size), 0) FROM vault_blobs")
        else:
            rows = self.state.query("SELECT COALESCE(SUM(size), 0) FROM vault_blobs WHERE device_id=?", (device_id,))
        return int(rows[0][0])

    def put(self, device_id: str, args: dict) -> dict:
        blob_id = args.get("blob_id")
        if not isinstance(blob_id, str) or not HEX32_RE.match(blob_id):
            raise BridgeError(errors.BAD_REQUEST, "'blob_id' must be 32 lowercase hex chars")
        if args.get("device_id") != device_id:
            raise BridgeError(errors.FORBIDDEN, "'device_id' must be the calling device")
        seq = _int(args, "seq", 1)
        key_epoch = _int(args, "key_epoch", 1)
        data = args.get("ciphertext")
        if not isinstance(data, (bytes, bytearray)) or not data:
            raise BridgeError(errors.BAD_REQUEST, "'ciphertext' must be non-empty binary")
        if len(data) > self.limits.vault_max_blob_bytes:
            raise BridgeError(errors.BLOB_TOO_LARGE, f"ciphertext exceeds {self.limits.vault_max_blob_bytes} bytes",
                              max=self.limits.vault_max_blob_bytes)
        data = bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        with self.state.transaction():
            rows = self.state.query(f"SELECT {_META} FROM vault_blobs WHERE blob_id=?", (blob_id,))
            if rows:
                m = meta_of(rows[0])
                if m["device_id"] == device_id and m["seq"] == seq and m["sha256"] == digest:
                    return {**m, "duplicate": True}      # a retry after a lost response
                raise BridgeError(errors.BLOB_CONFLICT, "blob_id already exists with different content")
            if key_epoch != self.epoch():
                raise BridgeError(errors.KEY_EPOCH_STALE, "'key_epoch' is not the current epoch",
                                  key_epoch=self.epoch())
            last = int(self.state.query("SELECT COALESCE(MAX(seq), 0) FROM vault_blobs WHERE device_id=?",
                                        (device_id,))[0][0])
            if seq != last + 1:
                raise BridgeError(errors.SEQ_CONFLICT, "'seq' must be the last seq of this device + 1", last_seq=last)
            used = self.usage(device_id)
            if used + len(data) > self.limits.vault_device_quota_bytes:
                raise BridgeError(errors.QUOTA_EXCEEDED, "device vault quota exceeded", scope="device", used=used,
                                  quota=self.limits.vault_device_quota_bytes)
            total = self.usage()
            if total + len(data) > self.limits.vault_total_quota_bytes:
                raise BridgeError(errors.QUOTA_EXCEEDED, "vault is full", scope="total", used=total,
                                  quota=self.limits.vault_total_quota_bytes)
            ts = self._clock()
            self.state.execute(
                "INSERT INTO vault_blobs(blob_id, device_id, seq, key_epoch, size, sha256, ts, data) "
                "VALUES(?,?,?,?,?,?,?,?)", (blob_id, device_id, seq, key_epoch, len(data), digest, ts, data))
            row = self.state.query(f"SELECT {_META} FROM vault_blobs WHERE blob_id=?", (blob_id,))[0]
        return {**meta_of(row), "duplicate": False}

    def list(self, args: dict, page_max: int) -> dict:
        cursor = _int(args, "cursor", 0, required=False) or 0
        limit = min(_int(args, "limit", 1, required=False) or page_max, page_max)
        where, params = "vcursor > ?", [cursor]
        if args.get("device_id") is not None:
            if not isinstance(args["device_id"], str) or not HEX32_RE.match(args["device_id"]):
                raise BridgeError(errors.BAD_REQUEST, "'device_id' must be a 32-char hex id")
            where += " AND device_id=?"
            params.append(args["device_id"])
        rows = self.state.query(f"SELECT {_META} FROM vault_blobs WHERE {where} ORDER BY vcursor LIMIT ?",
                                params + [limit + 1])
        more = len(rows) > limit
        blobs = [meta_of(r) for r in rows[:limit]]
        return {"blobs": blobs, "cursor": blobs[-1]["vcursor"] if blobs else cursor, "more": more,
                "key_epoch": self.epoch()}

    def get(self, args: dict, max_response_bytes: int) -> dict:
        ids = args.get("blob_ids")
        if not isinstance(ids, list) or not 1 <= len(ids) <= self.limits.vault_get_max_ids \
                or not all(isinstance(i, str) and HEX32_RE.match(i) for i in ids):
            raise BridgeError(errors.BAD_REQUEST,
                              f"'blob_ids' must be 1-{self.limits.vault_get_max_ids} 32-char hex ids")
        budget = max_response_bytes - 4096
        blobs, missing, truncated = [], [], []
        for bid in ids:
            rows = self.state.query(f"SELECT {_META}, data FROM vault_blobs WHERE blob_id=?", (bid,))
            if not rows:
                missing.append(bid)
                continue
            size = rows[0][5]
            if size + 256 > budget:
                truncated.append(bid)       # does not fit this response: ask again with fewer ids
                continue
            budget -= size + 256
            blobs.append({**meta_of(rows[0]), "ciphertext": bytes(rows[0][8])})
        return {"blobs": blobs, "missing": missing, "truncated": truncated}
