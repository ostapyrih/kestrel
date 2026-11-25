"""TOML configuration loading and validation."""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

PUBKEY_HEX_LEN = 128  # RNS public key: 32 bytes X25519 + 32 bytes Ed25519
DEFAULT_FAST_INTERFACES = (
    "TCPInterface",
    "TCPClientInterface",
    "TCPServerInterface",
    "BackboneInterface",
    "BackboneClientInterface",
)


class ConfigError(Exception):
    pass


@dataclass
class MeshChatXConfig:
    base_url: str
    password_file: str | None = None
    password_env: str | None = None
    allowed_versions: tuple[str, ...] = ("4.12.",)
    allowed_api_versions: tuple[int, ...] = (2,)
    request_timeout: float = 20.0
    send_timeout: float = 60.0
    login_backoff_base: float = 2.0
    login_backoff_max: float = 300.0

    def read_password(self) -> str:
        if self.password_file:
            try:
                value = Path(self.password_file).read_text(encoding="utf-8").strip("\r\n")
            except OSError as e:
                raise ConfigError(f"cannot read meshchatx.password_file: {e.strerror}") from None
        else:
            value = os.environ.get(self.password_env or "", "")
        if not value:
            raise ConfigError("MeshChatX password is empty")
        return value


@dataclass
class RnsConfig:
    config_dir: str = "/sidecar/.reticulum"
    identity_path: str = "/sidecar/storage/identity"
    lxmf_storage: str = "/sidecar/storage/lxmf"
    announce_interval: int = 1800
    announce_lxmf: bool = False
    require_shared_instance: bool = True
    log_level: int = 2


@dataclass
class Limits:
    max_text_bytes: int = 4096
    max_request_bytes: int = 65536
    max_response_bytes: int = 262144
    lxmf_max_response_bytes: int = 8192
    constrained_max_text_bytes: int = 160
    page_max: int = 100
    lxmf_ts_window: int = 86400
    journal_ttl: int = 7 * 86400
    send_rate_per_minute: int = 30
    identify_timeout: int = 30
    rpc_timeout: float = 90.0


@dataclass
class PushConfig:
    unknown_profile: str = "constrained"  # profile when the path to the phone is unknown
    fast_interfaces: tuple[str, ...] = DEFAULT_FAST_INTERFACES
    lxmf_offline_push: bool = True
    offline_push_max_per_hour: int = 30
    propagation_node: str | None = None  # hex destination hash of an LXMF propagation node


@dataclass
class Config:
    meshchatx: MeshChatXConfig
    whitelist: tuple[str, ...]
    state_dir: str = "/sidecar/state"
    rns: RnsConfig = field(default_factory=RnsConfig)
    limits: Limits = field(default_factory=Limits)
    push: PushConfig = field(default_factory=PushConfig)
    log_level: str = "INFO"

    @property
    def db_path(self) -> str:
        return os.path.join(self.state_dir, "bridge.sqlite3")

    @property
    def health_path(self) -> str:
        return os.path.join(self.state_dir, "health")


def _table(d: dict, key: str, required: bool = False) -> dict:
    v = d.get(key)
    if v is None:
        if required:
            raise ConfigError(f"missing section [{key}]")
        return {}
    if not isinstance(v, dict):
        raise ConfigError(f"[{key}] must be a table")
    return v


def _check_unknown(section: str, d: dict, allowed: set) -> None:
    extra = set(d) - allowed
    if extra:
        raise ConfigError(f"unknown key(s) in [{section}]: {', '.join(sorted(extra))}")


def _int(section: str, d: dict, key: str, default: int, minimum: int = 1) -> int:
    v = d.get(key, default)
    if isinstance(v, bool) or not isinstance(v, int) or v < minimum:
        raise ConfigError(f"{section}.{key} must be an integer >= {minimum}")
    return v


def _num(section: str, d: dict, key: str, default: float, minimum: float = 0.1) -> float:
    v = d.get(key, default)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < minimum:
        raise ConfigError(f"{section}.{key} must be a number >= {minimum}")
    return float(v)


def _bool(section: str, d: dict, key: str, default: bool) -> bool:
    v = d.get(key, default)
    if not isinstance(v, bool):
        raise ConfigError(f"{section}.{key} must be a boolean")
    return v


def _str(section: str, d: dict, key: str, default: str | None) -> str | None:
    v = d.get(key, default)
    if v is not None and (not isinstance(v, str) or not v):
        raise ConfigError(f"{section}.{key} must be a non-empty string")
    return v


def _strlist(section: str, d: dict, key: str, default: tuple) -> tuple:
    v = d.get(key, list(default))
    if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
        raise ConfigError(f"{section}.{key} must be a list of strings")
    return tuple(v)


