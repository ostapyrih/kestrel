"""Entry point: ``python -m kestrel_bridge --config /path/to/bridge.toml``."""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import time

from . import __version__
from .config import Config, ConfigError, load_config

log = logging.getLogger("kestrel")
DEFAULT_CONFIG = os.environ.get("KESTREL_CONFIG", "/sidecar/config/bridge.toml")
HEALTH_MAX_AGE = 90.0
ANNOUNCE_GRACE = 300.0   # seconds beyond announce_interval (or after start) before "announce not emitted"
EXIT_OK, EXIT_UNHEALTHY, EXIT_DEGRADED = 0, 1, 3


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="kestrel-bridge", description="Kestrel bridge sidecar for MeshChatX")
    p.add_argument("--config", default=DEFAULT_CONFIG, help="path to bridge.toml (default: %(default)s)")
    p.add_argument("--check-config", action="store_true", help="validate the config and exit")
    p.add_argument("--print-address", action="store_true",
                   help="print the public address of S (destination hash and public key) and exit")
    p.add_argument("--healthcheck", action="store_true",
                   help="exit 0 if the bridge process is alive (prints 'ok' or 'degraded: ...'); exit 1 if its "
                        "heartbeat is missing or stale")
    p.add_argument("--strict", action="store_true",
                   help="with --healthcheck: exit 3 instead of 0 when degraded (RNS interface or MeshChatX down)")
    p.add_argument("--list-devices", action="store_true",
                   help="print the device registry of the state database (device_id, name, platform, roles, "
                        "bootstrap, revoked) and exit")
    p.add_argument("--reinstate", metavar="DEVICE_ID",
                   help="operator recovery: clear 'revoked' of a device (also of a bootstrap device that is "
                        "listed in the config), then exit. Run it while the bridge is stopped")
    p.add_argument("--version", action="store_true")
    return p


def _setup_logging(level: str) -> None:
    logging.basicConfig(level=getattr(logging, level), format="%(asctime)s %(levelname)s %(name)s: %(message)s",
                        stream=sys.stdout)
    logging.getLogger("aiohttp").setLevel(logging.WARNING)


