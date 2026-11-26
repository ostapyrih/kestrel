"""Device registry (bootstrap + dynamic devices) and QR pairing helpers (protocol v2)."""
from __future__ import annotations

import base64
import logging
import re
import threading
import time
from dataclasses import dataclass

from . import codec, errors
from .errors import BridgeError
from .state import State, device_id_of_pubkey

log = logging.getLogger("kestrel.devices")

PUBKEY_BYTES = 64
ROLE_FIELD = "field"          # gets the LXMF/LoRa fallback push when it has no live Link
ROLES = (ROLE_FIELD,)
PLATFORM_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
NAME_MAX_BYTES = 64
LAST_SEEN_WRITE_INTERVAL = 60.0

PAIR_PREFIX = "kestrel-pair:v1:"
PAIR_SIG_DOMAIN = b"kestrel-pair-approve:v1:"
NONCE_MIN, NONCE_MAX = 16, 32


def device_id_of(public_key: str | bytes) -> str:
    return device_id_of_pubkey(public_key.hex() if isinstance(public_key, (bytes, bytearray)) else public_key)


def validate_name(v) -> str:
    if not isinstance(v, str):
        raise BridgeError(errors.BAD_REQUEST, "'name' must be a string")
    v = v.strip()
    if not v or len(v.encode("utf-8")) > NAME_MAX_BYTES or any(ord(c) < 32 or ord(c) == 127 for c in v):
        raise BridgeError(errors.BAD_REQUEST, f"'name' must be 1-{NAME_MAX_BYTES} bytes without control characters")
    return v


def validate_platform(v) -> str:
    if not isinstance(v, str) or not PLATFORM_RE.match(v):
        raise BridgeError(errors.BAD_REQUEST, "'platform' must match [a-z0-9][a-z0-9._-]{0,31}")
    return v


def validate_roles(v) -> tuple[str, ...]:
    if not isinstance(v, (list, tuple)) or not all(isinstance(r, str) for r in v) or any(r not in ROLES for r in v):
        raise BridgeError(errors.BAD_REQUEST, f"'roles' must be a list of {list(ROLES)}")
    return tuple(sorted(set(v)))


@dataclass(frozen=True)
class Device:
    device_id: str
    public_key: str
    name: str
    platform: str
    roles: tuple[str, ...]
    bootstrap: bool
    added_by: str
    added_at: float
    last_seen: float | None
    revoked_at: float | None

    @property
    def revoked(self) -> bool:
        return self.revoked_at is not None

    @property
    def field(self) -> bool:
        return ROLE_FIELD in self.roles

    def to_wire(self) -> dict:
        return {"device_id": self.device_id, "public_key": self.public_key, "name": self.name,
                "platform": self.platform, "roles": list(self.roles), "bootstrap": self.bootstrap,
                "added_by": self.added_by, "added_at": self.added_at, "last_seen": self.last_seen,
                "revoked_at": self.revoked_at}


_COLS = ("device_id, public_key, name, platform, roles, bootstrap, added_by, added_at, last_seen, revoked_at")


def _row(r) -> Device:
    return Device(r[0], r[1], r[2], r[3], tuple(x for x in r[4].split(",") if x), bool(r[5]), r[6], r[7], r[8], r[9])


