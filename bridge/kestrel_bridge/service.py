"""Transport-independent command handlers (shared by the RNS Link RPC and the LXMF fallback)."""
from __future__ import annotations

import asyncio
import logging
import re
import time
from collections import OrderedDict, defaultdict, deque
from dataclasses import dataclass

from . import __version__, codec, errors
from .codec import MAX_PROTOCOL_VERSION, MIN_PROTOCOL_VERSION, PROTOCOL_VERSION
from .config import Config
from .devices import DeviceRegistry
from .errors import BridgeError
from .meshchatx_client import MeshChatXClient
from .push import PushHub
from .service_devices import DeviceMixin
from .state import State
from .vault import Vault

log = logging.getLogger("kestrel.service")

MUTATING = frozenset({"/send_lxmf", "/send_rrc"})
PATHS = ("/hello", "/sync_chats", "/get_messages", "/list_rooms", "/get_room_messages",
         "/send_lxmf", "/send_rrc", "/subscribe", "/mark_read",
         "/devices/list", "/devices/approve", "/devices/rename", "/devices/set_role", "/devices/revoke",
         "/vault/put", "/vault/list", "/vault/get", "/vault/key", "/vault/set_keys")
# Paths that only exist on the Link transport (binary payloads, interactive, or too chatty for LoRa).
LINK_ONLY = frozenset({"/subscribe", "/devices/list", "/devices/approve", "/devices/rename", "/devices/set_role",
                       "/devices/revoke", "/vault/put", "/vault/list", "/vault/get", "/vault/key", "/vault/set_keys"})
CMD_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
HEX32_RE = re.compile(r"^[0-9a-f]{32}$")
METHODS = (None, "direct", "opportunistic", "propagated")
UPSTREAM_MAX_COUNT = 1000
PREVIEW_BYTES = 80


@dataclass
class Ctx:
    device_id: str                   # identity hash of the calling device, 32 hex
    transport: str                   # "link" or "lxmf"
    journal_reserved: bool = False   # the LXMF layer already claimed the cmd_id
    subscribe: object = None         # link only: callable(topics, hint) -> dict
    profile: str | None = None       # link only: effective push profile


def _hex32(args: dict, key: str) -> str:
    v = args.get(key)
    if not isinstance(v, str) or not HEX32_RE.match(v.lower()):
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be a 32-char hex hash")
    return v.lower()


def _opt_int(args: dict, key: str, minimum: int = 0) -> int | None:
    v = args.get(key)
    if v is None:
        return None
    if isinstance(v, bool) or not isinstance(v, int) or v < minimum:
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be an integer >= {minimum}")
    return v


def _limit(args: dict, cfg: Config, default: int = 50) -> int:
    v = _opt_int(args, "limit", 1)
    return min(v if v is not None else default, cfg.limits.page_max)


def _text(args: dict, key: str, max_bytes: int) -> str:
    v = args.get(key)
    if not isinstance(v, str) or not v.strip():
        raise BridgeError(errors.BAD_REQUEST, f"'{key}' must be a non-empty string")
    if len(v.encode("utf-8")) > max_bytes:
        raise BridgeError(errors.TOO_LARGE, f"'{key}' exceeds {max_bytes} bytes")
    return v


def _has_attachments(fields) -> bool:
    return isinstance(fields, dict) and any(k in fields for k in ("image", "audio", "file_attachments"))


def map_message(m: dict, origin: tuple[str, str] | None = None) -> dict:
    """``origin`` = (device_id, cmd_id) when the bridge sent this (outgoing) message on behalf of a device.
    ``origin_device`` is null for incoming messages and for messages sent from the MeshChatX UI itself."""
    incoming = bool(m["is_incoming"])
    return {
        "id": m["id"], "hash": m["hash"], "incoming": incoming, "state": m["state"],
        "method": m.get("method"), "title": m.get("title") or "", "text": m.get("content") or "",
        "ts": m["timestamp"], "attachments": _has_attachments(m.get("fields")),
        "origin_device": origin[0] if origin and not incoming else None,
        "cmd_id": origin[1] if origin and not incoming else None,
    }