def parse_config(raw: dict) -> Config:
    _check_unknown("root", raw, {"state_dir", "log_level", "meshchatx", "whitelist", "rns", "limits", "push"})

    m = _table(raw, "meshchatx", required=True)
    _check_unknown(
        "meshchatx",
        m,
        {
            "base_url", "password_file", "password_env", "allowed_versions", "allowed_api_versions",
            "request_timeout", "send_timeout", "login_backoff_base", "login_backoff_max",
        },
    )
    base_url = _str("meshchatx", m, "base_url", None)
    if not base_url:
        raise ConfigError("meshchatx.base_url is required")
    u = urlparse(base_url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ConfigError("meshchatx.base_url must be an http(s) URL")
    if u.username or u.password:
        raise ConfigError("meshchatx.base_url must not contain credentials")
    pf = _str("meshchatx", m, "password_file", None)
    pe = _str("meshchatx", m, "password_env", None)
    if (pf is None) == (pe is None):
        raise ConfigError("set exactly one of meshchatx.password_file / meshchatx.password_env")
    api_versions = m.get("allowed_api_versions", [2])
    if not isinstance(api_versions, list) or not api_versions or not all(isinstance(x, int) for x in api_versions):
        raise ConfigError("meshchatx.allowed_api_versions must be a non-empty list of integers")
    mc = MeshChatXConfig(
        base_url=base_url.rstrip("/"),
        password_file=pf,
        password_env=pe,
        allowed_versions=_strlist("meshchatx", m, "allowed_versions", ("4.12.",)),
        allowed_api_versions=tuple(api_versions),
        request_timeout=_num("meshchatx", m, "request_timeout", 20.0),
        send_timeout=_num("meshchatx", m, "send_timeout", 60.0),
        login_backoff_base=_num("meshchatx", m, "login_backoff_base", 2.0),
        login_backoff_max=_num("meshchatx", m, "login_backoff_max", 300.0),
    )

    w = _table(raw, "whitelist", required=True)
    _check_unknown("whitelist", w, {"phone_public_keys"})
    keys = w.get("phone_public_keys")
    if not isinstance(keys, list) or not keys:
        raise ConfigError("whitelist.phone_public_keys must be a non-empty list")
    norm = []
    for k in keys:
        if not isinstance(k, str):
            raise ConfigError("whitelist.phone_public_keys entries must be hex strings")
        k = k.strip().lower()
        if len(k) != PUBKEY_HEX_LEN or any(c not in "0123456789abcdef" for c in k):
            raise ConfigError(f"whitelist key must be {PUBKEY_HEX_LEN} hex chars (full 64-byte public key)")
        if k not in norm:
            norm.append(k)

    r = _table(raw, "rns")
    _check_unknown("rns", r, {"config_dir", "identity_path", "lxmf_storage", "announce_interval", "announce_lxmf",
                              "require_shared_instance", "log_level"})
    d = RnsConfig()
    rns = RnsConfig(
        config_dir=_str("rns", r, "config_dir", d.config_dir),
        identity_path=_str("rns", r, "identity_path", d.identity_path),
        lxmf_storage=_str("rns", r, "lxmf_storage", d.lxmf_storage),
        announce_interval=_int("rns", r, "announce_interval", d.announce_interval, 5),
        announce_lxmf=_bool("rns", r, "announce_lxmf", d.announce_lxmf),
        require_shared_instance=_bool("rns", r, "require_shared_instance", True),
        log_level=_int("rns", r, "log_level", d.log_level, 0),
    )
    if not rns.require_shared_instance:
        raise ConfigError("rns.require_shared_instance must stay true (the sidecar must never become the shared instance)")

    li = _table(raw, "limits")
    _check_unknown("limits", li, set(Limits.__dataclass_fields__))
    dl = Limits()
    limits = Limits(
        max_text_bytes=_int("limits", li, "max_text_bytes", dl.max_text_bytes),
        max_request_bytes=_int("limits", li, "max_request_bytes", dl.max_request_bytes, 256),
        max_response_bytes=_int("limits", li, "max_response_bytes", dl.max_response_bytes, 1024),
        lxmf_max_response_bytes=_int("limits", li, "lxmf_max_response_bytes", dl.lxmf_max_response_bytes, 256),
        constrained_max_text_bytes=_int("limits", li, "constrained_max_text_bytes", dl.constrained_max_text_bytes, 16),
        page_max=_int("limits", li, "page_max", dl.page_max),
        lxmf_ts_window=_int("limits", li, "lxmf_ts_window", dl.lxmf_ts_window, 10),
        journal_ttl=_int("limits", li, "journal_ttl", dl.journal_ttl, 60),
        send_rate_per_minute=_int("limits", li, "send_rate_per_minute", dl.send_rate_per_minute),
        identify_timeout=_int("limits", li, "identify_timeout", dl.identify_timeout),
        rpc_timeout=_num("limits", li, "rpc_timeout", dl.rpc_timeout),
    )
    if limits.journal_ttl <= limits.lxmf_ts_window:
        raise ConfigError("limits.journal_ttl must exceed limits.lxmf_ts_window (otherwise replays slip through)")

    p = _table(raw, "push")
    _check_unknown("push", p, {"unknown_profile", "fast_interfaces", "lxmf_offline_push",
                               "offline_push_max_per_hour", "propagation_node"})
    up = _str("push", p, "unknown_profile", "constrained")
    if up not in ("full", "constrained"):
        raise ConfigError("push.unknown_profile must be 'full' or 'constrained'")
    pn = _str("push", p, "propagation_node", None)
    if pn is not None and (len(pn) != 32 or any(c not in "0123456789abcdef" for c in pn.lower())):
        raise ConfigError("push.propagation_node must be a 32-char hex destination hash")
    push = PushConfig(
        unknown_profile=up,
        fast_interfaces=_strlist("push", p, "fast_interfaces", DEFAULT_FAST_INTERFACES),
        lxmf_offline_push=_bool("push", p, "lxmf_offline_push", True),
        offline_push_max_per_hour=_int("push", p, "offline_push_max_per_hour", 30),
        propagation_node=pn.lower() if pn else None,
    )

    level = str(raw.get("log_level", "INFO")).upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise ConfigError("log_level must be DEBUG, INFO, WARNING or ERROR")
    state_dir = _str("root", raw, "state_dir", "/sidecar/state")
    return Config(meshchatx=mc, whitelist=tuple(norm), state_dir=state_dir, rns=rns, limits=limits, push=push,
                  log_level=level)


def load_config(path: str) -> Config:
    try:
        with open(path, "rb") as f:
            raw = tomllib.load(f)
    except OSError as e:
        raise ConfigError(f"cannot read config: {e.strerror}") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"invalid TOML: {e}") from None
    return parse_config(raw)
