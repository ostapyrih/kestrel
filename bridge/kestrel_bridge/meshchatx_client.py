"""Authenticated HTTP client for the MeshChatX API.

Rules (see docs/PLAN.md, "Facts from Phase 1a"):
* the only credential is the web password; session = encrypted cookie + CSRF header;
* the CSRF token rotates at login, so it is re-fetched after every login;
* a 401 means the session died (for example the human logged out) -> log in again;
* /auth/logout is NEVER called: it bumps the global session epoch and kills every session;
* login is rate limited server-side -> exponential backoff, never a retry storm.
"""
from __future__ import annotations

import asyncio
import logging
import time
from urllib.parse import quote

import aiohttp

from . import __version__, errors
from .config import MeshChatXConfig
from .errors import BridgeError

log = logging.getLogger("kestrel.meshchatx")
API = "/api/v1"
USER_AGENT = f"kestrel-bridge/{__version__}"


def _need(d, keys: tuple[str, ...], what: str) -> None:
    if not isinstance(d, dict):
        raise BridgeError(errors.UPSTREAM_INCOMPATIBLE, f"{what}: unexpected response shape")
    for k in keys:
        if k not in d:
            raise BridgeError(errors.UPSTREAM_INCOMPATIBLE, f"{what}: response lacks key '{k}'")


def _upstream_text(body) -> str:
    if isinstance(body, dict):
        for k in ("error", "message"):
            v = body.get(k)
            if isinstance(v, str):
                return v[:200]
    return ""


