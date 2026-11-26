"""SQLite state: change cursor, per-conversation cursors, cmd_id journal, pending acks, devices, vault."""
from __future__ import annotations

import contextlib
import hashlib
import os
import secrets
import sqlite3
import threading
import time

# ---- schema versioning -------------------------------------------------------------------------
# ``meta.schema_version`` holds the version. A database without that row but with a ``meta`` table is
# a protocol-v1 database (version 1). Every migration runs in one transaction; an existing database is
# copied to ``<path>.v<from>.bak`` (sqlite backup API) before the first migration.
SCHEMA_VERSION = 2

_V1 = [
    "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)",
    """CREATE TABLE IF NOT EXISTS conv (
        key TEXT PRIMARY KEY,            -- 'lxmf:<peer>' or 'rrc:<hub>:<room>'
        fingerprint TEXT NOT NULL,
        change_cursor INTEGER NOT NULL,  -- server cursor value at last observed change
        last_id INTEGER NOT NULL DEFAULT 0  -- highest MeshChatX message id / RRC seq seen by the bridge
    )""",
    "CREATE INDEX IF NOT EXISTS conv_cursor ON conv(change_cursor)",
    """CREATE TABLE IF NOT EXISTS journal (
        phone TEXT NOT NULL, cmd_id TEXT NOT NULL, ts REAL NOT NULL,
        created REAL NOT NULL, response BLOB,
        PRIMARY KEY (phone, cmd_id)
    )""",
    """CREATE TABLE IF NOT EXISTS pending (
        cmd_id TEXT PRIMARY KEY, phone TEXT NOT NULL, lxmf_hash TEXT NOT NULL,
        peer TEXT NOT NULL, state TEXT, created REAL NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS pending_hash ON pending(lxmf_hash)",
    "INSERT OR IGNORE INTO meta(k, v) VALUES('cursor', '0')",
]

_V2 = [
    """CREATE TABLE devices (
        device_id TEXT PRIMARY KEY,         -- identity hash, 32 hex
        public_key TEXT NOT NULL UNIQUE,    -- 128 hex
        name TEXT NOT NULL, platform TEXT NOT NULL,
        roles TEXT NOT NULL DEFAULT '',     -- comma separated
        bootstrap INTEGER NOT NULL DEFAULT 0,
        added_by TEXT NOT NULL, added_at REAL NOT NULL,
        last_seen REAL, revoked_at REAL, revoked_by TEXT, revoke_reason TEXT
    )""",
    """CREATE TABLE device_keys (
        device_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL, wrapped BLOB NOT NULL, updated_at REAL NOT NULL
    )""",
    "CREATE TABLE pair_nonces (nonce TEXT PRIMARY KEY, used_at REAL NOT NULL, device_id TEXT NOT NULL)",
    """CREATE TABLE outbound (
        lxmf_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL, cmd_id TEXT NOT NULL,
        peer TEXT NOT NULL, created REAL NOT NULL
    )""",
    """CREATE TABLE vault_blobs (
        vcursor INTEGER PRIMARY KEY AUTOINCREMENT,
        blob_id TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL, seq INTEGER NOT NULL, key_epoch INTEGER NOT NULL,
        size INTEGER NOT NULL, sha256 TEXT NOT NULL, ts REAL NOT NULL, data BLOB NOT NULL
    )""",
    "CREATE UNIQUE INDEX vault_dev_seq ON vault_blobs(device_id, seq)",
]


def device_id_of_pubkey(public_key_hex: str) -> str:
    """RNS identity hash (truncated SHA-256 of the 64-byte public key) as 32 hex chars."""
    return hashlib.sha256(bytes.fromhex(public_key_hex)).digest()[:16].hex()


def _migrate_1(db) -> None:
    for stmt in _V1:
        db.execute(stmt)


def _migrate_2(db) -> None:
    for stmt in _V2:
        db.execute(stmt)
    # v1 keyed journal/pending by the phone's full public key; v2 keys them by device_id
    for table in ("journal", "pending"):
        for (phone,) in db.execute(f"SELECT DISTINCT phone FROM {table}").fetchall():
            if len(phone) == 128:
                db.execute(f"UPDATE {table} SET phone=? WHERE phone=?", (device_id_of_pubkey(phone), phone))
    db.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('state_id', ?)", (secrets.token_hex(8),))
    db.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('vault_epoch', '1')")
    db.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('vault_keys_epoch', '0')")


MIGRATIONS = {1: _migrate_1, 2: _migrate_2}


class SchemaTooNew(Exception):
    pass


def schema_version(db) -> int:
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'").fetchone() is None:
        return 0
    row = db.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()
    return int(row[0]) if row else 1


TERMINAL_STATES = frozenset({"delivered", "rejected", "cancelled", "failed"})


class State:
    def __init__(self, path: str = ":memory:", clock=time.time):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._lock = threading.RLock()
        self._clock = clock
        self._tx_depth = 0
        self.migrated_from: int | None = None
        with self._lock:
            if path != ":memory:":
                self._db.execute("PRAGMA journal_mode=WAL")
            self._migrate(path)

    def _migrate(self, path: str) -> None:
        current = schema_version(self._db)
        if current > SCHEMA_VERSION:
            self._db.close()
            raise SchemaTooNew(f"state database has schema version {current}, this bridge supports "
                               f"up to {SCHEMA_VERSION}: refusing to run")
        if current == SCHEMA_VERSION:
            return
        if current > 0:
            self.migrated_from = current
            if path != ":memory:" and os.path.exists(path):
                bak = sqlite3.connect(f"{path}.v{current}.bak")
                try:
                    self._db.backup(bak)
                finally:
                    bak.close()
        for v in range(current + 1, SCHEMA_VERSION + 1):
            self._db.execute("BEGIN IMMEDIATE")
            try:
                MIGRATIONS[v](self._db)
                self._db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('schema_version', ?)", (str(v),))
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # ---- generic helpers ------------------------------------------------------------------------
    @contextlib.contextmanager
    def transaction(self):
        """Re-entrant write transaction (only the outermost level begins and commits)."""
        with self._lock:
            outer = self._tx_depth == 0
            if outer:
                self._db.execute("BEGIN IMMEDIATE")
            self._tx_depth += 1
            try:
                yield self
            except BaseException:
                self._tx_depth -= 1
                if outer:
                    self._db.execute("ROLLBACK")
                raise
            self._tx_depth -= 1
            if outer:
                self._db.execute("COMMIT")

    def execute(self, sql: str, params=()) -> int:
        with self._lock:
            return self._db.execute(sql, params).rowcount

    def query(self, sql: str, params=()) -> list[tuple]:
        with self._lock:
            return self._db.execute(sql, params).fetchall()

    def meta_get(self, key: str, default: str | None = None) -> str | None:
        rows = self.query("SELECT v FROM meta WHERE k=?", (key,))
        return rows[0][0] if rows else default

    def meta_set(self, key: str, value: str) -> None:
        self.execute("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", (key, value))

    def state_id(self) -> str:
        """Random id of this state database. A client MUST drop all its cursors when it changes."""
        return self.meta_get("state_id") or ""

    # ---- change cursor / conversations -------------------------------------------------
    def cursor(self) -> int:
        with self._lock:
            return int(self._db.execute("SELECT v FROM meta WHERE k='cursor'").fetchone()[0])

    def _bump(self) -> int:
        n = self.cursor() + 1
        self._db.execute("UPDATE meta SET v=? WHERE k='cursor'", (str(n),))
        return n

    def touch_conv(self, key: str, fingerprint: str, force: bool = False) -> bool:
        """Record the observed state of a conversation; returns True when it changed."""
        with self._lock:
            row = self._db.execute("SELECT fingerprint FROM conv WHERE key=?", (key,)).fetchone()
            if row is not None and row[0] == fingerprint and not force:
                return False
            n = self._bump()
            if row is None:
                self._db.execute("INSERT INTO conv(key, fingerprint, change_cursor) VALUES(?,?,?)",
                                 (key, fingerprint, n))
            else:
                self._db.execute("UPDATE conv SET fingerprint=?, change_cursor=? WHERE key=?",
                                 (fingerprint, n, key))
            return True

    def convs_since(self, cursor: int, prefix: str, limit: int) -> tuple[list[str], bool]:
        """Keys (oldest change first) with change_cursor > cursor; second item: more rows exist."""
        with self._lock:
            rows = self._db.execute(
                "SELECT key FROM conv WHERE change_cursor>? AND key LIKE ? ORDER BY change_cursor LIMIT ?",
                (cursor, prefix + "%", limit + 1),
            ).fetchall()
        keys = [r[0] for r in rows]
        return keys[:limit], len(keys) > limit

    def conv_cursor(self, key: str) -> int:
        with self._lock:
            row = self._db.execute("SELECT change_cursor FROM conv WHERE key=?", (key,)).fetchone()
        return row[0] if row else 0

    def set_last_id(self, key: str, last_id: int) -> None:
        with self._lock:
            self._db.execute("UPDATE conv SET last_id=MAX(last_id, ?) WHERE key=?", (last_id, key))

    def get_last_id(self, key: str) -> int:
        with self._lock:
            row = self._db.execute("SELECT last_id FROM conv WHERE key=?", (key,)).fetchone()
        return row[0] if row else 0

    # ---- cmd_id journal (anti-replay / idempotency); ``phone`` is the device_id ---------------
    def journal_reserve(self, phone: str, cmd_id: str, ts: float) -> bool:
        """Atomically claim ``cmd_id``. Returns False if it was already used (replay/duplicate)."""
        with self._lock:
            cur = self._db.execute(
                "INSERT OR IGNORE INTO journal(phone, cmd_id, ts, created) VALUES(?,?,?,?)",
                (phone, cmd_id, ts, self._clock()),
            )
            return cur.rowcount == 1

    def journal_store(self, phone: str, cmd_id: str, response: bytes) -> None:
        with self._lock:
            self._db.execute("UPDATE journal SET response=? WHERE phone=? AND cmd_id=?", (response, phone, cmd_id))

    def journal_release(self, phone: str, cmd_id: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM journal WHERE phone=? AND cmd_id=?", (phone, cmd_id))

    def journal_get(self, phone: str, cmd_id: str) -> bytes | None:
        with self._lock:
            row = self._db.execute("SELECT response FROM journal WHERE phone=? AND cmd_id=?", (phone, cmd_id)).fetchone()
        return bytes(row[0]) if row and row[0] is not None else None

    def journal_prune(self, ttl: float) -> int:
        with self._lock:
            cur = self._db.execute("DELETE FROM journal WHERE created < ?", (self._clock() - ttl,))
            return cur.rowcount

    # ---- pending acks: cmd_id -> LXMF hash of A's message ----------------------------------
    def pending_put(self, cmd_id: str, phone: str, lxmf_hash: str, peer: str, state: str | None) -> None:
        with self._lock:
            self._db.execute(
                "INSERT OR REPLACE INTO pending(cmd_id, phone, lxmf_hash, peer, state, created) VALUES(?,?,?,?,?,?)",
                (cmd_id, phone, lxmf_hash, peer, state, self._clock()),
            )

    def pending_by_hash(self, lxmf_hash: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT cmd_id, phone, lxmf_hash, peer, state FROM pending WHERE lxmf_hash=?", (lxmf_hash,)
            ).fetchone()
        return dict(zip(("cmd_id", "phone", "lxmf_hash", "peer", "state"), row)) if row else None

    def pending_all(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT cmd_id, phone, lxmf_hash, peer, state FROM pending").fetchall()
        return [dict(zip(("cmd_id", "phone", "lxmf_hash", "peer", "state"), r)) for r in rows]

    def pending_update(self, lxmf_hash: str, state: str) -> None:
        with self._lock:
            if state in TERMINAL_STATES:
                self._db.execute("DELETE FROM pending WHERE lxmf_hash=?", (lxmf_hash,))
            else:
                self._db.execute("UPDATE pending SET state=? WHERE lxmf_hash=?", (state, lxmf_hash))

    def pending_prune(self, ttl: float) -> int:
        with self._lock:
            cur = self._db.execute("DELETE FROM pending WHERE created < ?", (self._clock() - ttl,))
            return cur.rowcount

    # ---- origin device of messages sent through the bridge (permanent) ---------------------------
    def outbound_put(self, lxmf_hash: str, device_id: str, cmd_id: str, peer: str) -> None:
        self.execute("INSERT OR REPLACE INTO outbound(lxmf_hash, device_id, cmd_id, peer, created) VALUES(?,?,?,?,?)",
                     (lxmf_hash, device_id, cmd_id, peer, self._clock()))

    def outbound_get_many(self, hashes: list[str]) -> dict[str, tuple[str, str]]:
        """lxmf_hash -> (device_id, cmd_id) for the hashes the bridge sent."""
        out: dict[str, tuple[str, str]] = {}
        for i in range(0, len(hashes), 500):
            chunk = hashes[i:i + 500]
            rows = self.query(
                f"SELECT lxmf_hash, device_id, cmd_id FROM outbound WHERE lxmf_hash IN ({','.join('?' * len(chunk))})",
                chunk)
            out.update({h: (d, c) for h, d, c in rows})
        return out
