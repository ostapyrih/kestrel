"""LXMF command channel (offline / LoRa fallback) with the sidecar's own LXMRouter.

A command is accepted only if ALL of these hold:
  1. the LXMF signature was validated by LXMF (``signature_validated is True``),
  2. the signing identity's full public key is in the whitelist,
  3. the payload is a well-formed ``kestrel.cmd`` with a ``ts`` inside the allowed window,
  4. its ``cmd_id`` was not used before (journal).
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import time
from collections import defaultdict, deque

from . import codec, errors
from .codec import LXMF_TYPE_CMD, LXMF_TYPE_PUSH, LXMF_TYPE_RESP, PROTOCOL_VERSION
from .config import Config, Limits
from .errors import BridgeError
from .service import CMD_ID_RE, PATHS, Ctx, Service
from .state import State

log = logging.getLogger("kestrel.lxmf")

# LXMF.FIELD_CUSTOM_TYPE / FIELD_CUSTOM_DATA (LXMF/LXMF.py); duplicated so that validation
# can be unit-tested without importing LXMF.
FIELD_CUSTOM_TYPE = 0xFB
FIELD_CUSTOM_DATA = 0xFC


class CommandRejected(BridgeError):
    """Raised by validate_command. ``phone`` is set only when the sender is authenticated
    (valid signature + whitelisted key); only then may the bridge answer."""

    def __init__(self, code: str, message: str = "", phone: str | None = None, cmd_id: str | None = None):
        super().__init__(code, message)
        self.phone = phone
        self.cmd_id = cmd_id


def _as_bytes(v) -> bytes | None:
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    if isinstance(v, str):
        return v.encode()
    return None


def validate_command(lxm, *, whitelist, recall, state: State, now: float, limits: Limits) -> tuple[str, dict]:
    """Authenticate and parse an inbound LXMF message. Returns (phone_pubkey_hex, payload).

    ``recall(source_hash) -> public key bytes | None``. On success the cmd_id is reserved in the journal.
    """
    if getattr(lxm, "signature_validated", False) is not True:
        raise CommandRejected(errors.UNAUTHORIZED, "signature not validated")
    pub = recall(lxm.source_hash)
    phone = pub.hex() if pub else None
    if phone is None or phone not in whitelist:
        raise CommandRejected(errors.UNAUTHORIZED, "sender key not whitelisted")
    fields = lxm.fields or {}
    if _as_bytes(fields.get(FIELD_CUSTOM_TYPE)) != LXMF_TYPE_CMD:
        raise CommandRejected("not_command", "not a kestrel command", phone=phone)
    data = fields.get(FIELD_CUSTOM_DATA)
    try:
        payload = codec.unpack(data, limits.max_request_bytes)
    except BridgeError as e:
        raise CommandRejected(e.code, e.message, phone=phone) from None
    if not isinstance(payload, dict):
        raise CommandRejected(errors.BAD_REQUEST, "payload must be a map", phone=phone)
    cmd_id = payload.get("cmd_id")
    if not isinstance(cmd_id, str) or not CMD_ID_RE.match(cmd_id):
        raise CommandRejected(errors.BAD_REQUEST, "invalid cmd_id", phone=phone)
    if payload.get("v") != PROTOCOL_VERSION:
        raise CommandRejected(errors.PROTOCOL_MISMATCH, "unsupported protocol version", phone=phone, cmd_id=cmd_id)
    ts = payload.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        raise CommandRejected(errors.BAD_REQUEST, "ts is required", phone=phone, cmd_id=cmd_id)
    if abs(now - ts) > limits.lxmf_ts_window:
        raise CommandRejected(errors.TS_OUT_OF_WINDOW, "ts outside the accepted window", phone=phone, cmd_id=cmd_id)
    if payload.get("path") not in PATHS:
        raise CommandRejected(errors.UNKNOWN_PATH, "unknown path", phone=phone, cmd_id=cmd_id)
    if not isinstance(payload.get("args", {}), dict):
        raise CommandRejected(errors.BAD_REQUEST, "args must be a map", phone=phone, cmd_id=cmd_id)
    if not state.journal_reserve(phone, cmd_id, float(ts)):
        raise CommandRejected(errors.REPLAY, "cmd_id was already used", phone=phone, cmd_id=cmd_id)
    return phone, payload


class LxmfCommands:
    """Owns the LXMRouter of S. Imports RNS/LXMF lazily so the pure helpers stay importable without them."""

    def __init__(self, cfg: Config, identity, service: Service, state: State, loop: asyncio.AbstractEventLoop):
        import LXMF
        import RNS
        from .rns_setup import require_stamping_applied
        require_stamping_applied()   # the LXMRouter creates destinations: stamping policy must be set first
        self._LXMF, self._RNS = LXMF, RNS
        self.cfg, self.service, self.state, self.loop = cfg, service, state, loop
        self.whitelist = frozenset(cfg.whitelist)
        self.router = LXMF.LXMRouter(identity=identity, storagepath=cfg.rns.lxmf_storage)
        self.local = self.router.register_delivery_identity(identity, display_name="Kestrel Bridge")
        self.router.register_delivery_callback(self._on_message)
        if cfg.push.propagation_node:
            self.router.set_outbound_propagation_node(bytes.fromhex(cfg.push.propagation_node))
        self._dests: dict[str, object] = {}
        self._replay_replies: dict[str, deque] = defaultdict(deque)
        self._seed_whitelist()
        if cfg.rns.announce_lxmf:
            self.router.announce(self.local.hash)

    def _seed_whitelist(self) -> None:
        """Make whitelisted phones known to RNS so their LXMF signatures validate without an announce."""
        RNS = self._RNS
        for phone in self.whitelist:
            ident = RNS.Identity(create_keys=False)
            ident.load_public_key(bytes.fromhex(phone))
            dh = RNS.Destination.hash(ident, "lxmf", "delivery")
            RNS.Identity.remember(RNS.Identity.truncated_hash(b"kestrel-seed" + dh), dh, ident.get_public_key())

    def _recall(self, source_hash: bytes):
        ident = self._RNS.Identity.recall(source_hash)
        return ident.get_public_key() if ident else None

    # ---- inbound ---------------------------------------------------------------------------------------
    def _on_message(self, lxm) -> None:
        try:
            phone, payload = validate_command(lxm, whitelist=self.whitelist, recall=self._recall, state=self.state,
                                              now=time.time(), limits=self.cfg.limits)
        except CommandRejected as e:
            log.warning("LXMF command rejected: %s", e.code)
            if e.phone and e.cmd_id and self._may_reply(e):
                self._reply(e.phone, {"v": PROTOCOL_VERSION, "cmd_id": e.cmd_id, **self._rejection_body(e)})
            return
        ctx = Ctx(phone=phone, transport="lxmf", journal_reserved=True)
        fut = asyncio.run_coroutine_threadsafe(
            self.service.dispatch(payload["path"], payload.get("args", {}), ctx), self.loop)
        try:
            resp = fut.result(timeout=self.cfg.limits.rpc_timeout)
        except (concurrent.futures.TimeoutError, TimeoutError):
            fut.cancel()
            resp = codec.err(errors.UPSTREAM_UNAVAILABLE, "request timed out")
        if not resp.get("ok") and resp["error"]["code"] in errors.RETRYABLE:
            self.state.journal_release(phone, payload["cmd_id"])
        resp = codec.clamp_response(resp, self.cfg.limits.lxmf_max_response_bytes)
        self._reply(phone, {"v": PROTOCOL_VERSION, "cmd_id": payload["cmd_id"], **resp})

    def _rejection_body(self, e: CommandRejected) -> dict:
        body = e.to_wire()
        if e.code == errors.REPLAY and e.phone and e.cmd_id:
            cached = self.state.journal_get(e.phone, e.cmd_id)
            if cached:
                try:
                    body["error"]["details"] = {"cached": codec.unpack(cached)}
                except BridgeError:
                    pass
        return body

    def _may_reply(self, e: CommandRejected) -> bool:
        """Never answer window/replay probes unboundedly (a replayed signed message must not be an
        amplifier towards a LoRa phone). Replay replies are budgeted per phone."""
        if e.code == errors.TS_OUT_OF_WINDOW or e.code == "not_command":
            return False
        if e.code == errors.REPLAY:
            q = self._replay_replies[e.phone]
            now = time.time()
            while q and now - q[0] > 3600:
                q.popleft()
            if len(q) >= 5:
                return False
            q.append(now)
        return True

    # ---- outbound (responses and offline push) ----------------------------------------------------------------
    def _destination(self, phone: str):
        d = self._dests.get(phone)
        if d is None:
            RNS = self._RNS
            ident = RNS.Identity(create_keys=False)
            ident.load_public_key(bytes.fromhex(phone))
            d = RNS.Destination(ident, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            self._dests[phone] = d
        return d

    def _send(self, phone: str, ftype: bytes, payload: bytes, method=None, fallback: bool = True) -> None:
        LXMF = self._LXMF
        lxm = LXMF.LXMessage(
            self._destination(phone), self.local, "", title="",
            fields={FIELD_CUSTOM_TYPE: ftype, FIELD_CUSTOM_DATA: payload},
            desired_method=method or LXMF.LXMessage.OPPORTUNISTIC,  # auto-upgraded to DIRECT when too big
        )
        if fallback and self.cfg.push.propagation_node:
            lxm.register_failed_callback(lambda m: self._propagate(phone, ftype, payload))
        self.router.handle_outbound(lxm)

    def _propagate(self, phone: str, ftype: bytes, payload: bytes) -> None:
        log.info("direct LXMF delivery failed, falling back to the propagation node")
        self._send(phone, ftype, payload, method=self._LXMF.LXMessage.PROPAGATED, fallback=False)

    def _reply(self, phone: str, body: dict) -> None:
        try:
            self._send(phone, LXMF_TYPE_RESP, codec.pack(body))
        except Exception:
            log.exception("could not send LXMF response")

    def push(self, phone: str, wire: bytes) -> None:
        """Offline push: ``wire`` is an already packed push envelope."""
        self._send(phone, LXMF_TYPE_PUSH, wire)
