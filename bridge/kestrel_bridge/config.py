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


RNS_MODES = ("standalone", "shared")
PUSH_PROFILES = ("auto", "full", "constrained")


@dataclass
class RnsConfig:
    """Reticulum settings.

    ``standalone`` (default): the bridge runs its own Reticulum instance (not a transport node,
    ``share_instance = No``) with one TCPClientInterface to ``tcp_host:tcp_port`` and writes the RNS
    config itself. ``shared``: attach to the shared instance of another process (``rpc_key`` etc. live
    in that instance's config, see README).
    """
    mode: str = "standalone"
    config_dir: str = "/sidecar/.reticulum"
    identity_path: str = "/sidecar/storage/identity"
    lxmf_storage: str = "/sidecar/storage/lxmf"
    announce_interval: int = 1800
    announce_lxmf: bool = False
    log_level: int = 2
    # RNS >= 1.6 proof-of-work "stamps". Off by default: on a small CPU the announce stamp never
    # finishes and the announce is never emitted (see README). The three sub-options default to ``stamps``.
    stamps: bool = False
    stamp_destinations: bool = False   # stamp our own announces
    stamp_path_requests: bool = False  # stamp the path requests we emit
    stamp_link_requests: bool = False  # stamp the link requests we emit
    # standalone only
    tcp_host: str | None = "meshchatx"
    tcp_port: int = 4242
    ifac_name: str | None = None
    ifac_passphrase_file: str | None = None
    # shared only
    require_shared_instance: bool = True

    def read_ifac_passphrase(self) -> str | None:
        if not self.ifac_passphrase_file:
            return None
        try:
            value = Path(self.ifac_passphrase_file).read_text(encoding="utf-8").strip("\r\n")
        except OSError as e:
            raise ConfigError(f"cannot read rns.ifac_passphrase_file: {e.strerror}") from None
        if not value:
            raise ConfigError("rns.ifac_passphrase_file is empty")
        return value


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
    # protocol v2: devices, pairing, read state
    max_devices: int = 16                  # trusted (non-revoked) devices
    pairing_window: int = 600              # seconds: accepted |now - ts| of a pairing QR payload
    device_admin_rate_per_minute: int = 20   # /devices/approve|rename|set_role|revoke per device
    mark_read_rate_per_minute: int = 60
    # protocol v2: vault (opaque ciphertext storage)
    vault_max_blob_bytes: int = 131072
    vault_device_quota_bytes: int = 64 * 1024 * 1024
    vault_total_quota_bytes: int = 512 * 1024 * 1024
    vault_put_rate_per_minute: int = 120
    vault_get_max_ids: int = 32


@dataclass
class PushConfig:
    profile: str = "auto"                 # auto | full | constrained (override)
    unknown_profile: str = "constrained"  # auto: profile when the transport to the phone is unknown
    full_max_rtt: float = 1.5             # standalone auto: Link RTT (seconds) must be below this for "full"
    full_min_link_mtu: int = 1000         # standalone auto: Link MTU (bytes) must be at least this for "full"
    fast_interfaces: tuple[str, ...] = DEFAULT_FAST_INTERFACES
    lxmf_offline_push: bool = True
    offline_push_max_per_hour: int = 30
    propagation_node: str | None = None  # hex destination hash of an LXMF propagation node


@dataclass
class DeviceSeed:
    """A bootstrap device from ``[[devices]]`` (or the deprecated ``[whitelist]``)."""
    public_key: str          # 128 hex chars
    name: str
    platform: str = "unknown"
    roles: tuple[str, ...] = ()


@dataclass
class Config:
    meshchatx: MeshChatXConfig
    devices: tuple[DeviceSeed, ...]
    state_dir: str = "/sidecar/state"
    rns: RnsConfig = field(default_factory=RnsConfig)
    limits: Limits = field(default_factory=Limits)
    push: PushConfig = field(default_factory=PushConfig)
    log_level: str = "INFO"
    warnings: tuple[str, ...] = ()   # config deprecations, logged by the entry point

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


def rns_config_value(what: str, value: str) -> str:
    """Quote ``value`` for the RNS (configobj) config file; refuse what cannot be written safely."""
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ConfigError(f"{what} must not contain control characters")
    if '"' not in value:
        return f'"{value}"'
    if "'" not in value:
        return f"'{value}'"
    raise ConfigError(f"{what} must not contain both ' and \"")


def _norm_pubkey(what: str, k) -> str:
    if not isinstance(k, str):
        raise ConfigError(f"{what} must be a hex string")
    k = k.strip().lower()
    if len(k) != PUBKEY_HEX_LEN or any(c not in "0123456789abcdef" for c in k):
        raise ConfigError(f"{what} must be {PUBKEY_HEX_LEN} hex chars (full 64-byte public key)")
    return k