def load_or_create_identity(path: str):
    import RNS
    if os.path.exists(path):
        ident = RNS.Identity.from_file(path)
        if ident is None:
            raise SystemExit("identity file is unreadable")
        return ident
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    ident = RNS.Identity()
    ident.to_file(path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return ident


def cmd_check_config(cfg: Config) -> int:
    cfg.meshchatx.read_password()  # raises ConfigError when unreadable/empty; the value is never printed
    cfg.rns.read_ifac_passphrase()
    if cfg.rns.mode == "standalone":
        where = f"RNS standalone via TCP {cfg.rns.tcp_host}:{cfg.rns.tcp_port}"
    else:
        where = "RNS shared instance"
    for w in cfg.warnings:
        print(f"warning: {w}", file=sys.stderr)
    print(f"config OK: {len(cfg.devices)} bootstrap device(s), MeshChatX at {cfg.meshchatx.base_url}, {where}")
    return 0


def _open_registry(cfg: Config):
    from .devices import DeviceRegistry
    from .state import SchemaTooNew, State
    os.makedirs(cfg.state_dir, exist_ok=True)
    try:
        state = State(cfg.db_path)
    except SchemaTooNew as e:
        raise ConfigError(str(e)) from None
    return state, DeviceRegistry(state, cfg.limits.max_devices)


def cmd_list_devices(cfg: Config) -> int:
    state, registry = _open_registry(cfg)
    try:
        registry.sync_bootstrap(cfg.devices)
        for d in registry.all():
            flags = ",".join(x for x in ("bootstrap" if d.bootstrap else "", "revoked" if d.revoked else "",
                                         *d.roles) if x)
            print(f"{d.device_id}  {d.name!r:24} {d.platform:10} {flags}")
    finally:
        state.close()
    return 0


def cmd_reinstate(cfg: Config, device_id: str) -> int:
    state, registry = _open_registry(cfg)
    try:
        registry.sync_bootstrap(cfg.devices)
        dev = registry.get(device_id.lower())
        if dev is None:
            print(f"unknown device {device_id}", file=sys.stderr)
            return 2
        registry.reinstate(dev.device_id)
        print(f"device {dev.device_id} ({dev.name}) reinstated")
    finally:
        state.close()
    return 0


def cmd_print_address(cfg: Config) -> int:
    import RNS
    from .rpc import destination_hash
    ident = load_or_create_identity(cfg.rns.identity_path)
    print("bridge destination (kestrel.bridge):", destination_hash(ident).hex())
    print("bridge lxmf.delivery destination:   ", RNS.Destination.hash(ident, "lxmf", "delivery").hex())
    print("bridge public key (hex):            ", ident.get_public_key().hex())
    return 0


def cmd_healthcheck(cfg: Config, strict: bool = False) -> int:
    """Exit 0: alive (``ok`` or ``degraded``, so Docker does not flap while MeshChatX restarts);
    1: no fresh heartbeat (process stuck or not running); 3: degraded, only with ``--strict``."""
    try:
        age = time.time() - os.path.getmtime(cfg.health_path)
        with open(cfg.health_path, encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        print("unhealthy: no heartbeat")
        return EXIT_UNHEALTHY
    if age >= HEALTH_MAX_AGE:
        print("unhealthy: stale heartbeat")
        return EXIT_UNHEALTHY
    try:
        h = json.loads(raw)
    except ValueError:
        h = {}
    if not isinstance(h, dict):
        h = {}
    problems = []
    if h.get("rns_online") is False:
        problems.append("RNS interface offline")
    elif "started_at" in h:
        # online but our announce never reached the wire (typically: RNS stamping starved of CPU)
        last = h.get("last_announce_emitted_at")
        now = time.time()
        if isinstance(last, (int, float)):
            limit, since, what = cfg.rns.announce_interval + ANNOUNCE_GRACE, last, "announce not emitted"
        else:
            limit, since, what = ANNOUNCE_GRACE, h.get("started_at"), "announce never emitted"
        if isinstance(since, (int, float)) and now - since > limit:
            problems.append(f"{what} for > {int(limit // 60)} min" + (" (stamp pending)" if h.get("announce_pending") else ""))
    if h.get("meshchatx_reachable") is False:
        problems.append("MeshChatX unreachable")
    if problems:
        print("degraded: " + ", ".join(problems))
        return EXIT_DEGRADED if strict else EXIT_OK
    print("ok")
    return EXIT_OK


class LogThrottle:
    """Allow an action at most once per ``interval`` seconds."""

    def __init__(self, interval: float = 60.0, clock=time.monotonic):
        self.interval, self._clock, self._last = interval, clock, None

    def ready(self) -> bool:
        now = self._clock()
        if self._last is None or now - self._last >= self.interval:
            self._last = now
            return True
        return False


async def upstream_step(service, client, throttle: LogThrottle, wait_timeout: float = 30) -> float:
    """One iteration of the upstream loop; returns the delay before the next one."""
    from .errors import BridgeError
    if service.compat_ok:
        await service.recheck_compat()
        return 300
    try:
        await client.wait_ready(timeout=wait_timeout)
    except BridgeError:
        if throttle.ready():
            log.info("MeshChatX is not ready yet (waited %ss); compatibility check pending", wait_timeout)
        return 5
    if await service.recheck_compat():
        try:
            await service.refresh(force=True)
        except BridgeError as e:
            log.warning("initial index refresh failed: %s", e.code)
        return 300
    if client.version is None or client._version_ok(client.version):
        return 10   # not usable yet; an incompatible version is only re-checked slowly
    return 300


async def _run(cfg: Config) -> None:
    import RNS
    from .errors import BridgeError
    from .lxmf_commands import LxmfCommands
    from .meshchatx_client import MeshChatXClient
    from .push import PushHub
    from .rns_setup import interfaces_online, start_reticulum, tcp_client_interfaces
    from .rpc import LinkProfile, PathProfile, RpcServer
    from .service import Service
    from .devices import DeviceRegistry
    from .state import SchemaTooNew, State
    from .ws_events import WsEvents

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()

    def request_stop(*_):
        loop.call_soon_threadsafe(stop.set)

    os.makedirs(cfg.state_dir, exist_ok=True)
    try:
        state = State(cfg.db_path)
    except SchemaTooNew as e:
        raise SystemExit(f"error: {e}") from None
    if state.migrated_from is not None:
        log.info("state database migrated from schema version %d (backup kept next to it)", state.migrated_from)
    for w in cfg.warnings:
        log.warning("config: %s", w)
    registry = DeviceRegistry(state, cfg.limits.max_devices)
    seeded = registry.sync_bootstrap(cfg.devices)
    for did in seeded["added"]:
        log.info("bootstrap device %s added", did[:8])
    for did in seeded["removed"]:
        log.warning("device %s is no longer in the config: revoked", did[:8])
    if not registry.trusted_devices():
        log.warning("no trusted device: every bootstrap device is revoked (use --reinstate or add a new "
                    "[[devices]] entry)")
    client = MeshChatXClient(cfg.meshchatx)
    service = Service(cfg, client, state, registry=registry)

    log.info("kestrel-bridge %s starting (rns mode: %s)", __version__, cfg.rns.mode)

    # Reticulum does not depend on MeshChatX being up: in standalone mode RNS reconnects its TCP
    # interface by itself, so MeshChatX may start later or be recreated at any time.
    ret = None
    while ret is None and not stop.is_set():
        try:
            ret = start_reticulum(cfg.rns)
        except (SystemError, OSError) as e:
            if cfg.rns.mode == "standalone":
                raise
            log.error("cannot attach to the Reticulum shared instance: %s; retrying", e)
            ret = None
            await asyncio.sleep(10)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    identity = load_or_create_identity(cfg.rns.identity_path)
    os.makedirs(cfg.rns.lxmf_storage, exist_ok=True)
    push = PushHub(cfg, profile_of=PathProfile(cfg, registry), registry=registry)
    service.push = push
    lxmf = LxmfCommands(cfg, identity, service, state, loop)
    push.offline_send = lxmf.push
    rpc = RpcServer(cfg, identity, service, push, loop)
    push.link_online = rpc.has_link
    if cfg.rns.mode == "standalone":
        push.profile_of = LinkProfile(cfg, rpc.active_link)   # no path table access: use the Link's own RTT/MTU
    rpc.start()
    ws = WsEvents(client, service.on_event, service.on_resync)

    def rns_online() -> bool:
        if cfg.rns.mode == "standalone":
            return interfaces_online(tcp_client_interfaces())
        return bool(ret.is_connected_to_shared_instance)

    async def upstream_loop():
        """Wait for MeshChatX, check compatibility, index; re-check every 5 minutes (10 s until first success)."""
        throttle = LogThrottle()
        while True:
            await asyncio.sleep(await upstream_step(service, client, throttle))

    started_at = time.time()

    def write_health() -> None:
        h = {"ts": time.time(), "mode": cfg.rns.mode, "rns_online": rns_online(),
             "meshchatx_reachable": ws.connected, "compat_ok": service.compat_ok,
             "started_at": started_at, "stamping": bool(RNS.Transport.STAMP_DESTINATIONS),
             "announce_pending": rpc.announce_pending,
             "last_announce_emitted_at": rpc.last_announce_emitted_at}
        try:
            with open(cfg.health_path, "w", encoding="utf-8") as f:
                json.dump(h, f)
        except OSError:
            pass

    async def housekeeping():
        n = 0
        while True:
            write_health()   # heartbeat regardless of MeshChatX/RNS state (degraded is not dead)
            if n % 240 == 0:  # hourly
                state.journal_prune(cfg.limits.journal_ttl)
                state.pending_prune(cfg.limits.journal_ttl)
                state.execute("DELETE FROM pair_nonces WHERE used_at < ?", (time.time() - 2 * cfg.limits.pairing_window,))
            if n % 2 == 0 and push.subscribers() and service.compat_ok:
                try:     # notice reads done in the MeshChatX web UI and push read_state to the devices
                    await service.refresh()
                except BridgeError:
                    pass
            n += 1
            await asyncio.sleep(15)

    tasks = [asyncio.create_task(t) for t in (ws.run(), upstream_loop(), housekeeping())]
    log.info("bridge running")
    await stop.wait()
    log.info("shutting down")
    ws.stop()
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    rpc.stop()
    try:
        lxmf.router.exit_handler()
    except Exception:
        pass
    await client.close()
    state.close()
    try:
        RNS.Reticulum.exit_handler()
    except Exception:
        pass


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.version:
        print(f"kestrel-bridge {__version__}")
        return 0
    try:
        cfg = load_config(args.config)
        if args.check_config:
            return cmd_check_config(cfg)
        if args.print_address:
            return cmd_print_address(cfg)
        if args.list_devices:
            return cmd_list_devices(cfg)
        if args.reinstate:
            return cmd_reinstate(cfg, args.reinstate)
        if args.healthcheck:
            return cmd_healthcheck(cfg, args.strict)
        _setup_logging(cfg.log_level)
        cfg.meshchatx.read_password()
        cfg.rns.read_ifac_passphrase()
    except ConfigError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2
    try:
        asyncio.run(_run(cfg))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