class DeviceRegistry:
    """All devices. Bootstrap devices come from the config, dynamic ones from QR pairing; both live in
    the state database, which is authoritative for ``revoked_at``, ``name`` and ``roles``.

    Listeners get ``(event, device)`` with event in ``added``, ``updated``, ``revoked`` after the change
    was committed.
    """

    def __init__(self, state: State, max_devices: int = 16, clock=time.time):
        self.state = state
        self.max_devices = max_devices
        self._clock = clock
        self._lock = threading.RLock()
        self._cache: dict[str, Device] = {}
        self._seen_written: dict[str, float] = {}
        self._listeners: list = []
        self.load()

    # ---- reading -----------------------------------------------------------------------------
    def load(self) -> None:
        with self._lock:
            rows = self.state.query(f"SELECT {_COLS} FROM devices ORDER BY added_at, rowid")
            self._cache = {r[0]: _row(r) for r in rows}

    def get(self, device_id: str) -> Device | None:
        return self._cache.get(device_id)

    def by_pubkey(self, public_key_hex: str) -> Device | None:
        if not isinstance(public_key_hex, str) or len(public_key_hex) != PUBKEY_BYTES * 2:
            return None
        d = self._cache.get(device_id_of(public_key_hex))
        return d if d is not None and d.public_key == public_key_hex.lower() else None

    def trusted(self, device_id: str) -> Device | None:
        d = self._cache.get(device_id)
        return d if d is not None and not d.revoked else None

    def trusted_by_pubkey(self, public_key_hex: str) -> Device | None:
        d = self.by_pubkey(public_key_hex)
        return d if d is not None and not d.revoked else None

    def all(self, include_revoked: bool = True) -> list[Device]:
        return sorted((d for d in self._cache.values() if include_revoked or not d.revoked),
                      key=lambda d: d.added_at)     # stable: ties keep insertion order

    def trusted_devices(self) -> list[Device]:
        return self.all(include_revoked=False)

    def field_devices(self) -> list[Device]:
        return [d for d in self.trusted_devices() if d.field]

    # ---- listeners ---------------------------------------------------------------------------
    def subscribe(self, listener) -> None:
        self._listeners.append(listener)

    def emit(self, event: str, device: Device) -> None:
        for fn in list(self._listeners):
            try:
                fn(event, device)
            except Exception:
                log.exception("device listener failed")

    # ---- writing -----------------------------------------------------------------------------
    def _store(self, d: Device) -> None:
        self.state.execute(
            f"INSERT OR REPLACE INTO devices({_COLS}) VALUES(?,?,?,?,?,?,?,?,?,?)",
            (d.device_id, d.public_key, d.name, d.platform, ",".join(d.roles), int(d.bootstrap), d.added_by,
             d.added_at, d.last_seen, d.revoked_at))

    def sync_bootstrap(self, seeds) -> dict:
        """Apply ``[[devices]]`` at start. Seeds only create missing devices (and mark existing ones as
        bootstrap); they never un-revoke and never overwrite a name/roles edited through the protocol.
        A device that used to be bootstrap but is no longer in the config is revoked (fail closed)."""
        now = self._clock()
        out = {"added": [], "removed": []}
        wanted = {device_id_of(s.public_key) for s in seeds}
        with self._lock, self.state.transaction():
            for s in seeds:
                did = device_id_of(s.public_key)
                cur = self._cache.get(did)
                if cur is None:
                    d = Device(did, s.public_key, s.name, s.platform, tuple(s.roles), True, "config", now, None, None)
                    self._store(d)
                    self._cache[did] = d
                    out["added"].append(did)
                elif not cur.bootstrap:
                    d = Device(**{**cur.__dict__, "bootstrap": True})
                    self._store(d)
                    self._cache[did] = d
            for cur in list(self._cache.values()):
                if cur.bootstrap and cur.device_id not in wanted:
                    d = Device(**{**cur.__dict__, "bootstrap": False,
                                  "revoked_at": cur.revoked_at if cur.revoked else now})
                    self._store(d)
                    if not cur.revoked:
                        self.state.execute("UPDATE devices SET revoked_by=?, revoke_reason=? WHERE device_id=?",
                                           ("config", "removed from config", cur.device_id))
                    self._cache[cur.device_id] = d
                    out["removed"].append(cur.device_id)
        return out

    def add(self, public_key: str, name: str, platform: str, roles, added_by: str, emit: bool = True) -> Device:
        public_key = public_key.lower()
        did = device_id_of(public_key)
        with self._lock:
            cur = self._cache.get(did)
            if cur is not None:
                raise BridgeError(errors.DEVICE_REVOKED if cur.revoked else errors.DEVICE_EXISTS,
                                  "this device identity was revoked and cannot be paired again" if cur.revoked
                                  else "device is already paired", device_id=did)
            if len(self.trusted_devices()) >= self.max_devices:
                raise BridgeError(errors.TOO_MANY_DEVICES, f"at most {self.max_devices} devices", max=self.max_devices)
            d = Device(did, public_key, validate_name(name), validate_platform(platform), validate_roles(roles),
                       False, added_by, self._clock(), None, None)
            self._store(d)
            self._cache[did] = d
        if emit:
            self.emit("added", d)
        return d

    def _require(self, device_id: str) -> Device:
        d = self._cache.get(device_id)
        if d is None:
            raise BridgeError(errors.DEVICE_NOT_FOUND, "unknown device", device_id=device_id)
        return d

    def update(self, device_id: str, name: str | None = None, roles=None) -> Device:
        with self._lock:
            cur = self._require(device_id)
            if cur.revoked:
                raise BridgeError(errors.DEVICE_REVOKED, "device is revoked", device_id=device_id)
            d = Device(**{**cur.__dict__, "name": validate_name(name) if name is not None else cur.name,
                          "roles": validate_roles(roles) if roles is not None else cur.roles})
            self._store(d)
            self._cache[device_id] = d
        self.emit("updated", d)
        return d

    def revoke(self, device_id: str, by: str, reason: str | None = None, emit: bool = True) -> Device:
        """Revoke a device. The last remaining trusted device cannot be revoked."""
        with self._lock:
            cur = self._require(device_id)
            if cur.revoked:
                raise BridgeError(errors.DEVICE_REVOKED, "device is already revoked", device_id=device_id)
            if len(self.trusted_devices()) <= 1:
                raise BridgeError(errors.LAST_DEVICE, "the last trusted device cannot be revoked")
            d = Device(**{**cur.__dict__, "revoked_at": self._clock()})
            with self.state.transaction():
                self._store(d)
                self.state.execute("UPDATE devices SET revoked_by=?, revoke_reason=? WHERE device_id=?",
                                   (by, (reason or "")[:64] or None, device_id))
                self.state.execute("DELETE FROM device_keys WHERE device_id=?", (device_id,))
            self._cache[device_id] = d
        if emit:
            self.emit("revoked", d)
        return d

    def reinstate(self, device_id: str) -> Device:
        """Operator action (``--reinstate``, state offline): clear ``revoked_at``."""
        with self._lock:
            cur = self._require(device_id)
            d = Device(**{**cur.__dict__, "revoked_at": None})
            self._store(d)
            self._cache[device_id] = d
        return d

    def touch_seen(self, device_id: str) -> None:
        now = self._clock()
        cur = self._cache.get(device_id)
        if cur is None:
            return
        with self._lock:
            self._cache[device_id] = Device(**{**cur.__dict__, "last_seen": now})
            if now - self._seen_written.get(device_id, 0.0) >= LAST_SEEN_WRITE_INTERVAL:
                self._seen_written[device_id] = now
                self.state.execute("UPDATE devices SET last_seen=? WHERE device_id=?", (now, device_id))


