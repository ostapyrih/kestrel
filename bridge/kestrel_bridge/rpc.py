"""RNS Link RPC: destination ``kestrel.bridge`` on identity S, identify()-based authorization."""
from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import threading
import time
from collections import deque

import RNS

from . import codec, errors
from .config import Config
from .push import FULL, CONSTRAINED, PushHub, Subscriber, classify_interface, classify_link
from .rns_setup import AnnounceWatcher, require_stamping_applied, tcp_client_interfaces
from .service import PATHS, Ctx, Service

log = logging.getLogger("kestrel.rpc")

APP_NAME = "kestrel"
ASPECT = "bridge"


def destination_hash(identity: "RNS.Identity") -> bytes:
    return RNS.Destination.hash(identity, APP_NAME, ASPECT)


def identity_from_public_key(pub_hex: str) -> "RNS.Identity":
    ident = RNS.Identity(create_keys=False)
    ident.load_public_key(bytes.fromhex(pub_hex))
    return ident


def device_of(identity, registry):
    """Return the trusted (registered, not revoked) Device whose FULL public key is ``identity``'s, or None.

    A 16-byte identity hash alone never matches: the registry is looked up by the hash of the full key and
    the stored key must equal the presented one.
    """
    if identity is None:
        return None
    try:
        key = identity.get_public_key().hex()
    except Exception:
        return None
    return registry.trusted_by_pubkey(key)


class PathProfile:
    """Maps a device to 'full'/'constrained' using the path table of the shared instance (RPC)."""

    def __init__(self, cfg: Config, registry):
        self.cfg = cfg
        self.registry = registry
        self._hashes: dict[str, bytes] = {}

    def __call__(self, device_id: str) -> str | None:
        try:
            dh = self._hashes.get(device_id)
            if dh is None:
                dev = self.registry.get(device_id)
                if dev is None:
                    return None
                dh = RNS.Destination.hash(identity_from_public_key(dev.public_key), "lxmf", "delivery")
                self._hashes[device_id] = dh
            name = RNS.Reticulum.get_instance().get_next_hop_if_name(dh)
        except Exception as e:  # RPC key mismatch, instance gone, ...
            log.debug("next-hop lookup failed: %s", type(e).__name__)
            return None
        if not name or name == "None":
            return None
        return FULL if classify_interface(name, self.cfg.push.fast_interfaces) else CONSTRAINED


class LinkProfile:
    """Standalone mode: profile of a device from the measured RTT/MTU of its current Link.

    ``link_of(device_id)`` returns the device's active Link (or None). No access to any path table needed.
    """

    def __init__(self, cfg: Config, link_of):
        self.cfg = cfg
        self.link_of = link_of

    def __call__(self, device_id: str) -> str | None:
        link = self.link_of(device_id)
        if link is None:
            return None
        return classify_link(getattr(link, "rtt", None), getattr(link, "mtu", None),
                             self.cfg.push.full_max_rtt, self.cfg.push.full_min_link_mtu)


class _LinkState:
    def __init__(self, link):
        self.link = link
        self.device_id: str | None = None
        self.sub: Subscriber | None = None
        self.closing = False                 # a reason packet was sent / the Link is about to be closed
        self.timer: threading.Timer | None = None

    def send(self, data: bytes) -> bool:
        link = self.link
        if link.status != RNS.Link.ACTIVE:
            return False
        if len(data) <= link.get_mdu():
            return RNS.Packet(link, data).send() is not False
        RNS.Resource(data, link)
        return True


