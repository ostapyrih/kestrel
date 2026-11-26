"""Invite tokens for the reverse pairing flow (``/devices/invite`` + ``/devices/redeem``, protocol v2 additive).

The trusted device shows a QR code that carries a one-time token; the new device redeems it over an
unauthenticated Link (the only path such a Link may call). Tokens are random 16 bytes, kept only as SHA-256
hashes and only in memory: an invite lives at most ``limits.invite_ttl`` (<= 600 s), so a bridge restart merely
makes open invites invalid.
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
import threading
from collections import deque

from . import errors
from .devices import DeviceRegistry, validate_name, validate_platform
from .errors import BridgeError

TOKEN_BYTES = 16


def token_hash(token: bytes) -> str:
    return hashlib.sha256(b"kestrel-invite:v1:" + token).hexdigest()


class _Invite:
    __slots__ = ("invite_id", "inviter", "created", "expires_at", "used_at", "redeemed_by")

    def __init__(self, invite_id: str, inviter: str, created: float, expires_at: float):
        self.invite_id = invite_id
        self.inviter = inviter
        self.created = created
        self.expires_at = expires_at
        self.used_at: float | None = None
        self.redeemed_by: str | None = None


class InviteStore:
    def __init__(self, limits, registry: DeviceRegistry, vault, clock):
        self.limits = limits
        self.registry = registry
        self.vault = vault
        self._clock = clock
        self._lock = threading.Lock()
        self._invites: dict[str, _Invite] = {}            # token hash -> invite
        self._fails: dict[str, deque] = {}                 # remote identity -> times of failed redeems

    # ---- housekeeping ------------------------------------------------------------------------
    def _purge(self, now: float) -> None:
        for h in [h for h, i in self._invites.items() if now > i.expires_at]:
            del self._invites[h]

    def open_count(self, inviter: str) -> int:
        now = self._clock()
        with self._lock:
            self._purge(now)
            return sum(1 for i in self._invites.values() if i.inviter == inviter and i.used_at is None)

    # ---- /devices/invite ---------------------------------------------------------------------
    def create(self, inviter: str) -> dict:
        if self.vault.in_use():
            raise BridgeError(errors.VAULT_IN_USE, "invites are not available while the vault is in use; "
                                                   "use QR pairing from the new device (/devices/approve)")
        now = self._clock()
        with self._lock:
            self._purge(now)
            if sum(1 for i in self._invites.values() if i.inviter == inviter and i.used_at is None) \
                    >= self.limits.max_open_invites:
                raise BridgeError(errors.RATE_LIMITED, "too many open invites", retry_after=60,
                                  max=self.limits.max_open_invites)
            token = secrets.token_bytes(TOKEN_BYTES)
            inv = _Invite(secrets.token_hex(16), inviter, now, now + self.limits.invite_ttl)
            self._invites[token_hash(token)] = inv
        return {"invite_id": inv.invite_id, "token": token, "expires_at": inv.expires_at}

    # ---- /devices/redeem ---------------------------------------------------------------------
    def _fail_check(self, who: str, now: float) -> None:
        q = self._fails.get(who)
        if q is not None:
            while q and now - q[0] > 60:
                q.popleft()
            if not q:
                del self._fails[who]
            elif len(q) >= self.limits.redeem_fail_rate_per_minute:
                raise BridgeError(errors.RATE_LIMITED, "too many failed redeem attempts", retry_after=60)

    def _fail(self, who: str, now: float) -> None:
        self._fails.setdefault(who, deque()).append(now)
        if len(self._fails) > 4096:                       # identities are free to mint: bound the table
            for k in [k for k, q in self._fails.items() if not q or now - q[-1] > 60]:
                del self._fails[k]

    def redeem(self, who: str, public_key: str, args: dict):
        """Validate the token and add the device. ``who`` identifies the remote identity (rate limit).
        Returns the new Device (the caller emits ``added``). A failed attempt consumes nothing."""
        now = self._clock()
        with self._lock:
            self._fail_check(who, now)
            try:
                return self._redeem(now, public_key, args)
            except BridgeError as e:
                if e.code in (errors.PAIRING_INVALID, errors.PAIRING_EXPIRED, errors.PAIRING_REPLAY):
                    self._fail(who, now)
                raise

    def _redeem(self, now: float, public_key: str, args: dict):
        token = args.get("token")
        if not isinstance(token, (bytes, bytearray)) or len(token) != TOKEN_BYTES:
            raise BridgeError(errors.PAIRING_INVALID, "'token' must be 16 bytes of binary")
        inv = None
        h = token_hash(bytes(token))
        for k, v in self._invites.items():                # constant-time comparison, no early exit
            if hmac.compare_digest(k, h):
                inv = v
        if inv is None:
            raise BridgeError(errors.PAIRING_INVALID, "unknown invite")
        if inv.used_at is not None:
            raise BridgeError(errors.PAIRING_REPLAY, "this invite was already used")
        if now > inv.expires_at:
            raise BridgeError(errors.PAIRING_EXPIRED, "the invite expired", server_time=now)
        if self.registry.trusted(inv.inviter) is None:
            raise BridgeError(errors.PAIRING_INVALID, "the inviting device is no longer trusted")
        if self.vault.in_use():
            raise BridgeError(errors.VAULT_IN_USE, "invites are not available while the vault is in use")
        name = validate_name(args.get("name"))
        platform = validate_platform(args.get("platform", "unknown"))
        dev = self.registry.add(public_key, name, platform, [], inv.inviter, emit=False)
        inv.used_at = now
        inv.redeemed_by = dev.device_id
        return dev