# ---- pairing ----------------------------------------------------------------------------------
def encode_pairing_qr(public_key: bytes, name: str, platform: str, nonce: bytes, ts: float) -> str:
    """Build the QR text (used by tests; a client implements the same)."""
    payload = codec.pack({"pubkey": bytes(public_key), "name": name, "platform": platform,
                          "nonce": bytes(nonce), "ts": ts})
    return PAIR_PREFIX + base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")


def decode_pairing_qr(text: str) -> bytes:
    """QR text -> the exact msgpack payload bytes (these bytes are what the approver signs)."""
    if not isinstance(text, str) or not text.startswith(PAIR_PREFIX):
        raise BridgeError(errors.PAIRING_INVALID, "not a kestrel-pair:v1 payload")
    body = text[len(PAIR_PREFIX):]
    try:
        return base64.b64decode(body + "=" * (-len(body) % 4), altchars=b"-_", validate=True)
    except Exception:
        raise BridgeError(errors.PAIRING_INVALID, "payload is not base64url") from None


def pairing_sign_message(payload: bytes, approver_id: str) -> bytes:
    """The bytes the approving device signs with its identity (Ed25519, ``Identity.sign``)."""
    return PAIR_SIG_DOMAIN + bytes(payload) + bytes.fromhex(approver_id)


def parse_pairing_payload(payload) -> dict:
    """Validate the decoded pairing map. Returns {pubkey(hex), name, platform, nonce(hex), ts}."""
    if not isinstance(payload, (bytes, bytearray)) or len(payload) > 1024:
        raise BridgeError(errors.PAIRING_INVALID, "'payload' must be the pairing bytes (<= 1024)")
    try:
        m = codec.unpack(bytes(payload), 1024)
    except BridgeError:
        raise BridgeError(errors.PAIRING_INVALID, "pairing payload is not valid msgpack") from None
    if not isinstance(m, dict):
        raise BridgeError(errors.PAIRING_INVALID, "pairing payload must be a map")
    pub, nonce, ts = m.get("pubkey"), m.get("nonce"), m.get("ts")
    if not isinstance(pub, (bytes, bytearray)) or len(pub) != PUBKEY_BYTES:
        raise BridgeError(errors.PAIRING_INVALID, "pairing 'pubkey' must be 64 bytes")
    if not isinstance(nonce, (bytes, bytearray)) or not NONCE_MIN <= len(nonce) <= NONCE_MAX:
        raise BridgeError(errors.PAIRING_INVALID, f"pairing 'nonce' must be {NONCE_MIN}-{NONCE_MAX} bytes")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        raise BridgeError(errors.PAIRING_INVALID, "pairing 'ts' must be a number")
    try:
        name, platform = validate_name(m.get("name")), validate_platform(m.get("platform"))
    except BridgeError as e:
        raise BridgeError(errors.PAIRING_INVALID, e.message) from None
    return {"pubkey": bytes(pub).hex(), "name": name, "platform": platform, "nonce": bytes(nonce).hex(),
            "ts": float(ts)}


def verify_signature(public_key_hex: str, signature, message: bytes) -> bool:
    """Ed25519 verification with the RNS identity of ``public_key_hex``."""
    if not isinstance(signature, (bytes, bytearray)) or len(signature) != 64:
        return False
    import RNS
    try:
        ident = RNS.Identity(create_keys=False)
        ident.load_public_key(bytes.fromhex(public_key_hex))
        return bool(ident.validate(bytes(signature), message))
    except Exception:
        return False