def map_rrc_message(m: dict) -> dict:
    return {"seq": m.get("seq"), "kind": m.get("kind"), "nick": m.get("nick") or "", "text": m.get("text") or "",
            "ts": m.get("ts"), "mention": bool(m.get("mention")), "src": m.get("src")}


async def fetch_after(fetch, after_id: int, page: int, max_pages: int = 10) -> tuple[list[dict], bool]:
    """All messages with id > after_id, working around the MeshChatX paging quirk.

    ``fetch(order, after_id, count)`` returns one raw page, newest first. With order="asc" the page
    holds the NEWEST ``count`` rows with id > after_id (a gap may remain below it); with order="desc"
    the rows have id < after_id. Returns (messages ascending by id, gap) where gap=True means the
    page cap was hit and older rows in the middle are still missing.
    """
    first = await fetch("asc", after_id, page)
    items = {m["id"]: m for m in first}
    last = first
    gap = False
    if len(first) >= page:
        for i in range(max_pages):
            oldest = min(m["id"] for m in last)
            older = await fetch("desc", oldest, page)
            fresh = [m for m in older if m["id"] > after_id]
            for m in fresh:
                items[m["id"]] = m
            if len(older) < page or len(fresh) < len(older):
                break
            last = older
        else:
            gap = True
    return sorted(items.values(), key=lambda m: m["id"]), gap


