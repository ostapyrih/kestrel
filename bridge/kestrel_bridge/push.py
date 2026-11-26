"""Push fan-out: WS-derived events -> subscribed Links, LXMF fallback for offline phones.

Transport awareness: the *effective profile* of a phone is the most restrictive of
  - ``push.profile`` = ``full``/``constrained`` (override), or with ``auto``:
      * shared mode: the path table of the shared instance (next hop interface TCP/backbone -> "full"),
      * standalone mode: the phone's live Link (RTT < push.full_max_rtt and MTU >= push.full_min_link_mtu),
  - what the phone asked for in /subscribe ("profile" hint can only downgrade),
  - ``push.unknown_profile`` when no path is known.
"constrained" (LoRa) receives only incoming direct LXMF messages, RRC mentions and terminal
delivery states of messages the phone sent through the bridge, with text truncated.

Fan-out (protocol v2): every identified, subscribed Link of every non-revoked device gets the event. The
LXMF fallback goes only to devices with the ``field`` role that have no live Link.
"""
from __future__ import annotations

import logging
import secrets
import time
from collections import defaultdict, deque

from . import codec
from .config import Config

log = logging.getLogger("kestrel.push")

FULL = "full"
CONSTRAINED = "constrained"
TERMINAL = frozenset({"delivered", "rejected", "cancelled", "failed"})
TOPICS = ("lxmf", "rrc", "vault")
# Events delivered to every subscribed Link whatever its topics (security / consistency events).
ALWAYS = frozenset({"resync", "device_added", "device_updated", "device_revoked"})


def classify_interface(name: str | None, fast_prefixes) -> bool:
    """True when the interface name (``str(RNS interface)``, e.g. ``TCPInterface[x/1.2.3.4:4242]``) is fast."""
    if not name:
        return False
    cls = name.split("[", 1)[0].strip()
    return cls in fast_prefixes


def classify_link(rtt, mtu, max_rtt: float, min_mtu: int) -> str | None:
    """Profile from the measured state of the phone's Link (standalone mode).

    ``full`` needs a measured RTT below ``max_rtt`` seconds AND a link MTU of at least ``min_mtu``
    bytes (LoRa/serial paths negotiate the 500-byte base MTU and have RTTs of seconds). Missing
    measurements -> None (unknown).
    """
    if not isinstance(rtt, (int, float)) or not isinstance(mtu, int) or rtt <= 0 or mtu <= 0:
        return None
    return FULL if rtt < max_rtt and mtu >= min_mtu else CONSTRAINED


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
    if name in ("resync", "device_revoked"):
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
    """Topic of an event; None = always delivered."""
    if event_name in ALWAYS:
        return None
    if event_name == "read_state":
        return "lxmf"
    head = event_name.split(".", 1)[0]
    return head if head in TOPICS else None


class Subscriber:
    """A subscribed device Link. ``send`` delivers raw bytes (packet or resource) and returns success."""

    def __init__(self, device_id: str, send, topics=TOPICS, hint: str = FULL):
        self.device_id = device_id
        self.send = send
        self.topics = frozenset(t for t in topics if t in TOPICS)
        self.hint = hint if hint in (FULL, CONSTRAINED) else FULL
        self.profile_cache: tuple[float, str] | None = None


class PushHub:
    def __init__(self, cfg: Config, profile_of=None, offline_send=None, clock=time.monotonic, registry=None,
                 link_online=None):
        """``profile_of(device_id) -> 'full' | 'constrained' | None`` (None = unknown path).
        ``offline_send(device_id, wire_bytes) -> None`` queues an LXMF push. ``registry`` supplies the
        ``field`` devices; ``link_online(device_id) -> bool`` tells whether a device has any live Link."""
        self.cfg = cfg
        self.registry = registry
        self.link_online = link_online or (lambda device_id: False)
        self.profile_of = profile_of or (lambda device_id: None)
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

    def drop_device(self, device_id: str) -> None:
        """Forget every subscription of a device (it was revoked)."""
        for sub in [s for s in self._subs if s.device_id == device_id]:
            self.unsubscribe(sub)

    def effective_profile(self, sub: Subscriber) -> str:
        now = self._clock()
        if sub.profile_cache and now - sub.profile_cache[0] < 30:
            return sub.profile_cache[1]
        if self.cfg.push.profile in (FULL, CONSTRAINED):
            path = self.cfg.push.profile
        else:
            path = self.profile_of(sub.device_id)
            if path is None:
                path = self.cfg.push.unknown_profile
        prof = more_restrictive(path, sub.hint)
        sub.profile_cache = (now, prof)
        return prof

    def _wire(self, event: dict, event_id: str) -> bytes:
        self._seq += 1
        return codec.pack({"t": "push", "seq": self._seq, "id": event_id, "ts": time.time(),
                           "event": event["event"], "data": event["data"]})

    def publish(self, event: dict, skip_device: str | None = None) -> int:
        """Fan out one event; returns the number of deliveries (links + offline).

        ``id`` identifies the event (the Link copy and the LXMF fallback copy of one event share it), so a
        device that receives both can drop the duplicate. There is no explicit acknowledgement in v2:
        push is a hint, /sync_chats and /get_messages are the source of truth."""
        name = event["event"]
        topic = topic_of(name)
        event_id = secrets.token_hex(8)
        delivered = 0
        live_devices = set()
        for sub in list(self._subs):
            if sub.device_id == skip_device:
                continue
            if topic is not None and topic not in sub.topics:
                continue
            live_devices.add(sub.device_id)
            filtered = filter_event(event, self.effective_profile(sub), self.cfg.limits.constrained_max_text_bytes)
            if filtered is None:
                continue
            try:
                ok = sub.send(self._wire(filtered, event_id))
            except Exception:
                ok = False
            if ok:
                delivered += 1
            else:
                self.unsubscribe(sub)
        if name in ("lxmf.message", "rrc.message") and self.offline_send and self.cfg.push.lxmf_offline_push \
                and self.registry is not None:
            for dev in self.registry.field_devices():
                if dev.device_id in live_devices or dev.device_id == skip_device or self.link_online(dev.device_id):
                    continue
                small = filter_event(event, CONSTRAINED, self.cfg.limits.constrained_max_text_bytes)
                if small is None or not self._offline_budget(dev.device_id):
                    continue
                try:
                    self.offline_send(dev.device_id, self._wire(small, event_id))
                    delivered += 1
                except Exception:
                    log.exception("offline push failed")
        return delivered

    def _offline_budget(self, device_id: str) -> bool:
        now = self._clock()
        q = self._offline_times[device_id]
        while q and now - q[0] > 3600:
            q.popleft()
        if len(q) >= self.cfg.push.offline_push_max_per_hour:
            return False
        q.append(now)
        return True