def _parse_devices(raw: dict) -> tuple[list[DeviceSeed], list[str]]:
    """``[[devices]]`` (protocol v2) plus the deprecated ``[whitelist] phone_public_keys`` (bootstrap devices)."""
    from .devices import device_id_of, validate_name, validate_platform, validate_roles
    from .errors import BridgeError
    seeds: list[DeviceSeed] = []
    seen: set[str] = set()
    warnings: list[str] = []
    entries = raw.get("devices")
    if entries is not None:
        if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
            raise ConfigError("devices must be an array of tables ([[devices]])")
        for i, e in enumerate(entries):
            _check_unknown(f"devices[{i}]", e, {"public_key", "name", "platform", "roles"})
            key = _norm_pubkey(f"devices[{i}].public_key", e.get("public_key"))
            if key in seen:
                raise ConfigError(f"devices[{i}].public_key is listed twice")
            seen.add(key)
            try:
                name = validate_name(e.get("name", f"device-{device_id_of(key)[:6]}"))
                platform = validate_platform(e.get("platform", "unknown"))
                roles = validate_roles(e.get("roles", []))
            except BridgeError as ex:
                raise ConfigError(f"devices[{i}]: {ex.message}") from None
            seeds.append(DeviceSeed(key, name, platform, roles))
    w = raw.get("whitelist")
    if w is not None:
        if not isinstance(w, dict):
            raise ConfigError("[whitelist] must be a table")
        _check_unknown("whitelist", w, {"phone_public_keys"})
        keys = w.get("phone_public_keys")
        if not isinstance(keys, list):
            raise ConfigError("whitelist.phone_public_keys must be a list")
        warnings.append("[whitelist] phone_public_keys is deprecated: use [[devices]] (public_key, name, platform, "
                        "roles); its keys are loaded as bootstrap devices")
        for k in keys:
            k = _norm_pubkey("whitelist key", k)
            if k not in seen:
                seen.add(k)
                seeds.append(DeviceSeed(k, f"device-{device_id_of(k)[:6]}"))
    if not seeds:
        raise ConfigError("configure at least one bootstrap device: [[devices]] (or the deprecated "
                          "[whitelist] phone_public_keys)")
    return seeds, warnings


