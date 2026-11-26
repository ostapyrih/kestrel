"""RNS Link RPC: destination ``kestrel.bridge`` on identity S, identify()-based authorization."""
from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import threading

import RNS

from . import codec, errors
from .config import Config
from .push import FULL, CONSTRAINED, PushHub, Subscriber, classify_interface, classify_link
from .rns_setup import AnnounceWatcher, tcp_client_interfaces
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


def phone_of(identity, whitelist) -> str | None:
    """Return the whitelisted full public key (hex) of ``identity`` or None."""
    if identity is None:
        return None
    try:
        key = identity.get_public_key().hex()
    except Exception:
        return None
    return key if key in whitelist else None


class PathProfile:
    """Maps a phone to 'full'/'constrained' using the path table of the shared instance (RPC)."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._hashes: dict[str, bytes] = {}

    def __call__(self, phone: str) -> str | None:
        try:
            dh = self._hashes.get(phone)
            if dh is None:
                dh = RNS.Destination.hash(identity_from_public_key(phone), "lxmf", "delivery")
                self._hashes[phone] = dh
            name = RNS.Reticulum.get_instance().get_next_hop_if_name(dh)
        except Exception as e:  # RPC key mismatch, instance gone, ...
            log.debug("next-hop lookup failed: %s", type(e).__name__)
            return None
        if not name or name == "None":
            return None
        return FULL if classify_interface(name, self.cfg.push.fast_interfaces) else CONSTRAINED


class LinkProfile:
    """Standalone mode: profile of a phone from the measured RTT/MTU of its current Link.

    ``link_of(phone)`` returns the phone's active Link (or None). No access to any path table needed.
    """

    def __init__(self, cfg: Config, link_of):
        self.cfg = cfg
        self.link_of = link_of

    def __call__(self, phone: str) -> str | None:
        link = self.link_of(phone)
        if link is None:
            return None
        return classify_link(getattr(link, "rtt", None), getattr(link, "mtu", None),
                             self.cfg.push.full_max_rtt, self.cfg.push.full_min_link_mtu)


class _LinkState:
    def __init__(self, link):
        self.link = link
        self.phone: str | None = None
        self.sub: Subscriber | None = None

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
        self.whitelist = frozenset(cfg.whitelist)
        self.destination: RNS.Destination | None = None
        self._links: dict[bytes, _LinkState] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._announcer: AnnounceWatcher | None = None

    # ---- lifecycle ---------------------------------------------------------------------------
    def start(self) -> None:
        d = RNS.Destination(self.identity, RNS.Destination.IN, RNS.Destination.SINGLE, APP_NAME, ASPECT)
        for path in PATHS:
            # authorization is done in the handler (the whitelist is checked against the full public key)
            d.register_request_handler(path, self._make_handler(path), allow=RNS.Destination.ALLOW_ALL)
        d.set_link_established_callback(self._link_established)
        self.destination = d
        # standalone: announce on start, every announce_interval and after every TCP reconnect;
        # shared: periodic only (the shared instance owns the interface)
        watch = tcp_client_interfaces if self.cfg.rns.mode == "standalone" else None
        self._announcer = AnnounceWatcher(lambda: d.announce(), watch, self.cfg.rns.announce_interval)
        self._announcer.start()
        log.info("RPC destination %s ready", RNS.prettyhexrep(d.hash))

    def active_link(self, phone: str):
        """The most recent active Link of an identified phone, or None."""
        with self._lock:
            states = list(self._links.values())
        for st in reversed(states):
            if st.phone == phone and st.link.status == RNS.Link.ACTIVE:
                return st.link
        return None

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
        if st is not None and st.phone is None and link.status == RNS.Link.ACTIVE:
            log.info("link did not identify in time, closing")
            link.teardown()

    def _remote_identified(self, link, identity) -> None:
        phone = phone_of(identity, self.whitelist)
        if phone is None:
            log.warning("link identified with a key outside the whitelist (identity %s), closing",
                        RNS.prettyhexrep(identity.hash))
            link.teardown()
            return
        st = self._links.get(link.link_id)
        if st is not None:
            st.phone = phone
        log.info("phone linked (identity %s)", RNS.prettyhexrep(identity.hash))

    def _link_closed(self, link) -> None:
        with self._lock:
            st = self._links.pop(link.link_id, None)
        if st is not None and st.sub is not None:
            self.push.unsubscribe(st.sub)

    # ---- requests ------------------------------------------------------------------------------------
    def _make_handler(self, path_name: str):
        def handler(path, data, request_id, link_id, remote_identity, requested_at):
            return self._handle(path, data, link_id, remote_identity)
        return handler

    def _handle(self, path: str, data, link_id: bytes, remote_identity) -> dict:
        phone = phone_of(remote_identity, self.whitelist)
        if phone is None:
            return codec.err(errors.UNAUTHORIZED, "identify() with a whitelisted key first")
        st = self._links.get(link_id)
        if st is None:
            return codec.err(errors.INTERNAL, "unknown link")

        def subscribe(topics, hint):
            if st.sub is not None:
                self.push.unsubscribe(st.sub)
            st.sub = Subscriber(phone, st.send, topics, hint)
            self.push.subscribe(st.sub)
            return {"topics": sorted(st.sub.topics), "profile": self.push.effective_profile(st.sub),
                    "mdu": st.link.get_mdu()}

        if data is not None and not isinstance(data, dict):
            return codec.err(errors.BAD_REQUEST, "request must be a map")
        forced = self.cfg.push.profile if self.cfg.push.profile != "auto" else None
        ctx = Ctx(phone=phone, transport="link", subscribe=subscribe,
                  profile=forced or self.push.profile_of(phone))
        fut = asyncio.run_coroutine_threadsafe(self.service.dispatch(path, data, ctx), self.loop)
        try:
            resp = fut.result(timeout=self.cfg.limits.rpc_timeout)
        except (concurrent.futures.TimeoutError, TimeoutError):
            fut.cancel()
            return codec.err(errors.UPSTREAM_UNAVAILABLE, "request timed out")
        return codec.clamp_response(resp, self.cfg.limits.max_response_bytes)