class RpcServer:
    def __init__(self, cfg: Config, identity: "RNS.Identity", service: Service, push: PushHub,
                 loop: asyncio.AbstractEventLoop):
        self.cfg = cfg
        self.identity = identity
        self.service = service
        self.push = push
        self.loop = loop
        self.registry = service.registry
        self.destination: RNS.Destination | None = None
        self._links: dict[bytes, _LinkState] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._announcer: AnnounceWatcher | None = None
        self._busy: dict[bytes, int] = {}       # link_id -> requests being handled right now
        self._rej_clock = time.monotonic
        self._rej_ident: dict[bytes, deque] = {}    # identity hash -> times of recent reason packets
        self._rej_global: deque = deque()
        self.service.online = self.has_link
        self.registry.subscribe(self._on_device_event)

    # ---- lifecycle ---------------------------------------------------------------------------
    def start(self) -> None:
        require_stamping_applied()   # the stamping policy must be set before the first destination exists
        d = RNS.Destination(self.identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP_NAME, ASPECT)
        for path in PATHS:
            # authorization is done in the handler (the whitelist is checked against the full public key)
            d.register_request_handler(path, self._make_handler(path), allow=RNS.Destination.ALLOW_ALL)
        d.set_link_established_callback(self._link_established)
        self.destination = d
        # standalone: announce on start, every announce_interval and after every TCP reconnect;
        # shared: periodic only (the shared instance owns the interface)
        watch = tcp_client_interfaces if self.cfg.rns.mode == "standalone" else None
        self._announcer = AnnounceWatcher(
            lambda: d.announce(), watch, self.cfg.rns.announce_interval,
            emitted_at=lambda: self._announce_emitted_at(d), stamping=lambda: bool(RNS.Transport.STAMP_DESTINATIONS))
        self._announcer.start()
        log.info("RPC destination %s ready", RNS.prettyhexrep(d.hash))

    @staticmethod
    def _announce_emitted_at(d) -> float | None:
        """Wall-clock time of the last announce RNS built for ``d`` (``_announce`` records it in
        ``path_responses[None]`` right before sending), or None when this RNS does not expose it."""
        entry = getattr(d, "path_responses", {}).get(None)
        return float(entry[0]) if entry else None

    @property
    def last_announce_emitted_at(self) -> float | None:
        return self._announcer.last_emitted_at if self._announcer is not None else None

    @property
    def announce_pending(self) -> bool:
        return self._announcer is not None and self._announcer.pending

    def active_link(self, device_id: str):
        """The most recent active Link of an identified device, or None."""
        with self._lock:
            states = list(self._links.values())
        for st in reversed(states):
            if st.device_id == device_id and st.link.status == RNS.Link.ACTIVE:
                return st.link
        return None

    def has_link(self, device_id: str) -> bool:
        return self.active_link(device_id) is not None

    def close_device(self, device_id: str) -> int:
        """Tell every Link of a device why (``kestrel.reject`` / ``device_revoked``), then tear it down after the
        grace delay. A Link that is answering a request right now (a device that revokes itself) gets the reason
        packet one second later, i.e. after its response."""
        with self._lock:
            states = [st for st in self._links.values() if st.device_id == device_id]
        for st in states:
            st.device_id = None          # no further command is accepted on this Link
            delay = 1.0 if self._busy.get(st.link.link_id) else 0.0
            self._reject_and_close(st, errors.DEVICE_REVOKED, delay)
        return len(states)

    def _reject_allowed(self, identity) -> bool:
        """Sliding one-minute window of reason packets per remote identity and over all identities."""
        now = self._rej_clock()
        limit = self.cfg.limits.reject_rate_per_minute
        try:
            key = bytes(identity.hash)
        except Exception:
            key = b""
        with self._lock:
            for q in [self._rej_global, *self._rej_ident.values()]:
                while q and now - q[0] > 60:
                    q.popleft()
            for k in [k for k, q in self._rej_ident.items() if not q]:
                del self._rej_ident[k]
            q = self._rej_ident.setdefault(key, deque())
            if len(q) >= limit or len(self._rej_global) >= limit * 10:
                return False
            q.append(now)
            self._rej_global.append(now)
            return True

    def _reject_and_close(self, st: _LinkState, code: str, send_delay: float = 0.0, send: bool = True) -> None:
        """Send ONE reason packet over the Link, then tear it down after ``limits.reject_grace`` seconds (or
        earlier when the client closes it: ``_link_closed`` cancels the timer)."""
        if st.closing:
            return
        st.closing = True
        link = st.link

        def _teardown() -> None:
            try:
                if link.status != RNS.Link.CLOSED:
                    link.teardown()
            except Exception:
                log.exception("could not close a link")

        def _go() -> None:
            if send and link.status == RNS.Link.ACTIVE:
                try:
                    st.send(codec.reject_packet(code, self.service._clock()))
                except Exception:
                    log.exception("could not send the reject reason")
            grace = self.cfg.limits.reject_grace
            if grace <= 0 or not send:
                _teardown()
                return
            st.timer = threading.Timer(grace, _teardown)
            st.timer.daemon = True
            st.timer.start()

        if send_delay > 0:
            st.timer = threading.Timer(send_delay, _go)
            st.timer.daemon = True
            st.timer.start()
        else:
            _go()

    def _on_device_event(self, event: str, device) -> None:
        if event == "revoked":
            n = self.close_device(device.device_id)
            log.info("device %s revoked, %d link(s) closed", device.device_id[:8], n)

    def stop(self) -> None:
        self._stop.set()
        if self._announcer is not None:
            self._announcer.stop()
        with self._lock:
            states = list(self._links.values())
        for st in states:
            try:
                st.link.teardown()
            except Exception:
                pass

    # ---- links -----------------------------------------------------------------------------------
    def _link_established(self, link) -> None:
        st = _LinkState(link)
        with self._lock:
            self._links[link.link_id] = st
        link.set_remote_identified_callback(self._remote_identified)
        link.set_link_closed_callback(self._link_closed)
        t = threading.Timer(self.cfg.limits.identify_timeout, self._identify_timeout, args=(link,))
        t.daemon = True
        t.start()

    def _identify_timeout(self, link) -> None:
        st = self._links.get(link.link_id)
        if st is not None and st.device_id is None and link.status == RNS.Link.ACTIVE:
            log.info("link did not identify in time, closing")
            link.teardown()

    def _remote_identified(self, link, identity) -> None:
        dev = device_of(identity, self.registry)
        st = self._links.get(link.link_id)
        if dev is None:
            revoked = None
            try:
                revoked = self.registry.by_pubkey(identity.get_public_key().hex())
            except Exception:
                pass
            code = errors.DEVICE_REVOKED if revoked is not None else errors.UNAUTHORIZED
            log.warning("link identified with an unknown or revoked key (identity %s): %s",
                        RNS.prettyhexrep(identity.hash), code)
            if st is None:
                link.teardown()
                return
            # no data other than the one reason packet ever goes to this Link; over the rate limit it is closed silently
            self._reject_and_close(st, code, send=self._reject_allowed(identity))
            return
        if st is not None:
            st.device_id = dev.device_id
        self.registry.touch_seen(dev.device_id)
        log.info("device linked (%s, identity %s)", dev.name, RNS.prettyhexrep(identity.hash))

    def _link_closed(self, link) -> None:
        with self._lock:
            st = self._links.pop(link.link_id, None)
        if st is not None and st.timer is not None:
            st.timer.cancel()
        if st is not None and st.sub is not None:
            self.push.unsubscribe(st.sub)

    # ---- requests ------------------------------------------------------------------------------------
    def _make_handler(self, path_name: str):
        def handler(path, data, request_id, link_id, remote_identity, requested_at):
            return self._handle(path, data, link_id, remote_identity)
        return handler

    def _handle(self, path: str, data, link_id: bytes, remote_identity) -> dict:
        dev = device_of(remote_identity, self.registry)
        if dev is None:
            revoked = None
            try:
                revoked = self.registry.by_pubkey(remote_identity.get_public_key().hex())
            except Exception:
                pass
            if revoked is not None:
                return codec.err(errors.DEVICE_REVOKED, "this device was revoked")
            return codec.err(errors.UNAUTHORIZED, "identify() with a trusted device key first")
        st = self._links.get(link_id)
        if st is None:
            return codec.err(errors.INTERNAL, "unknown link")
        if st.device_id != dev.device_id:
            return codec.err(errors.UNAUTHORIZED, "identify() with a trusted device key first")
        device_id = dev.device_id

        def subscribe(topics, hint):
            if st.sub is not None:
                self.push.unsubscribe(st.sub)
            st.sub = Subscriber(device_id, st.send, topics, hint)
            self.push.subscribe(st.sub)
            return {"topics": sorted(st.sub.topics), "profile": self.push.effective_profile(st.sub),
                    "mdu": st.link.get_mdu()}

        if data is not None and not isinstance(data, dict):
            return codec.err(errors.BAD_REQUEST, "request must be a map")
        forced = self.cfg.push.profile if self.cfg.push.profile != "auto" else None
        ctx = Ctx(device_id=device_id, transport="link", subscribe=subscribe,
                  profile=forced or self.push.profile_of(device_id))
        self._busy[link_id] = self._busy.get(link_id, 0) + 1
        try:
            fut = asyncio.run_coroutine_threadsafe(self.service.dispatch(path, data, ctx), self.loop)
            try:
                resp = fut.result(timeout=self.cfg.limits.rpc_timeout)
            except (concurrent.futures.TimeoutError, TimeoutError):
                fut.cancel()
                return codec.err(errors.UPSTREAM_UNAVAILABLE, "request timed out")
        finally:
            left = self._busy.get(link_id, 1) - 1
            if left > 0:
                self._busy[link_id] = left
            else:
                self._busy.pop(link_id, None)
        return codec.clamp_response(resp, self.cfg.limits.max_response_bytes)