def parse_config(raw: dict) -> Config:
    _check_unknown("root", raw, {"state_dir", "log_level", "meshchatx", "whitelist", "devices", "rns", "limits", "push"})

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

    seeds, warnings = _parse_devices(raw)

    r = _table(raw, "rns")
    _check_unknown("rns", r, {"mode", "config_dir", "identity_path", "lxmf_storage", "announce_interval",
                              "announce_lxmf", "log_level", "tcp_host", "tcp_port", "ifac_name",
                              "ifac_passphrase_file", "require_shared_instance", "stamps", "stamp_destinations",
                              "stamp_path_requests", "stamp_link_requests"})
    d = RnsConfig()
    stamps = _bool("rns", r, "stamps", d.stamps)
    mode = _str("rns", r, "mode", d.mode)
    if mode not in RNS_MODES:
        raise ConfigError("rns.mode must be 'standalone' or 'shared'")
    if mode == "standalone":
        if "require_shared_instance" in r:
            raise ConfigError('rns.require_shared_instance only applies to rns.mode = "shared"')
        tcp_port = _int("rns", r, "tcp_port", d.tcp_port)
        if tcp_port > 65535:
            raise ConfigError("rns.tcp_port must be 1..65535")
        tcp_host = _str("rns", r, "tcp_host", d.tcp_host)
        if any(c.isspace() for c in tcp_host):
            raise ConfigError("rns.tcp_host must be a host name or IP address")
        ifac_name = _str("rns", r, "ifac_name", None)
        ifac_pf = _str("rns", r, "ifac_passphrase_file", None)
        if ifac_name is not None:
            rns_config_value("rns.ifac_name", ifac_name)
        if "'" in tcp_host or '"' in tcp_host:
            raise ConfigError("rns.tcp_host must be a host name or IP address")
    else:
        for k in ("tcp_host", "tcp_port", "ifac_name", "ifac_passphrase_file"):
            if k in r:
                raise ConfigError(f"rns.{k} only applies to rns.mode = \"standalone\"")
        tcp_host, tcp_port, ifac_name, ifac_pf = d.tcp_host, d.tcp_port, None, None
    rns = RnsConfig(
        mode=mode,
        config_dir=_str("rns", r, "config_dir", d.config_dir),
        identity_path=_str("rns", r, "identity_path", d.identity_path),
        lxmf_storage=_str("rns", r, "lxmf_storage", d.lxmf_storage),
        announce_interval=_int("rns", r, "announce_interval", d.announce_interval, 5),
        announce_lxmf=_bool("rns", r, "announce_lxmf", d.announce_lxmf),
        log_level=_int("rns", r, "log_level", d.log_level, 0),
        stamps=stamps,
        stamp_destinations=_bool("rns", r, "stamp_destinations", stamps),
        stamp_path_requests=_bool("rns", r, "stamp_path_requests", stamps),
        stamp_link_requests=_bool("rns", r, "stamp_link_requests", stamps),
        tcp_host=tcp_host,
        tcp_port=tcp_port,
        ifac_name=ifac_name,
        ifac_passphrase_file=ifac_pf,
        require_shared_instance=_bool("rns", r, "require_shared_instance", True),
    )
    if mode == "shared" and not rns.require_shared_instance:
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
        max_devices=_int("limits", li, "max_devices", dl.max_devices),
        pairing_window=_int("limits", li, "pairing_window", dl.pairing_window, 30),
        device_admin_rate_per_minute=_int("limits", li, "device_admin_rate_per_minute",
                                          dl.device_admin_rate_per_minute),
        mark_read_rate_per_minute=_int("limits", li, "mark_read_rate_per_minute", dl.mark_read_rate_per_minute),
        vault_max_blob_bytes=_int("limits", li, "vault_max_blob_bytes", dl.vault_max_blob_bytes, 1024),
        vault_device_quota_bytes=_int("limits", li, "vault_device_quota_bytes", dl.vault_device_quota_bytes, 1024),
        vault_total_quota_bytes=_int("limits", li, "vault_total_quota_bytes", dl.vault_total_quota_bytes, 1024),
        vault_put_rate_per_minute=_int("limits", li, "vault_put_rate_per_minute", dl.vault_put_rate_per_minute),
        vault_get_max_ids=_int("limits", li, "vault_get_max_ids", dl.vault_get_max_ids),
    )
    if limits.pairing_window > 600:
        raise ConfigError("limits.pairing_window must be at most 600 seconds")
    if len(seeds) > limits.max_devices:
        raise ConfigError("more bootstrap devices than limits.max_devices")
    if limits.journal_ttl <= limits.lxmf_ts_window:
        raise ConfigError("limits.journal_ttl must exceed limits.lxmf_ts_window (otherwise replays slip through)")

    p = _table(raw, "push")
    _check_unknown("push", p, {"profile", "unknown_profile", "full_max_rtt", "full_min_link_mtu", "fast_interfaces",
                               "lxmf_offline_push", "offline_push_max_per_hour", "propagation_node"})
    prof = _str("push", p, "profile", "auto")
    if prof not in PUSH_PROFILES:
        raise ConfigError("push.profile must be 'auto', 'full' or 'constrained'")
    up = _str("push", p, "unknown_profile", "constrained")
    if up not in ("full", "constrained"):
        raise ConfigError("push.unknown_profile must be 'full' or 'constrained'")
    pn = _str("push", p, "propagation_node", None)
    if pn is not None and (len(pn) != 32 or any(c not in "0123456789abcdef" for c in pn.lower())):
        raise ConfigError("push.propagation_node must be a 32-char hex destination hash")
    push = PushConfig(
        profile=prof,
        unknown_profile=up,
        full_max_rtt=_num("push", p, "full_max_rtt", 1.5, 0.05),
        full_min_link_mtu=_int("push", p, "full_min_link_mtu", 1000, 100),
        fast_interfaces=_strlist("push", p, "fast_interfaces", DEFAULT_FAST_INTERFACES),
        lxmf_offline_push=_bool("push", p, "lxmf_offline_push", True),
        offline_push_max_per_hour=_int("push", p, "offline_push_max_per_hour", 30),
        propagation_node=pn.lower() if pn else None,
    )

    level = str(raw.get("log_level", "INFO")).upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise ConfigError("log_level must be DEBUG, INFO, WARNING or ERROR")
    state_dir = _str("root", raw, "state_dir", "/sidecar/state")
    return Config(meshchatx=mc, devices=tuple(seeds), state_dir=state_dir, rns=rns, limits=limits, push=push,
                  log_level=level, warnings=tuple(warnings))


def load_config(path: str) -> Config:
    try:
        with open(path, "rb") as f:
            raw = tomllib.load(f)
    except OSError as e:
        raise ConfigError(f"cannot read config: {e.strerror}") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"invalid TOML: {e}") from None
    return parse_config(raw)
