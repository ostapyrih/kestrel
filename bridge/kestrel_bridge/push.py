"""Push fan-out: WS-derived events -> subscribed Links, LXMF fallback for offline phones.

Transport awareness: the *effective profile* of a phone is the most restrictive of
  - what the path table says (next hop interface is TCP/backbone -> "full", otherwise "constrained"),
  - what the phone asked for in /subscribe ("profile" hint can only downgrade),
  - ``push.unknown_profile`` when no path is known.
"constrained" (LoRa) receives only incoming direct LXMF messages, RRC mentions and terminal
delivery states of messages the phone sent through the bridge, with text truncated.
"""
from __future__ import annotations

import logging
import time
from collections import defaultdict, deque

from . import codec
from .config import Config

log = logging.getLogger("kestrel.push")

FULL = "full"
CONSTRAINED = "constrained"
TERMINAL = frozenset({"delivered", "rejected", "cancelled", "failed"})
TOPICS = ("lxmf", "rrc")


def classify_interface(name: str | None, fast_prefixes) -> bool:
    """True when the interface name (``str(RNS interface)``, e.g. ``TCPInterface[x/1.2.3.4:4242]``) is fast."""
    if not name:
        return False
    cls = name.split("[", 1)[0].strip()
    return cls in fast_prefixes


def more_restrictive(*profiles: str) -> str:
    return CONSTRAINED if CONSTRAINED in profiles else FULL


def truncate_utf8(text: str, max_bytes: int) -> tuple[str, bool]:
    raw = text.encode("utf-8")
    if len(raw) <= max_bytes:
        return text, False
    return raw[:max_bytes].decode("utf-8", errors="ignore"), True


def filter_event(event: dict, profile: str, max_text_bytes: int) -> dict | None:
    """Return the event as it may be sent under ``profile``, or None to drop it."""
    if profile == FULL:
        return event
    name, data = event["event"], event["data"]
    if name == "resync":
        return event
    if name == "lxmf.message":
        if not data.get("incoming"):
            return None
        text, trunc = truncate_utf8(data.get("text") or "", max_text_bytes)
        out = {"peer": data["peer"], "hash": data.get("hash"), "incoming": True, "ts": data.get("ts"),
               "text": text, "truncated": trunc}
        if data.get("name"):
            out["name"] = data["name"][:32]
        return {"event": name, "data": out}
    if name == "rrc.message":
        if not data.get("mention"):
            return None
        text, trunc = truncate_utf8(data.get("text") or "", max_text_bytes)
        out = {"hub": data["hub"], "room": data["room"], "seq": data.get("seq"), "ts": data.get("ts"),
               "nick": (data.get("nick") or "")[:32], "mention": True, "text": text, "truncated": trunc}
        return {"event": name, "data": out}
    if name == "lxmf.state":
        if data.get("cmd_id") and data.get("state") in TERMINAL:
            return {"event": name, "data": {k: data[k] for k in ("hash", "state", "cmd_id") if k in data}}
        return None
    return None


def topic_of(event_name: str) -> str | None:
    head = event_name.split(".", 1)[0]
    return head if head in TOPICS else None


class Subscriber:
    """A subscribed phone Link. ``send`` delivers raw bytes (packet or resource) and returns success."""

    def __init__(self, phone: str, send, topics=TOPICS, hint: str = FULL):
        self.phone = phone
        self.send = send
        self.topics = frozenset(t for t in topics if t in TOPICS)
        self.hint = hint if hint in (FULL, CONSTRAINED) else FULL
        self.profile_cache: tuple[float, str] | None = None


class PushHub:
    def __init__(self, cfg: Config, profile_of=None, offline_send=None, clock=time.monotonic):
        """``profile_of(phone) -> 'full' | 'constrained' | None`` (None = unknown path).
        ``offline_send(phone, wire_bytes) -> None`` queues an LXMF push."""
        self.cfg = cfg
        self.profile_of = profile_of or (lambda phone: None)
        self.offline_send = offline_send
        self._clock = clock
        self._subs: list[Subscriber] = []
        self._seq = 0
        self._offline_times: dict[str, deque] = defaultdict(deque)

    def subscribe(self, sub: Subscriber) -> None:
        self.unsubscribe(sub)
        self._subs.append(sub)

    def unsubscribe(self, sub: Subscriber) -> None:
        if sub in self._subs:
            self._subs.remove(sub)

    def subscribers(self) -> list[Subscriber]:
        return list(self._subs)

    def effective_profile(self, sub: Subscriber) -> str:
        now = self._clock()
        if sub.profile_cache and now - sub.profile_cache[0] < 30:
            return sub.profile_cache[1]
        path = self.profile_of(sub.phone)
        if path is None:
            path = self.cfg.push.unknown_profile
        prof = more_restrictive(path, sub.hint)
        sub.profile_cache = (now, prof)
        return prof

    def _wire(self, event: dict) -> bytes:
        self._seq += 1
        return codec.pack({"t": "push", "seq": self._seq, "ts": time.time(), "event": event["event"],
                           "data": event["data"]})

    def publish(self, event: dict) -> int:
        """Fan out one event; returns the number of deliveries (links + offline)."""
        name = event["event"]
        topic = topic_of(name)
        delivered = 0
        live_phones = set()
        for sub in list(self._subs):
            if topic is not None and topic not in sub.topics:
                continue
            live_phones.add(sub.phone)
            filtered = filter_event(event, self.effective_profile(sub), self.cfg.limits.constrained_max_text_bytes)
            if filtered is None:
                continue
            try:
                ok = sub.send(self._wire(filtered))
            except Exception:
                ok = False
            if ok:
                delivered += 1
            else:
                self.unsubscribe(sub)
        if name in ("lxmf.message", "rrc.message") and self.offline_send and self.cfg.push.lxmf_offline_push:
            for phone in self.cfg.whitelist:
                if phone in live_phones:
                    continue
                small = filter_event(event, CONSTRAINED, self.cfg.limits.constrained_max_text_bytes)
                if small is None or not self._offline_budget(phone):
                    continue
                try:
                    self.offline_send(phone, self._wire(small))
                    delivered += 1
                except Exception:
                    log.exception("offline push failed")
        return delivered

    def _offline_budget(self, phone: str) -> bool:
        now = self._clock()
        q = self._offline_times[phone]
        while q and now - q[0] > 3600:
            q.popleft()
        if len(q) >= self.cfg.push.offline_push_max_per_hour:
            return False
        q.append(now)
        return True
