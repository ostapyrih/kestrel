"""A fake MeshChatX HTTP+WS server for tests (implements the subset of the API the bridge uses).

Behaviour mirrors the facts in docs/PLAN.md: cookie session + CSRF that rotates at login, 401 for
unauthenticated calls, message pages that always come back newest-first, /auth/logout recorded
(the bridge must never call it).

Run standalone:  python -m tests.fake_meshchatx --port 18000
Control endpoints (test only): POST /_test/emit (broadcast a WS event), /_test/expire (kill sessions),
GET /_test/calls (request log).
"""
from __future__ import annotations

import argparse
import json
import secrets
import time

from aiohttp import WSMsgType, web

PASSWORD = "test-password"
API = "/api/v1"


class FakeMeshChatX:
    def __init__(self, password: str = PASSWORD, version: str = "4.12.1", api_version: int = 2):
        self.password = password
        self.version = version
        self.api_version = api_version
        self.sessions: dict[str, dict] = {}   # cookie -> {"csrf": str}
        self.calls: list[tuple[str, str]] = []
        self.logins = 0
        self.network_ready = True
        self.conversations: list[dict] = []
        self.messages: dict[str, list[dict]] = {}   # peer -> messages (ascending id)
        self.hubs: list[dict] = []
        self.room_messages: dict[tuple[str, str], list[dict]] = {}
        self.sent: list[dict] = []
        self.rrc_sent: list[dict] = []
        self.active_cleared = 0
        self.ws_clients: list[web.WebSocketResponse] = []
        self.ws_inbound: list[dict] = []
        self.next_id = 1
        self.drop_csrf_once = False
        self.app = self._build()

    # ---- helpers ----------------------------------------------------------------------------
    def add_message(self, peer: str, text: str, incoming: bool = True, state: str = "delivered") -> dict:
        m = {"id": self.next_id, "hash": secrets.token_hex(16), "source_hash": peer if incoming else "0" * 32,
             "destination_hash": "0" * 32 if incoming else peer, "is_incoming": incoming, "state": state,
             "method": "direct", "title": "", "content": text, "fields": {}, "timestamp": time.time()}
        self.next_id += 1
        self.messages.setdefault(peer, []).append(m)
        return m

    def kill_sessions(self) -> None:
        self.sessions.clear()

    async def emit(self, event: dict) -> None:
        for ws in list(self.ws_clients):
            if not ws.closed:
                await ws.send_str(json.dumps(event))

    def _session(self, request: web.Request) -> dict | None:
        return self.sessions.get(request.cookies.get("AIOHTTP_SESSION", ""))

    # ---- app --------------------------------------------------------------------------------------
    def _build(self) -> web.Application:
        @web.middleware
        async def mw(request: web.Request, handler):
            self.calls.append((request.method, request.path))
            if request.path.startswith(API) and request.path not in (
                    f"{API}/status", f"{API}/auth/csrf", f"{API}/auth/login", f"{API}/auth/logout"):
                if self._session(request) is None:
                    return web.json_response({"error": "Authentication required"}, status=401)
            if request.path.startswith(API) and request.method not in ("GET", "HEAD", "OPTIONS") \
                    and request.path != f"{API}/auth/csrf":
                s = self._session(request)
                if s is not None and (request.headers.get("X-CSRF-Token") != s["csrf"] or self.drop_csrf_once):
                    self.drop_csrf_once = False
                    return web.json_response({"error": "bad csrf", "code": "csrf_invalid"}, status=403)
            return await handler(request)

        app = web.Application(middlewares=[mw])
        r = app.router
        r.add_get(f"{API}/status", self.status)
        r.add_get(f"{API}/auth/csrf", self.csrf)
        r.add_post(f"{API}/auth/login", self.login)
        r.add_post(f"{API}/auth/logout", self.logout)
        r.add_get(f"{API}/app/info", self.app_info)
        r.add_get(f"{API}/lxmf/conversations", self.list_conversations)
        r.add_get(f"{API}/lxmf-messages/conversation/{{peer}}", self.conv_messages)
        r.add_post(f"{API}/lxmf-messages/send", self.send)
        r.add_post(f"{API}/lxmf/conversations/{{peer}}/mark-as-read", self.mark_read)
        r.add_get(f"{API}/rrc/hubs", self.rrc_hubs)
        r.add_get(f"{API}/rrc/hubs/{{hub}}/rooms/{{room}}/messages", self.rrc_messages)
        r.add_post(f"{API}/rrc/hubs/{{hub}}/rooms/{{room}}/messages", self.rrc_send)
        r.add_post(f"{API}/rrc/active/clear", self.rrc_clear)
        r.add_get("/ws", self.ws)
        r.add_post("/_test/emit", self.t_emit)
        r.add_post("/_test/expire", self.t_expire)
        r.add_post("/_test/seed", self.t_seed)
        r.add_get("/_test/calls", self.t_calls)
        return app

    async def status(self, request):
        return web.json_response({"status": "ok", "version": self.version, "network_ready": self.network_ready})

    async def csrf(self, request):
        s = self._session(request)
        if s is None:
            cookie = secrets.token_hex(16)
            s = {"csrf": secrets.token_hex(8), "authed": False}
            self.sessions[cookie] = s
            resp = web.json_response({"csrf_token": s["csrf"]})
            resp.set_cookie("AIOHTTP_SESSION", cookie, httponly=True)
            return resp
        return web.json_response({"csrf_token": s["csrf"]})

    async def login(self, request):
        s = self._session(request)
        body = await request.json()
        if s is None or request.headers.get("X-CSRF-Token") != s["csrf"]:
            return web.json_response({"error": "bad csrf", "code": "csrf_invalid"}, status=403)
        if body.get("password") != self.password:
            return web.json_response({"error": "Invalid password"}, status=401)
        self.logins += 1
        s["csrf"] = secrets.token_hex(8)  # rotated at login
        s["authed"] = True
        return web.json_response({"message": "Login successful"})

    async def logout(self, request):
        self.kill_sessions()
        return web.json_response({"message": "bye"})

    async def app_info(self, request):
        return web.json_response({"app_info": {"version": self.version, "api_version": self.api_version}})

    async def list_conversations(self, request):
        return web.json_response({"conversations": self.conversations})

    async def conv_messages(self, request):
        peer = request.match_info["peer"]
        q = request.query
        count = min(int(q.get("count", 100)), 1000)
        order = q.get("order", "asc")
        after = q.get("after_id")
        rows = list(self.messages.get(peer, []))
        if after is not None:
            after = int(after)
            rows = [m for m in rows if (m["id"] > after if order == "asc" else m["id"] < after)]
        rows.sort(key=lambda m: m["id"], reverse=True)   # always newest first
        return web.json_response({"lxmf_messages": rows[:count]})

    async def send(self, request):
        body = await request.json()
        lm = body["lxmf_message"]
        if lm["destination_hash"] == "f" * 32:
            return web.json_response({"error": "No path to destination", "code": "send_failed"}, status=503)
        m = self.add_message(lm["destination_hash"], lm["content"], incoming=False, state="outbound")
        self.sent.append({"to": lm["destination_hash"], "text": lm["content"], "method": body.get("delivery_method")})
        return web.json_response({"lxmf_message": {k: v for k, v in m.items() if k != "id"}})

    async def mark_read(self, request):
        return web.json_response({"message": "ok"})

    async def rrc_hubs(self, request):
        return web.json_response({"hubs": self.hubs})

    async def rrc_messages(self, request):
        key = (request.match_info["hub"], request.match_info["room"])
        rows = self.room_messages.get(key, [])
        limit = int(request.query.get("limit", 200))
        before = request.query.get("before_seq")
        if before is not None:
            rows = [m for m in rows if m["seq"] < int(before)]
        page = rows[-limit:]
        return web.json_response({"messages": page, "members": [], "has_more": len(rows) > len(page)})

    async def rrc_send(self, request):
        body = await request.json()
        self.rrc_sent.append({"hub": request.match_info["hub"], "room": request.match_info["room"], **body})
        return web.json_response({"message": "Sent"})

    async def rrc_clear(self, request):
        self.active_cleared += 1
        return web.json_response({"message": "ok"})

    async def ws(self, request):
        if self._session(request) is None or not self._session(request).get("authed"):
            return web.json_response({"error": "Authentication required"}, status=401)
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.ws_clients.append(ws)
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                data = json.loads(msg.data)
                self.ws_inbound.append(data)
                if data.get("type") == "ping":
                    await ws.send_str(json.dumps({"type": "pong"}))
        if ws in self.ws_clients:
            self.ws_clients.remove(ws)
        return ws

    # ---- test control -------------------------------------------------------------------------------
    async def t_emit(self, request):
        await self.emit(await request.json())
        return web.json_response({"clients": len(self.ws_clients)})

    async def t_expire(self, request):
        self.kill_sessions()
        return web.json_response({})

    async def t_seed(self, request):
        body = await request.json()
        for c in body.get("conversations", []):
            self.conversations.append(c)
        for m in body.get("messages", []):
            self.add_message(m["peer"], m["text"], m.get("incoming", True))
        self.hubs.extend(body.get("hubs", []))
        return web.json_response({})

    async def t_calls(self, request):
        return web.json_response({"calls": self.calls, "sent": self.sent, "logins": self.logins,
                                  "ws_clients": len(self.ws_clients)})


def conversation(peer: str, name: str = "Peer", created_at="2026-01-01T00:00:00", unread: bool = False) -> dict:
    return {"display_name": name, "custom_display_name": None, "destination_hash": peer, "is_unread": unread,
            "failed_messages_count": 0, "latest_message_preview": "hello", "latest_message_created_at": created_at}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18000)
    args = ap.parse_args()
    fake = FakeMeshChatX()
    web.run_app(fake.app, host="127.0.0.1", port=args.port, print=lambda *_: None)


if __name__ == "__main__":
    main()
