"""LXMF command channel (offline / LoRa fallback) with the sidecar's own LXMRouter.

A command is accepted only if ALL of these hold:
  1. the LXMF signature was validated by LXMF (``signature_validated is True``),
  2. the signing identity's full public key belongs to a trusted (registered, not revoked) device,
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
from .codec import LXMF_TYPE_CMD, LXMF_TYPE_PUSH, LXMF_TYPE_RESP, MAX_PROTOCOL_VERSION, MIN_PROTOCOL_VERSION, PROTOCOL_VERSION
from .config import Config, Limits
from .errors import BridgeError
from .service import CMD_ID_RE, LINK_ONLY, PATHS, Ctx, Service
from .state import State

log = logging.getLogger("kestrel.lxmf")

# LXMF.FIELD_CUSTOM_TYPE / FIELD_CUSTOM_DATA (LXMF/LXMF.py); duplicated so that validation
# can be unit-tested without importing LXMF.
FIELD_CUSTOM_TYPE = 0xFB
FIELD_CUSTOM_DATA = 0xFC


class CommandRejected(BridgeError):
    """Raised by validate_command. ``device_id`` is set only when the sender is authenticated
    (valid signature + trusted device key); only then may the bridge answer."""

    def __init__(self, code: str, message: str = "", device_id: str | None = None, cmd_id: str | None = None,
                 **details):
        super().__init__(code, message, **details)
        self.device_id = device_id
        self.cmd_id = cmd_id


def _as_bytes(v) -> bytes | None:
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    if isinstance(v, str):
        return v.encode()
    return None


def validate_command(lxm, *, registry, recall, state: State, now: float, limits: Limits) -> tuple[str, dict]:
    """Authenticate and parse an inbound LXMF message. Returns (device_id, payload).

    ``recall(source_hash) -> public key bytes | None``. On success the cmd_id is reserved in the journal.
    """
    if getattr(lxm, "signature_validated", False) is not True:
        raise CommandRejected(errors.UNAUTHORIZED, "signature not validated")
    pub = recall(lxm.source_hash)
    dev = registry.trusted_by_pubkey(pub.hex()) if pub else None
    if dev is None:
        raise CommandRejected(errors.UNAUTHORIZED, "sender is not a trusted device")
    phone = dev.device_id
    fields = lxm.fields or {}
    if _as_bytes(fields.get(FIELD_CUSTOM_TYPE)) != LXMF_TYPE_CMD:
        raise CommandRejected("not_command", "not a kestrel command", device_id=phone)
    data = fields.get(FIELD_CUSTOM_DATA)
    try:
        payload = codec.unpack(data, limits.max_request_bytes)
    except BridgeError as e:
        raise CommandRejected(e.code, e.message, device_id=phone) from None
    if not isinstance(payload, dict):
        raise CommandRejected(errors.BAD_REQUEST, "payload must be a map", device_id=phone)
    cmd_id = payload.get("cmd_id")
    if not isinstance(cmd_id, str) or not CMD_ID_RE.match(cmd_id):
        raise CommandRejected(errors.BAD_REQUEST, "invalid cmd_id", device_id=phone)
    v = payload.get("v")
    if isinstance(v, bool) or not isinstance(v, int) or not MIN_PROTOCOL_VERSION <= v <= MAX_PROTOCOL_VERSION:
        raise CommandRejected(errors.PROTOCOL_MISMATCH, "unsupported protocol version", device_id=phone, cmd_id=cmd_id,
                              server_version=PROTOCOL_VERSION, client_version=v if isinstance(v, int) else None,
                              min_version=MIN_PROTOCOL_VERSION, max_version=MAX_PROTOCOL_VERSION)
    ts = payload.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        raise CommandRejected(errors.BAD_REQUEST, "ts is required", device_id=phone, cmd_id=cmd_id)
    if abs(now - ts) > limits.lxmf_ts_window:
        raise CommandRejected(errors.TS_OUT_OF_WINDOW, "ts outside the accepted window", device_id=phone, cmd_id=cmd_id)
    if payload.get("path") not in PATHS or payload.get("path") in LINK_ONLY:
        raise CommandRejected(errors.UNKNOWN_PATH if payload.get("path") not in PATHS else errors.UNSUPPORTED_TRANSPORT,
                              "unknown path or a path that needs an RNS Link", device_id=phone, cmd_id=cmd_id)
    if not isinstance(payload.get("args", {}), dict):
        raise CommandRejected(errors.BAD_REQUEST, "args must be a map", device_id=phone, cmd_id=cmd_id)
    if not state.journal_reserve(phone, cmd_id, float(ts)):
        raise CommandRejected(errors.REPLAY, "cmd_id was already used", device_id=phone, cmd_id=cmd_id)
    return phone, payload


class LxmfCommands:
    """Owns the LXMRouter of S. Imports RNS/LXMF lazily so the pure helpers stay importable without them."""

    def __init__(self, cfg: Config, identity, service: Service, state: State, loop: asyncio.AbstractEventLoop):
        import LXMF
        import RNS
        self._LXMF, self._RNS = LXMF, RNS
        self.cfg, self.service, self.state, self.loop = cfg, service, state, loop
        self.registry = service.registry
        self.router = LXMF.LXMRouter(identity=identity, storagepath=cfg.rns.lxmf_storage)
        self.local = self.router.register_delivery_identity(identity, display_name="Kestrel Bridge")
        self.router.register_delivery_callback(self._on_message)
        if cfg.push.propagation_node:
            self.router.set_outbound_propagation_node(bytes.fromhex(cfg.push.propagation_node))
        self._dests: dict[str, object] = {}
        self._replay_replies: dict[str, deque] = defaultdict(deque)
        self.seed_devices()
        self.registry.subscribe(lambda event, dev: self.seed_devices() if event == "added" else None)
        if cfg.rns.announce_lxmf:
            self.router.announce(self.local.hash)

    def seed_devices(self) -> None:
        """Make trusted devices known to RNS so their LXMF signatures validate without an announce."""
        RNS = self._RNS
        for dev in self.registry.trusted_devices():
            ident = RNS.Identity(create_keys=False)
            ident.load_public_key(bytes.fromhex(dev.public_key))
            dh = RNS.Destination.hash(ident, "lxmf", "delivery")
            RNS.Identity.remember(RNS.Identity.truncated_hash(b"kestrel-seed" + dh), dh, ident.get_public_key())

    def _recall(self, source_hash: bytes):
        ident = self._RNS.Identity.recall(source_hash)
        return ident.get_public_key() if ident else None

    # ---- inbound ---------------------------------------------------------------------------------------
    def _on_message(self, lxm) -> None:
        try:
            phone, payload = validate_command(lxm, registry=self.registry, recall=self._recall, state=self.state,
                                              now=time.time(), limits=self.cfg.limits)
        except CommandRejected as e:
            log.warning("LXMF command rejected: %s", e.code)
            if e.device_id and e.cmd_id and self._may_reply(e):
                self._reply(e.device_id, {"v": PROTOCOL_VERSION, "cmd_id": e.cmd_id, **self._rejection_body(e)})
            return
        ctx = Ctx(device_id=phone, transport="lxmf", journal_reserved=True)
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
        if e.code == errors.REPLAY and e.device_id and e.cmd_id:
            cached = self.state.journal_get(e.device_id, e.cmd_id)
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
            q = self._replay_replies[e.device_id]
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
            dev = self.registry.get(phone)
            if dev is None:
                raise KeyError("unknown device")
            ident = RNS.Identity(create_keys=False)
            ident.load_public_key(bytes.fromhex(dev.public_key))
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
