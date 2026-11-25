"""Entry point: ``python -m kestrel_bridge --config /path/to/bridge.toml``."""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import sys
import time

from . import __version__
from .config import Config, ConfigError, load_config

log = logging.getLogger("kestrel")
DEFAULT_CONFIG = os.environ.get("KESTREL_CONFIG", "/sidecar/config/bridge.toml")
MIN_RNS_CONFIG = """[reticulum]
  enable_transport = No
  share_instance = Yes
  instance_name = default

[interfaces]
"""


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="kestrel-bridge", description="Kestrel bridge sidecar for MeshChatX")
    p.add_argument("--config", default=DEFAULT_CONFIG, help="path to bridge.toml (default: %(default)s)")
    p.add_argument("--check-config", action="store_true", help="validate the config and exit")
    p.add_argument("--print-address", action="store_true",
                   help="print the public address of S (destination hash and public key) and exit")
    p.add_argument("--healthcheck", action="store_true", help="exit 0 if the running bridge is healthy")
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
    print(f"config OK: {len(cfg.whitelist)} whitelisted phone key(s), MeshChatX at {cfg.meshchatx.base_url}")
    return 0


def cmd_print_address(cfg: Config) -> int:
    import RNS
    from .rpc import destination_hash
    ident = load_or_create_identity(cfg.rns.identity_path)
    print("bridge destination (kestrel.bridge):", destination_hash(ident).hex())
    print("bridge lxmf.delivery destination:   ", RNS.Destination.hash(ident, "lxmf", "delivery").hex())
    print("bridge public key (hex):            ", ident.get_public_key().hex())
    return 0


def cmd_healthcheck(cfg: Config) -> int:
    try:
        age = time.time() - os.path.getmtime(cfg.health_path)
    except OSError:
        return 1
    return 0 if age < 90 else 1


async def _run(cfg: Config) -> None:
    import RNS
    from .lxmf_commands import LxmfCommands
    from .meshchatx_client import MeshChatXClient
    from .push import PushHub
    from .rpc import PathProfile, RpcServer
    from .service import Service
    from .state import State
    from .ws_events import WsEvents
    from .errors import BridgeError

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()

    def request_stop(*_):
        loop.call_soon_threadsafe(stop.set)

    os.makedirs(cfg.state_dir, exist_ok=True)
    state = State(cfg.db_path)
    client = MeshChatXClient(cfg.meshchatx)
    service = Service(cfg, client, state)

    log.info("kestrel-bridge %s starting; waiting for MeshChatX", __version__)
    await client.wait_ready()
    while not await service.recheck_compat() and not stop.is_set():
        if client.version is not None and not client._version_ok(client.version):
            break  # incompatible: keep running degraded, the periodic check below will retry
        await asyncio.sleep(10)
    try:
        await service.refresh(force=True)
    except BridgeError as e:
        log.warning("initial index refresh failed: %s", e.code)

    # attach to the existing shared instance; never become one
    os.makedirs(cfg.rns.config_dir, exist_ok=True)
    cfg_file = os.path.join(cfg.rns.config_dir, "config")
    if not os.path.exists(cfg_file):
        with open(cfg_file, "w", encoding="utf-8") as f:
            f.write(MIN_RNS_CONFIG)
    ret = None
    while ret is None and not stop.is_set():
        try:
            ret = RNS.Reticulum(configdir=cfg.rns.config_dir, loglevel=cfg.rns.log_level,
                                require_shared_instance=True)
            if not ret.is_connected_to_shared_instance:
                raise SystemError("not connected to a shared instance")
        except (SystemError, OSError) as e:
            log.error("cannot attach to the Reticulum shared instance: %s; retrying", e)
            ret = None
            await asyncio.sleep(10)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    identity = load_or_create_identity(cfg.rns.identity_path)
    os.makedirs(cfg.rns.lxmf_storage, exist_ok=True)
    push = PushHub(cfg, profile_of=PathProfile(cfg))
    service.push = push
    lxmf = LxmfCommands(cfg, identity, service, state, loop)
    push.offline_send = lxmf.push
    rpc = RpcServer(cfg, identity, service, push, loop)
    rpc.start()
    ws = WsEvents(client, service.on_event, service.on_resync)

    async def compat_loop():
        while True:
            await asyncio.sleep(300)
            await service.recheck_compat()

    async def housekeeping():
        n = 0
        while True:
            if ws.connected:
                try:
                    with open(cfg.health_path, "w", encoding="utf-8") as f:
                        f.write(str(time.time()))
                except OSError:
                    pass
            if n % 240 == 0:  # hourly
                state.journal_prune(cfg.limits.journal_ttl)
                state.pending_prune(cfg.limits.journal_ttl)
            n += 1
            await asyncio.sleep(15)

    tasks = [asyncio.create_task(t) for t in (ws.run(), compat_loop(), housekeeping())]
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
        if args.healthcheck:
            return cmd_healthcheck(cfg)
        _setup_logging(cfg.log_level)
        cfg.meshchatx.read_password()
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
