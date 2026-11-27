"""Handlers for /devices/* and /vault/* (mixed into Service). All of them need an RNS Link."""
from __future__ import annotations

from . import codec, errors
from .devices import (pairing_sign_message, parse_pairing_payload,
                      validate_name, validate_roles, verify_signature)
from .errors import BridgeError
from .vault import HEX32_RE

REASON_MAX = 64


def _device_id(args: dict, key: str = "device_id", default: str | None = None) -> str:
    v = args.get(key, default)
    if not isinstance(v, str) or not HEX32_RE.match(v):
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be a 32-char hex device id")
    return v


class DeviceMixin:
    """Expects: cfg, state, registry, vault, push, online, _clock, rate_ok(), _publish()."""

    # ---- routing -----------------------------------------------------------------------------
    def _device_or_vault(self, path: str, args: dict, ctx) -> dict:
        admin = {"/devices/approve", "/devices/rename", "/devices/set_role", "/devices/revoke",
                 "/devices/invite"}
        if path in admin and not self.rate_ok("device_admin", ctx.device_id,
                                              self.cfg.limits.device_admin_rate_per_minute):
            raise BridgeError(errors.RATE_LIMITED, "too many device administration requests", retry_after=60)
        if path == "/vault/put" and not self.rate_ok("vault_put", ctx.device_id,
                                                     self.cfg.limits.vault_put_rate_per_minute):
            raise BridgeError(errors.RATE_LIMITED, "too many vault uploads", retry_after=60)
        handler = {
            "/devices/list": self._devices_list, "/devices/approve": self._devices_approve,
            "/devices/rename": self._devices_rename, "/devices/set_role": self._devices_set_role,
            "/devices/revoke": self._devices_revoke,
            "/devices/invite": self._devices_invite, "/devices/redeem": self._devices_redeem_trusted,
            "/vault/put": self._vault_put, "/vault/list": self._vault_list, "/vault/get": self._vault_get,
            "/vault/key": self._vault_key, "/vault/set_keys": self._vault_set_keys,
        }[path]
        return handler(args, ctx)

    # ---- registry events -> push -------------------------------------------------------------
    def _on_device_event(self, event: str, device) -> None:
        if event == "added":
            self._publish("device_added", {"device": device.to_wire(), "approved_by": device.added_by})
        elif event == "updated":
            self._publish("device_updated", {"device": device.to_wire()})
        elif event == "revoked":
            if self.push is not None:
                self.push.drop_device(device.device_id)      # the revoked device gets nothing more
            self._publish("device_revoked", {"device_id": device.device_id, "revoked_at": device.revoked_at,
                                             "key_epoch": self.vault.epoch()})

    # ---- /devices/* --------------------------------------------------------------------------
    def _wire_device(self, d) -> dict:
        w = d.to_wire()
        w["online"] = bool(self.online(d.device_id)) and not d.revoked
        return w

    def _devices_list(self, args: dict, ctx) -> dict:
        include = args.get("include_revoked", True)
        if not isinstance(include, bool):
            raise BridgeError(errors.BAD_REQUEST, "'include_revoked' must be a boolean")
        return {"devices": [self._wire_device(d) for d in self.registry.all(include)],
                "key_epoch": self.vault.epoch()}

    def _devices_approve(self, args: dict, ctx) -> dict:
        approver = self.registry.trusted(ctx.device_id)
        if approver is None:
            raise BridgeError(errors.DEVICE_REVOKED, "the approving device is not trusted")
        payload = args.get("payload")
        p = parse_pairing_payload(payload)
        now = self._clock()
        if abs(now - p["ts"]) > self.cfg.limits.pairing_window:
            raise BridgeError(errors.PAIRING_EXPIRED, "the pairing QR code expired (or the clocks differ)",
                              server_time=now, window=self.cfg.limits.pairing_window)
        if not verify_signature(approver.public_key, args.get("signature"),
                                pairing_sign_message(payload, approver.device_id)):
            raise BridgeError(errors.BAD_SIGNATURE, "approval signature is invalid")
        name = validate_name(args["name"]) if args.get("name") is not None else p["name"]
        roles = validate_roles(args.get("roles", []))
        wrapped = self.vault.check_approve_key(args)
        try:
            with self.state.transaction():
                if self.state.execute("INSERT OR IGNORE INTO pair_nonces(nonce, used_at, device_id) VALUES(?,?,?)",
                                      (p["nonce"], now, approver.device_id)) != 1:
                    raise BridgeError(errors.PAIRING_REPLAY, "this pairing QR code was already used")
                dev = self.registry.add(p["pubkey"], name, p["platform"], roles, approver.device_id, emit=False)
                if wrapped is not None:
                    self.vault.store_device_key(dev.device_id, wrapped)
        except BaseException:
            self.registry.load()      # the cache must not keep a change that was rolled back
            raise
        self.registry.emit("added", dev)
        return {"device": self._wire_device(dev)}

    def _devices_invite(self, args: dict, ctx) -> dict:
        if self.registry.trusted(ctx.device_id) is None:
            raise BridgeError(errors.DEVICE_REVOKED, "the inviting device is not trusted")
        return self.invites.create(ctx.device_id, args)

    def _devices_redeem_trusted(self, args: dict, ctx) -> dict:
        raise BridgeError(errors.DEVICE_EXISTS, "this device is already paired", device_id=ctx.device_id)

    async def redeem_unknown(self, who: str, public_key: str, args) -> dict:
        """``/devices/redeem`` from a Link identified with an unknown key (the only path such a Link may call).
        Returns a wire response; on success the device exists and ``device_added`` was pushed."""
        try:
            if args is None:
                args = {}
            if not isinstance(args, dict):
                raise BridgeError(errors.BAD_REQUEST, "request must be a map")
            dev = self.invites.redeem(who, public_key, args)
            self.registry.emit("added", dev)
            return codec.ok({"device": self._wire_device(dev)})
        except BridgeError as e:
            return e.to_wire()

    def _devices_rename(self, args: dict, ctx) -> dict:
        did = _device_id(args, default=ctx.device_id)
        dev = self.registry.update(did, name=validate_name(args.get("name")))
        return {"device": self._wire_device(dev)}

    def _devices_set_role(self, args: dict, ctx) -> dict:
        did = _device_id(args)
        role, enabled = args.get("role"), args.get("enabled")
        if not isinstance(enabled, bool):
            raise BridgeError(errors.BAD_REQUEST, "'enabled' must be a boolean")
        validate_roles([role])
        cur = self.registry.get(did)
        if cur is None:
            raise BridgeError(errors.DEVICE_NOT_FOUND, "unknown device", device_id=did)
        roles = set(cur.roles)
        roles.add(role) if enabled else roles.discard(role)
        dev = self.registry.update(did, roles=sorted(roles))
        return {"device": self._wire_device(dev)}

    def _devices_revoke(self, args: dict, ctx) -> dict:
        did = _device_id(args)
        reason = args.get("reason")
        if reason is not None and (not isinstance(reason, str) or len(reason.encode("utf-8")) > REASON_MAX):
            raise BridgeError(errors.BAD_REQUEST, f"'reason' must be a string of at most {REASON_MAX} bytes")
        target = self.registry.get(did)
        if target is None:
            raise BridgeError(errors.DEVICE_NOT_FOUND, "unknown device", device_id=did)
        if target.revoked:
            raise BridgeError(errors.DEVICE_REVOKED, "device is already revoked", device_id=did)
        remaining = {d.device_id for d in self.registry.trusted_devices() if d.device_id != did}
        if not remaining:
            raise BridgeError(errors.LAST_DEVICE, "the last trusted device cannot be revoked")
        wrapped = self.vault.validate_revoke_keys(args, remaining)
        try:
            with self.state.transaction():
                dev = self.registry.revoke(did, ctx.device_id, reason, emit=False)
                epoch = self.vault.apply_revocation(did, wrapped)
        except BaseException:
            self.registry.load()      # the cache must not keep a change that was rolled back
            raise
        self.registry.emit("revoked", dev)
        return {"device": self._wire_device(dev), "key_epoch": epoch}

    # ---- /vault/* ----------------------------------------------------------------------------
    def _vault_put(self, args: dict, ctx) -> dict:
        meta = self.vault.put(ctx.device_id, args)
        if not meta["duplicate"]:
            self._publish("vault.blob", {k: meta[k] for k in ("blob_id", "device_id", "seq", "key_epoch", "size",
                                                              "vcursor")}, skip_device=ctx.device_id)
        return meta

    def _vault_list(self, args: dict, ctx) -> dict:
        return self.vault.list(args, self.cfg.limits.page_max)

    def _vault_get(self, args: dict, ctx) -> dict:
        return self.vault.get(args, self.cfg.limits.max_response_bytes)

    def _vault_key(self, args: dict, ctx) -> dict:
        return self.vault.key_of(ctx.device_id)

    def _vault_set_keys(self, args: dict, ctx) -> dict:
        return self.vault.set_keys(args, {d.device_id for d in self.registry.trusted_devices()})
