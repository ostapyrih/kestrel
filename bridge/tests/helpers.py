"""Shared test helpers."""
from __future__ import annotations

import copy

from aiohttp.test_utils import TestServer

from kestrel_bridge.config import parse_config
from kestrel_bridge.devices import DeviceRegistry
from kestrel_bridge.state import State, device_id_of_pubkey

PHONE_KEY = "ab" * 64     # fake 64-byte public key (hex)
OTHER_KEY = "cd" * 64
PHONE_ID = device_id_of_pubkey(PHONE_KEY)
OTHER_ID = device_id_of_pubkey(OTHER_KEY)
PEER = "11" * 16


def raw_config(**over) -> dict:
    raw = {
        "state_dir": ".",
        "meshchatx": {"base_url": "http://127.0.0.1:1", "password_env": "KESTREL_TEST_PASSWORD",
                      "login_backoff_base": 1.0, "login_backoff_max": 8.0},
        "devices": [{"public_key": PHONE_KEY, "name": "phone-1", "platform": "android"}],
        "push": {"unknown_profile": "full"},
    }
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(raw.get(k), dict):
            raw[k].update(v)
        else:
            raw[k] = v
    return parse_config(copy.deepcopy(raw))


async def start_fake(fake, cfg_over=None):
    """Start the fake MeshChatX and return (server, config pointing at it)."""
    server = TestServer(fake.app)
    await server.start_server()
    url = f"http://127.0.0.1:{server.port}"
    cfg = raw_config(meshchatx={"base_url": url, **(cfg_over or {})})
    return server, cfg


class FakeClock:
    def __init__(self, t: float = 1000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


def make_registry(cfg, state=None, clock=None):
    """(state, registry) with the config's bootstrap devices loaded."""
    state = state or State()
    reg = DeviceRegistry(state, cfg.limits.max_devices, *([clock] if clock else []))
    reg.sync_bootstrap(cfg.devices)
    return state, reg


class RealDevice:
    """A device with a real RNS identity (can sign / be signed to)."""

    def __init__(self):
        import RNS
        self.identity = RNS.Identity()
        self.public_key = self.identity.get_public_key().hex()
        self.device_id = device_id_of_pubkey(self.public_key)

    def sign(self, message: bytes) -> bytes:
        return self.identity.sign(message)