class Service(DeviceMixin):
    def __init__(self, cfg: Config, client: MeshChatXClient, state: State, push: PushHub | None = None,
                 clock=time.time, registry: DeviceRegistry | None = None):
        self.cfg = cfg
        self.client = client
        self.state = state
        self.push = push
        self._clock = clock
        self._refresh_lock = asyncio.Lock()
        self._last_refresh = 0.0
        self._lxmf_cache: dict[str, dict] = {}
        self._rrc_cache: dict[str, dict] = {}
        self._rates: dict[tuple[str, str], deque] = defaultdict(deque)
        self._inflight: dict[str, list[asyncio.Future]] = defaultdict(list)
        self._read_by: dict[str, str] = {}
        self.registry = registry or DeviceRegistry(state, cfg.limits.max_devices, clock)
        self.vault = Vault(state, cfg.limits, clock)
        self.online = lambda device_id: False     # set by the RPC layer: does the device have a live Link?
        self.registry.subscribe(self._on_device_event)
        self._last_state: OrderedDict[str, str] = OrderedDict()
        self.compat_ok = False

    # ---- dispatch ---------------------------------------------------------------------
    async def dispatch(self, path: str, args, ctx: Ctx) -> dict:
        """Run one command; always returns a wire response ({"ok":...})."""
        try:
            return await self._dispatch(path, args, ctx)
        except BridgeError as e:
            return e.to_wire()
        except Exception:
            log.exception("handler %s failed", path)
            return codec.err(errors.INTERNAL, "internal error")

    async def _dispatch(self, path: str, args, ctx: Ctx) -> dict:
        if path not in PATHS:
            raise BridgeError(errors.UNKNOWN_PATH, "unknown request path")
        if self.registry.trusted(ctx.device_id) is None:
            if self.registry.get(ctx.device_id) is not None:
                raise BridgeError(errors.DEVICE_REVOKED, "this device was revoked")
            raise BridgeError(errors.UNAUTHORIZED, "unknown device")
        self.registry.touch_seen(ctx.device_id)
        if args is None:
            args = {}
        if not isinstance(args, dict):
            raise BridgeError(errors.BAD_REQUEST, "request must be a map")
        if path == "/hello":
            return codec.ok(self._hello(args, ctx))
        if path in LINK_ONLY and ctx.transport != "link":
            raise BridgeError(errors.UNSUPPORTED_TRANSPORT, f"{path} needs an RNS Link")
        if path == "/subscribe":
            if ctx.subscribe is None:
                raise BridgeError(errors.UNSUPPORTED_TRANSPORT, "/subscribe needs an RNS Link")
            return codec.ok(self._subscribe(args, ctx))
        if path.startswith("/devices/") or path.startswith("/vault/"):
            return codec.ok(self._device_or_vault(path, args, ctx))
        if not self.compat_ok:
            raise BridgeError(errors.UPSTREAM_INCOMPATIBLE, "MeshChatX version/API is not supported by this bridge")
        if path in MUTATING:
            return await self._mutating(path, args, ctx)
        if ctx.transport == "lxmf" and not ctx.journal_reserved:
            raise BridgeError(errors.BAD_REQUEST, "LXMF commands must pass through the command validator")
        if path == "/mark_read":
            return codec.ok(await self._mark_read(args, ctx))
        handler = {"/sync_chats": self._sync_chats, "/get_messages": self._get_messages,
                   "/list_rooms": self._list_rooms, "/get_room_messages": self._get_room_messages}[path]
        return codec.ok(await handler(args))

    def rate_ok(self, bucket: str, device_id: str, limit: int) -> bool:
        """Sliding one-minute window per (bucket, device)."""
        now = self._clock()
        q = self._rates[(bucket, device_id)]
        while q and now - q[0] > 60:
            q.popleft()
        if len(q) >= limit:
            return False
        q.append(now)
        return True

    def _rate_ok(self, device_id: str) -> bool:
        return self.rate_ok("send", device_id, self.cfg.limits.send_rate_per_minute)

    async def _mutating(self, path: str, args: dict, ctx: Ctx) -> dict:
        cmd_id = args.get("cmd_id")
        if not isinstance(cmd_id, str) or not CMD_ID_RE.match(cmd_id):
            raise BridgeError(errors.BAD_REQUEST, "'cmd_id' (8-64 chars A-Za-z0-9_-) is required")
        runner = self._send_lxmf if path == "/send_lxmf" else self._send_rrc
        # validate before reserving so that a malformed request does not burn the cmd_id
        prepared = runner(args, ctx, dry=True)
        if not ctx.journal_reserved:
            ts = args.get("ts")
            ts = float(ts) if isinstance(ts, (int, float)) and not isinstance(ts, bool) else self._clock()
            if not self.state.journal_reserve(ctx.device_id, cmd_id, ts):
                raise self._replay_error(ctx.device_id, cmd_id)
        if not self._rate_ok(ctx.device_id):
            self.state.journal_release(ctx.device_id, cmd_id)
            raise BridgeError(errors.RATE_LIMITED, "too many send commands", retry_after=60)
        try:
            result = await runner(args, ctx, prepared=prepared)
            resp = codec.ok(result)
        except BridgeError as e:
            if e.code in errors.RETRYABLE:
                self.state.journal_release(ctx.device_id, cmd_id)
                raise
            self.state.journal_store(ctx.device_id, cmd_id, codec.pack(e.to_wire()))
            raise
        self.state.journal_store(ctx.device_id, cmd_id, codec.pack(resp))
        return resp

    def _replay_error(self, phone: str, cmd_id: str) -> BridgeError:
        cached = self.state.journal_get(phone, cmd_id)
        details = {}
        if cached:
            try:
                details["cached"] = codec.unpack(cached)
            except BridgeError:
                pass
        return BridgeError(errors.REPLAY, "cmd_id was already used", **details)

    # ---- /hello, /subscribe ----------------------------------------------------------------
    def _hello(self, args: dict, ctx: Ctx) -> dict:
        v = args.get("protocol_version")
        if isinstance(v, bool) or not isinstance(v, int) or not MIN_PROTOCOL_VERSION <= v <= MAX_PROTOCOL_VERSION:
            raise BridgeError(errors.PROTOCOL_MISMATCH, "unsupported protocol_version",
                              server_version=PROTOCOL_VERSION, client_version=v,
                              min_version=MIN_PROTOCOL_VERSION, max_version=MAX_PROTOCOL_VERSION)
        lim = self.cfg.limits
        dev = self.registry.trusted(ctx.device_id)
        return {
            "protocol_version": PROTOCOL_VERSION,
            "min_protocol_version": MIN_PROTOCOL_VERSION,
            "max_protocol_version": MAX_PROTOCOL_VERSION,
            "server": f"kestrel-bridge/{__version__}",
            "time": self._clock(),
            "state_id": self.state.state_id(),
            "cursor": self.state.cursor(),
            "device": dev.to_wire(),
            "capabilities": ["lxmf", "rrc", "push", "lxmf_transport", "devices", "pairing", "read_state",
                             "origin_device", "vault"],
            "compat": {"ok": self.compat_ok, "meshchatx_version": self.client.version,
                       "api_version": self.client.api_version},
            "profile": ctx.profile,
            "vault": {"key_epoch": self.vault.epoch(), "in_use": self.vault.in_use(),
                      "used_bytes": self.vault.usage(ctx.device_id)},
            "limits": {"max_text_bytes": lim.max_text_bytes, "page_max": lim.page_max,
                       "constrained_max_text_bytes": lim.constrained_max_text_bytes,
                       "lxmf_max_response_bytes": lim.lxmf_max_response_bytes,
                       "lxmf_ts_window": lim.lxmf_ts_window, "pairing_window": lim.pairing_window,
                       "max_devices": lim.max_devices, "vault_max_blob_bytes": lim.vault_max_blob_bytes,
                       "vault_device_quota_bytes": lim.vault_device_quota_bytes,
                       "vault_total_quota_bytes": lim.vault_total_quota_bytes,
                       "vault_get_max_ids": lim.vault_get_max_ids},
        }

    def _subscribe(self, args: dict, ctx: Ctx) -> dict:
        topics = args.get("topics", ["lxmf", "rrc", "vault"])
        if not isinstance(topics, list) or not all(t in ("lxmf", "rrc", "vault") for t in topics):
            raise BridgeError(errors.BAD_REQUEST, "'topics' must be a subset of ['lxmf','rrc','vault']")
        hint = args.get("profile", "full")
        if hint not in ("full", "constrained"):
            raise BridgeError(errors.BAD_REQUEST, "'profile' must be 'full' or 'constrained'")
        out = ctx.subscribe(topics, hint)
        out["cursor"] = self.state.cursor()
        return out

    # ---- conversation index -----------------------------------------------------------------
    async def refresh(self, force: bool = False) -> None:
        """Pull the conversation list and RRC hubs from MeshChatX, assigning change cursors."""
        async with self._refresh_lock:
            if not force and self._clock() - self._last_refresh < 1.0:
                return
            convs = await self.client.list_conversations()
            previous, self._lxmf_cache = self._lxmf_cache, {}
            flipped = []
            for c in convs:
                peer = c["destination_hash"].lower()
                self._lxmf_cache[peer] = c
                fp = f"{c['latest_message_created_at']}|{int(bool(c['is_unread']))}|{c.get('failed_messages_count', 0)}"
                self.state.touch_conv(f"lxmf:{peer}", fp)
                old = previous.get(peer)
                if old is not None and old.get("is_unread") and not c.get("is_unread"):
                    flipped.append(peer)
            try:
                hubs = await self.client.rrc_hubs()
            except BridgeError as e:
                if e.code in (errors.UPSTREAM_UNAVAILABLE, errors.UPSTREAM_AUTH):
                    raise
                log.info("RRC not available: %s", e.code)
                hubs = []
            self._rrc_cache = {}
            for h in hubs:
                for room in self._joined_rooms(h):
                    unread = int((h.get("unread_counts") or {}).get(room, 0) or 0)
                    mention = room in (h.get("mention_rooms") or [])
                    key = f"rrc:{h['hub_hash']}:{room}"
                    self._rrc_cache[key] = {"hub": h["hub_hash"], "hub_name": self._hub_name(h), "room": room,
                                            "unread": unread, "mention": mention}
                    self.state.touch_conv(key, f"{unread}|{int(mention)}")
            self._last_refresh = self._clock()
            for peer in flipped:     # read in MeshChatX (web UI or another device's /mark_read)
                self._publish("read_state", {"peer": peer, "unread": False, "cursor": self.state.cursor(),
                                             "by_device": self._read_by.pop(peer, None)})

    @staticmethod
    def _joined_rooms(hub: dict) -> list[str]:
        out = []
        for r in hub.get("rooms") or []:
            name = r if isinstance(r, str) else (r.get("name") or r.get("room")) if isinstance(r, dict) else None
            if isinstance(name, str) and name:
                out.append(name)
        return out

    @staticmethod
    def _hub_name(hub: dict) -> str:
        return str(hub.get("custom_name") or hub.get("display_name") or hub.get("name") or hub.get("hub_name")
                   or hub["hub_hash"][:8])

    async def _sync_chats(self, args: dict) -> dict:
        cursor = _opt_int(args, "cursor", 0) or 0
        limit = _limit(args, self.cfg, default=self.cfg.limits.page_max)
        client_state = args.get("state_id")
        if client_state is not None and not isinstance(client_state, str):
            raise BridgeError(errors.BAD_REQUEST, "'state_id' must be a string")
        await self.refresh()
        server = self.state.cursor()
        reset = cursor > server or (client_state is not None and client_state != self.state.state_id())
        if reset:
            cursor = 0
        keys, more = self.state.convs_since(cursor, "", limit)
        lxmf, rrc = [], []
        for k in keys:
            if k.startswith("lxmf:"):
                c = self._lxmf_cache.get(k[5:])
                if c is None:
                    continue
                preview, _ = _trunc(c.get("latest_message_preview") or "", PREVIEW_BYTES)
                lxmf.append({"peer": k[5:], "name": c.get("custom_display_name") or c.get("display_name") or "",
                             "last_ts": c.get("latest_message_created_at"), "unread": bool(c.get("is_unread")),
                             "failed": int(c.get("failed_messages_count") or 0), "preview": preview,
                             "last_id": self.state.get_last_id(k)})
            else:
                r = self._rrc_cache.get(k)
                if r is not None:
                    rrc.append(dict(r))
        out_cursor = self.state.conv_cursor(keys[-1]) if more and keys else server
        return {"state_id": self.state.state_id(), "cursor": out_cursor, "reset": reset, "more": more,
                "lxmf": lxmf, "rrc": rrc}

    # ---- /get_messages -------------------------------------------------------------------------
    async def _get_messages(self, args: dict) -> dict:
        peer = _hex32(args, "peer")
        limit = _limit(args, self.cfg)
        before = _opt_int(args, "before_id", 1)
        after = _opt_int(args, "after_id", 0)
        if before is not None and after is not None:
            raise BridgeError(errors.BAD_REQUEST, "use only one of before_id / after_id")
        gap = False
        if after is not None:
            fetch = lambda order, aid, count: self.client.conversation_messages(peer, count, order, aid)  # noqa: E731
            msgs, gap = await fetch_after(fetch, after, UPSTREAM_MAX_COUNT)
            has_more = len(msgs) > limit
            if gap:
                msgs = msgs[-limit:]   # newest rows; the client pages backwards with before_id
            else:
                msgs = msgs[:limit]
        elif before is not None:
            raw = await self.client.conversation_messages(peer, limit, "desc", before)
            msgs = sorted(raw, key=lambda m: m["id"])
            has_more = len(raw) >= limit
        else:
            raw = await self.client.conversation_messages(peer, limit, "asc", None)
            msgs = sorted(raw, key=lambda m: m["id"])
            has_more = len(raw) >= limit
        if msgs:
            self.state.set_last_id(f"lxmf:{peer}", max(m["id"] for m in msgs))
        origins = self.state.outbound_get_many([str(m["hash"]).lower() for m in msgs if not m["is_incoming"]])
        return {"peer": peer, "has_more": has_more, "gap": gap,
                "messages": [map_message(m, origins.get(str(m["hash"]).lower())) for m in msgs]}

    async def _mark_read(self, args: dict, ctx: Ctx) -> dict:
        """Mark a conversation read in MeshChatX (shared with its web UI). Every device (including the
        caller) then gets a ``read_state`` push; the change also shows up in /sync_chats."""
        peer = _hex32(args, "peer")
        if not self.rate_ok("mark_read", ctx.device_id, self.cfg.limits.mark_read_rate_per_minute):
            raise BridgeError(errors.RATE_LIMITED, "too many mark_read requests", retry_after=60)
        await self.client.mark_read(peer)
        self._read_by[peer] = ctx.device_id
        try:
            await self.refresh(force=True)
        finally:
            self._read_by.pop(peer, None)
        return {"peer": peer, "cursor": self.state.cursor()}

    # ---- RRC -------------------------------------------------------------------------------------
    async def _list_rooms(self, args: dict) -> dict:
        hubs = await self.client.rrc_hubs()
        out = []
        for h in hubs:
            counts = h.get("unread_counts") or {}
            mentions = h.get("mention_rooms") or []
            rooms = [{"room": r, "unread": int(counts.get(r, 0) or 0), "mention": r in mentions}
                     for r in self._joined_rooms(h)]
            out.append({"hub": h["hub_hash"], "name": self._hub_name(h), "connected": bool(h.get("connected")),
                        "status": h.get("status_text") or h.get("status") or "", "rooms": rooms})
        return {"hubs": out}

    async def _get_room_messages(self, args: dict) -> dict:
        hub = _hex32(args, "hub")
        room = args.get("room")
        if not isinstance(room, str) or not room or len(room) > 64 or any(ord(c) < 32 for c in room):
            raise BridgeError(errors.BAD_REQUEST, "'room' must be a short printable string")
        limit = _limit(args, self.cfg)
        before = _opt_int(args, "before_seq", 0)
        after = _opt_int(args, "after_seq", 0)
        if before is not None and after is not None:
            raise BridgeError(errors.BAD_REQUEST, "use only one of before_seq / after_seq")
        try:
            gap = False
            if after is not None:
                raw, has_more = await self.client.rrc_room_messages(hub, room, UPSTREAM_MAX_COUNT, None)
                fresh = [m for m in raw if isinstance(m.get("seq"), int) and m["seq"] > after]
                gap = has_more and len(fresh) == len(raw)
                if len(fresh) > limit:
                    fresh, gap = fresh[-limit:], True
                msgs, has_more = fresh, False
            else:
                msgs, has_more = await self.client.rrc_room_messages(hub, room, limit, before)
        finally:
            # reading history makes the room "active" in the desktop UI: undo that side effect
            try:
                await self.client.rrc_active_clear()
            except BridgeError:
                pass
        return {"hub": hub, "room": room, "messages": [map_rrc_message(m) for m in msgs],
                "has_more": has_more, "gap": gap}

    # ---- commands --------------------------------------------------------------------------------
    def _send_lxmf(self, args: dict, ctx: Ctx, dry: bool = False, prepared=None):
        if dry:
            dest = _hex32(args, "to")
            text = _text(args, "text", self.cfg.limits.max_text_bytes)
            method = args.get("delivery_method")
            if method not in METHODS:
                raise BridgeError(errors.BAD_REQUEST, "'delivery_method' must be direct, opportunistic, propagated or null")
            return dest, text, method
        return self._do_send_lxmf(args, ctx, prepared)

    async def _do_send_lxmf(self, args: dict, ctx: Ctx, prepared) -> dict:
        dest, text, method = prepared
        # The MeshChatX WS "message created" event can arrive before the send response: mark the send as
        # in flight so on_event waits for the origin mapping below.
        gate = asyncio.get_running_loop().create_future()
        self._inflight[dest].append(gate)
        try:
            lm = await self.client.send_lxmf(dest, text, method)
            h = str(lm["hash"]).lower()
            st = lm.get("state")
            self.state.pending_put(args["cmd_id"], ctx.device_id, h, dest, st)
            self.state.outbound_put(h, ctx.device_id, args["cmd_id"], dest)
        finally:
            self._inflight[dest].remove(gate)
            if not self._inflight[dest]:
                del self._inflight[dest]
            if not gate.done():
                gate.set_result(None)
        self._last_state[h] = st
        return {"lxmf_hash": h, "state": st, "method": lm.get("method"), "to": dest, "ts": self._clock()}

    def _send_rrc(self, args: dict, ctx: Ctx, dry: bool = False, prepared=None):
        if dry:
            hub = _hex32(args, "hub")
            room = args.get("room")
            if not isinstance(room, str) or not room or len(room) > 64 or any(ord(c) < 32 for c in room):
                raise BridgeError(errors.BAD_REQUEST, "'room' must be a short printable string")
            text = _text(args, "text", self.cfg.limits.max_text_bytes)
            if text.lstrip().startswith("/"):
                # MeshChatX executes text starting with "/" as a hub command as A.
                raise BridgeError(errors.RRC_COMMAND_REJECTED, "RRC text starting with '/' is not allowed")
            return hub, room, text
        return self._do_send_rrc(prepared)

    async def _do_send_rrc(self, prepared) -> dict:
        hub, room, text = prepared
        await self.client.rrc_send(hub, room, text)
        return {"sent": True, "hub": hub, "room": room, "ts": self._clock()}

    # ---- WS events -> push ---------------------------------------------------------------------
    def _publish(self, name: str, data: dict, skip_device: str | None = None) -> None:
        if self.push is not None:
            self.push.publish({"event": name, "data": data}, skip_device=skip_device)

    async def on_event(self, ev: dict) -> None:
        t = ev.get("type")
        if t == "lxmf.delivery":
            m = ev["lxmf_message"]
            if m.get("is_spam"):
                return
            peer = str(m["source_hash"]).lower()
            self.state.touch_conv(f"lxmf:{peer}", f"ws:{m['hash']}", force=True)
            if peer in self._lxmf_cache:     # so that a quick read in MeshChatX is seen as a flip
                self._lxmf_cache[peer] = {**self._lxmf_cache[peer], "is_unread": True}
            self._publish("lxmf.message", {
                "peer": peer, "hash": m["hash"], "incoming": True, "state": m.get("state"),
                "method": m.get("method"), "title": m.get("title") or "", "text": m.get("content") or "",
                "ts": m.get("timestamp"), "name": ev.get("remote_identity_name") or "",
                "attachments": _has_attachments(m.get("fields")), "origin_device": None,
                "cmd_id": None, "cursor": self.state.cursor()})
        elif t == "lxmf_message_created":
            m = ev["lxmf_message"]
            peer = str(m["destination_hash"]).lower()
            gates = [g for g in self._inflight.get(peer, []) if not g.done()]
            if gates:
                await asyncio.wait(gates, timeout=2.0)
            self.state.touch_conv(f"lxmf:{peer}", f"ws:{m['hash']}", force=True)
            origin = self.state.outbound_get_many([str(m["hash"]).lower()]).get(str(m["hash"]).lower())
            self._publish("lxmf.message", {
                "peer": peer, "hash": m["hash"], "incoming": False, "state": m.get("state"),
                "method": m.get("method"), "title": m.get("title") or "", "text": m.get("content") or "",
                "ts": m.get("timestamp"), "attachments": _has_attachments(m.get("fields")),
                "origin_device": origin[0] if origin else None, "cmd_id": origin[1] if origin else None,
                "cursor": self.state.cursor()})
        elif t == "lxmf_message_state_updated":
            m = ev["lxmf_message"]
            h = str(m["hash"]).lower()
            st = m.get("state")
            if self._last_state.get(h) == st:
                return
            self._last_state[h] = st
            self._last_state.move_to_end(h)
            while len(self._last_state) > 2000:
                self._last_state.popitem(last=False)
            pend = self.state.pending_by_hash(h)
            data = {"hash": h, "state": st, "progress": m.get("progress"), "method": m.get("method")}
            if pend:
                data["cmd_id"] = pend["cmd_id"]
            peer = pend["peer"] if pend else str(m.get("destination_hash") or "").lower()
            if len(peer) == 32:      # a state change makes the conversation show up in /sync_chats again
                self.state.touch_conv(f"lxmf:{peer}", f"st:{h}:{st}", force=True)
            self._publish("lxmf.state", data)
            if pend and st:
                self.state.pending_update(h, st)
        elif t == "lxmf_message_deleted":
            h = (ev.get("lxmf_message") or {}).get("hash") or ev.get("hash")
            if h:
                self._publish("lxmf.deleted", {"hash": h})
        elif t == "rrc.message":
            msg = ev.get("message") or {}
            hub, room = ev.get("hub_hash"), ev.get("room") or msg.get("room")
            if not hub or not room:
                return
            self.state.touch_conv(f"rrc:{hub}:{room}", f"ws:{msg.get('seq')}", force=True)
            self._publish("rrc.message", {"hub": hub, "room": room, "seq": msg.get("seq"),
                                          "kind": msg.get("kind"), "nick": msg.get("nick") or "",
                                          "text": msg.get("text") or "", "ts": msg.get("ts"),
                                          "mention": bool(ev.get("mention") or msg.get("mention")),
                                          "src": msg.get("src")})
        elif t == "rrc.change":
            if ev.get("hub_hash"):
                self._publish("rrc.change", {"hub": ev["hub_hash"]})

    async def on_resync(self) -> None:
        """The WS lost events: rebuild the index and tell subscribed phones to resync."""
        try:
            await self.refresh(force=True)
            await self._repoll_pending()
        except BridgeError as e:
            log.warning("resync failed: %s", e.code)
        self._publish("resync", {"cursor": self.state.cursor()})

    async def _repoll_pending(self) -> None:
        by_peer: dict[str, list[dict]] = defaultdict(list)
        for p in self.state.pending_all():
            by_peer[p["peer"]].append(p)
        for peer, items in by_peer.items():
            page = await self.client.conversation_messages(peer, 50, "asc", None)
            known = {str(m["hash"]).lower(): m for m in page}
            for p in items:
                m = known.get(p["lxmf_hash"])
                if m is None or m["state"] == p["state"]:
                    continue
                self._publish("lxmf.state", {"hash": p["lxmf_hash"], "state": m["state"], "cmd_id": p["cmd_id"]})
                self.state.pending_update(p["lxmf_hash"], m["state"])

    async def recheck_compat(self) -> bool:
        try:
            await self.client.check_compat()
            self.compat_ok = True
        except BridgeError as e:
            self.compat_ok = False if e.code == errors.UPSTREAM_INCOMPATIBLE else self.compat_ok
            log.error("MeshChatX compatibility check: %s: %s", e.code, e.message)
        return self.compat_ok


def _trunc(text: str, max_bytes: int):
    from .push import truncate_utf8
    return truncate_utf8(text, max_bytes)

