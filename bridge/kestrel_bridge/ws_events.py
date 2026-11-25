"""MeshChatX /ws consumer.

The server never replays missed events, so after every reconnect ``on_resync`` is invoked and the
service must resync over HTTP. Only the ``lxmf`` and ``rrc`` topics are kept.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random

import aiohttp

from .errors import BridgeError
from .meshchatx_client import MeshChatXClient

log = logging.getLogger("kestrel.ws")

ALL_TOPICS = ("lxmf", "announce", "nomad", "telephone", "rrc", "filesync", "rns.link", "plugin",
              "sessions", "config", "control", "other")
KEEP_TOPICS = ("lxmf", "rrc")
UNWANTED_TOPICS = [t for t in ALL_TOPICS if t not in KEEP_TOPICS]
INTERESTING = frozenset({
    "lxmf.delivery", "lxmf_message_created", "lxmf_message_state_updated", "lxmf_message_deleted",
    "rrc.message", "rrc.change",
})
PING_INTERVAL = 30.0


class WsEvents:
    def __init__(self, client: MeshChatXClient, on_event, on_resync, *, ping_interval: float = PING_INTERVAL,
                 backoff_base: float = 1.0, backoff_max: float = 60.0):
        self.client = client
        self.on_event = on_event      # async callable(dict)
        self.on_resync = on_resync    # async callable()
        self.ping_interval = ping_interval
        self.backoff_base = backoff_base
        self.backoff_max = backoff_max
        self.connected = False
        self._stop = asyncio.Event()
        self._connects = 0

    def stop(self) -> None:
        self._stop.set()

    async def run(self) -> None:
        failures = 0
        while not self._stop.is_set():
            try:
                ws = await self.client.open_ws()
            except BridgeError as e:
                failures += 1
                delay = min(self.backoff_max, self.backoff_base * 2 ** min(failures - 1, 10))
                delay *= 0.75 + random.random() / 2
                log.warning("websocket connect failed (%s); retry in %.1fs", e.code, delay)
                await self._sleep(delay)
                continue
            failures = 0
            self._connects += 1
            try:
                await ws.send_json({"type": "ws.unsubscribe", "topics": UNWANTED_TOPICS})
                self.connected = True
                log.info("websocket connected (connect #%d)", self._connects)
                if self._connects > 1:
                    await self.on_resync()
                await self._pump(ws)
            except (aiohttp.ClientError, asyncio.TimeoutError, ConnectionError) as e:
                log.warning("websocket dropped: %s", type(e).__name__)
            finally:
                self.connected = False
                if not ws.closed:
                    await ws.close()
            await self._sleep(self.backoff_base)

    async def _sleep(self, delay: float) -> None:
        try:
            await asyncio.wait_for(self._stop.wait(), timeout=delay)
        except asyncio.TimeoutError:
            pass

    async def _pump(self, ws) -> None:
        pinger = asyncio.create_task(self._ping_loop(ws))
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except ValueError:
                        continue
                    if isinstance(data, dict) and data.get("type") in INTERESTING:
                        try:
                            await self.on_event(data)
                        except Exception:
                            log.exception("event handler failed")  # never include event content
                elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.ERROR):
                    break
                if self._stop.is_set():
                    break
        finally:
            pinger.cancel()

    async def _ping_loop(self, ws) -> None:
        while not ws.closed:
            await asyncio.sleep(self.ping_interval)
            try:
                await ws.send_json({"type": "ping"})
            except Exception:
                return