class MeshChatXClient:
    def __init__(self, cfg: MeshChatXConfig, clock=time.monotonic, session: aiohttp.ClientSession | None = None):
        self.cfg = cfg
        self._clock = clock
        self._session = session
        self._csrf: str | None = None
        self._logged_in = False
        self._login_lock = asyncio.Lock()
        self._failures = 0
        self._not_before = 0.0
        self.version: str | None = None
        self.api_version: int | None = None

    # ---- session ---------------------------------------------------------------------
    @property
    def session(self) -> aiohttp.ClientSession:
        if self._session is None:
            self._session = aiohttp.ClientSession(
                cookie_jar=aiohttp.CookieJar(unsafe=True),  # unsafe: allow cookies for IP hosts
                headers={"User-Agent": USER_AGENT},
                timeout=aiohttp.ClientTimeout(total=self.cfg.request_timeout),
            )
        return self._session

    async def close(self) -> None:
        if self._session is not None:
            await self._session.close()
            self._session = None

    def _url(self, path: str) -> str:
        return f"{self.cfg.base_url}{API}{path}"

    # ---- login -------------------------------------------------------------------------
    async def _fetch_csrf(self) -> str:
        async with self.session.get(self._url("/auth/csrf")) as r:
            if r.status != 200:
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"csrf endpoint returned {r.status}")
            body = await r.json(content_type=None)
        _need(body, ("csrf_token",), "/auth/csrf")
        return body["csrf_token"]

    def _fail(self, retry_floor: float = 0.0) -> float:
        self._failures += 1
        delay = min(self.cfg.login_backoff_max, self.cfg.login_backoff_base * 2 ** (self._failures - 1))
        delay = min(self.cfg.login_backoff_max, max(delay, retry_floor))
        self._not_before = self._clock() + delay
        return delay

    async def login(self, force: bool = False) -> None:
        async with self._login_lock:
            if self._logged_in and not force:
                return
            now = self._clock()
            if now < self._not_before:
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "login backoff active",
                                  retry_after=round(self._not_before - now, 1))
            self._logged_in = False
            password = self.cfg.read_password()
            try:
                token = await self._fetch_csrf()
                async with self.session.post(
                    self._url("/auth/login"), json={"password": password}, headers={"X-CSRF-Token": token}
                ) as r:
                    status = r.status
                if status == 401:
                    d = self._fail(retry_floor=60.0)
                    raise BridgeError(errors.UPSTREAM_AUTH, "MeshChatX rejected the password", retry_after=d)
                if status == 429:
                    d = self._fail(retry_floor=60.0)
                    raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "MeshChatX login rate limited", retry_after=d)
                if status != 200:
                    d = self._fail()
                    raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"login returned {status}", retry_after=d)
                self._csrf = await self._fetch_csrf()  # token rotated by the login
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                d = self._fail()
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"cannot reach MeshChatX: {type(e).__name__}",
                                  retry_after=d) from None
            self._failures = 0
            self._not_before = 0.0
            self._logged_in = True
            log.info("logged in to MeshChatX")

    # ---- requests ------------------------------------------------------------------------
    async def request(self, method: str, path: str, *, params=None, json=None, timeout: float | None = None):
        """Authenticated request returning parsed JSON.

        Survives a MeshChatX restart/recreate: while the server is down the call fails with
        UPSTREAM_UNAVAILABLE (no state is lost); afterwards the old cookie is dead, which shows up as
        401 (log in again) or as csrf_invalid (refetch the token; if that is not enough, log in again).
        Each recovery step is tried once per call.
        """
        await self.login()
        relogged = csrf_refreshed = False
        for _ in range(3):
            headers = {}
            if method.upper() not in ("GET", "HEAD", "OPTIONS"):
                headers["X-CSRF-Token"] = self._csrf or ""
            try:
                async with self.session.request(
                    method, self._url(path), params=params, json=json, headers=headers,
                    timeout=aiohttp.ClientTimeout(total=timeout or self.cfg.request_timeout),
                ) as r:
                    status = r.status
                    try:
                        body = await r.json(content_type=None)
                    except Exception:
                        body = None
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"cannot reach MeshChatX: {type(e).__name__}") from None
            if status == 401 and not relogged:
                log.info("MeshChatX session expired, logging in again")
                relogged = True
                self._logged_in = False
                await self.login(force=True)
                continue
            csrf_invalid = status == 403 and isinstance(body, dict) and body.get("code") == "csrf_invalid"
            if csrf_invalid and csrf_refreshed and not relogged:
                # a fresh token did not help: the session itself is gone (server was recreated)
                log.info("MeshChatX still rejects the CSRF token, logging in again")
                relogged = True
                self._logged_in = False
                await self.login(force=True)
                continue
            if csrf_invalid and not csrf_refreshed:
                csrf_refreshed = True
                try:
                    self._csrf = await self._fetch_csrf()
                except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                    raise BridgeError(errors.UPSTREAM_UNAVAILABLE,
                                      f"cannot reach MeshChatX: {type(e).__name__}") from None
                continue
            break
        if status == 401:
            raise BridgeError(errors.UPSTREAM_AUTH, "MeshChatX session rejected after re-login")
        if status == 503 and isinstance(body, dict) and body.get("code") == "starting":
            raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "MeshChatX is starting")
        if status == 429:
            retry = body.get("retry_after") if isinstance(body, dict) else None
            raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "MeshChatX rate limited the request", retry_after=retry)
        if status >= 400:
            raise BridgeError(errors.UPSTREAM_ERROR, _upstream_text(body) or f"HTTP {status}", status=status)
        return body

    # ---- compatibility ---------------------------------------------------------------------
    async def status(self) -> dict:
        try:
            async with self.session.get(self._url("/status")) as r:
                body = await r.json(content_type=None)
                status = r.status
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"cannot reach MeshChatX: {type(e).__name__}") from None
        if status != 200:
            raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"/status returned {status}")
        _need(body, ("version",), "/status")
        return body

    async def wait_ready(self, poll: float = 3.0, timeout: float | None = None) -> dict:
        """Block until /status reports network_ready."""
        deadline = None if timeout is None else self._clock() + timeout
        while True:
            try:
                st = await self.status()
                if st.get("network_ready") is True:
                    return st
            except BridgeError as e:
                log.info("waiting for MeshChatX: %s", e.message)
            if deadline is not None and self._clock() > deadline:
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "MeshChatX did not become ready")
            await asyncio.sleep(poll)

    def _version_ok(self, version) -> bool:
        return isinstance(version, str) and any(version.startswith(p) for p in self.cfg.allowed_versions)

    async def check_compat(self) -> dict:
        """Verify the MeshChatX version (/status) and API version (/app/info). Raises UPSTREAM_INCOMPATIBLE."""
        st = await self.status()
        self.version = st["version"]
        if not self._version_ok(self.version):
            raise BridgeError(errors.UPSTREAM_INCOMPATIBLE,
                              f"MeshChatX version {self.version!r} is not in the allowlist "
                              f"{list(self.cfg.allowed_versions)}")
        info = await self.request("GET", "/app/info")
        _need(info, ("app_info",), "/app/info")
        _need(info["app_info"], ("api_version",), "/app/info.app_info")
        self.api_version = info["app_info"]["api_version"]
        if self.api_version not in self.cfg.allowed_api_versions:
            raise BridgeError(errors.UPSTREAM_INCOMPATIBLE,
                              f"MeshChatX api_version {self.api_version!r} is not supported")
        return {"version": self.version, "api_version": self.api_version}

    # ---- LXMF ----------------------------------------------------------------------------------
    async def list_conversations(self, limit: int = 500) -> list[dict]:
        body = await self.request("GET", "/lxmf/conversations", params={"limit": limit})
        _need(body, ("conversations",), "/lxmf/conversations")
        for c in body["conversations"]:
            _need(c, ("destination_hash", "latest_message_created_at", "is_unread"), "conversation")
        return body["conversations"]

    async def conversation_messages(self, peer: str, count: int, order: str = "asc",
                                    after_id: int | None = None) -> list[dict]:
        """Raw page, newest first (MeshChatX orders by id DESC whatever ``order`` says).

        order=asc : after_id means id > after_id (but you get the NEWEST ``count`` of them)
        order=desc: after_id means id < after_id
        """
        params = {"count": count, "order": order}
        if after_id is not None:
            params["after_id"] = after_id
        body = await self.request("GET", f"/lxmf-messages/conversation/{quote(peer, safe='')}", params=params)
        _need(body, ("lxmf_messages",), "/lxmf-messages/conversation")
        for m in body["lxmf_messages"]:
            _need(m, ("id", "hash", "is_incoming", "state", "content", "timestamp"), "lxmf message")
        return body["lxmf_messages"]

    async def send_lxmf(self, dest: str, text: str, method: str | None) -> dict:
        try:
            body = await self.request(
                "POST", "/lxmf-messages/send",
                json={"delivery_method": method, "lxmf_message": {"destination_hash": dest, "content": text}},
                timeout=self.cfg.send_timeout,
            )
        except BridgeError as e:
            if e.code == errors.UPSTREAM_ERROR:
                raise BridgeError(errors.SEND_FAILED, e.message, **e.details) from None
            raise
        _need(body, ("lxmf_message",), "/lxmf-messages/send")
        _need(body["lxmf_message"], ("hash",), "/lxmf-messages/send.lxmf_message")
        return body["lxmf_message"]

    async def mark_read(self, peer: str) -> None:
        await self.request("POST", f"/lxmf/conversations/{quote(peer, safe='')}/mark-as-read")

    # ---- RRC -------------------------------------------------------------------------------------
    async def rrc_hubs(self) -> list[dict]:
        body = await self.request("GET", "/rrc/hubs")
        _need(body, ("hubs",), "/rrc/hubs")
        for h in body["hubs"]:
            _need(h, ("hub_hash",), "rrc hub")
        return body["hubs"]

    async def rrc_room_messages(self, hub: str, room: str, limit: int, before_seq: int | None = None):
        params = {"limit": limit}
        if before_seq is not None:
            params["before_seq"] = before_seq
        body = await self.request(
            "GET", f"/rrc/hubs/{quote(hub, safe='')}/rooms/{quote(room, safe='')}/messages", params=params)
        _need(body, ("messages",), "rrc room messages")
        return body["messages"], bool(body.get("has_more", False))

    async def rrc_send(self, hub: str, room: str, text: str) -> None:
        await self.request("POST", f"/rrc/hubs/{quote(hub, safe='')}/rooms/{quote(room, safe='')}/messages",
                           json={"text": text, "action": False})

    async def rrc_active_clear(self) -> None:
        await self.request("POST", "/rrc/active/clear")

    # ---- websocket ---------------------------------------------------------------------------------
    async def open_ws(self) -> aiohttp.ClientWebSocketResponse:
        await self.login()
        url = self.cfg.base_url.replace("http", "ws", 1) + "/ws"
        for attempt in (0, 1):
            try:
                # No Origin header is sent (the server allows that; a wrong one is refused).
                return await self.session.ws_connect(url, heartbeat=None, max_msg_size=8 * 1024 * 1024)
            except aiohttp.WSServerHandshakeError as e:
                if e.status == 401 and attempt == 0:
                    self._logged_in = False
                    await self.login(force=True)
                    continue
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"websocket handshake failed: {e.status}") from None
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                raise BridgeError(errors.UPSTREAM_UNAVAILABLE, f"websocket failed: {type(e).__name__}") from None
        raise BridgeError(errors.UPSTREAM_UNAVAILABLE, "websocket failed")
