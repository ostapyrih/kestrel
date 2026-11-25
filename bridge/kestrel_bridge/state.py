"""SQLite state: change cursor, per-conversation cursors, cmd_id journal, pending acks."""
from __future__ import annotations

import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS conv (
    key TEXT PRIMARY KEY,            -- 'lxmf:<peer>' or 'rrc:<hub>:<room>'
    fingerprint TEXT NOT NULL,
    change_cursor INTEGER NOT NULL,  -- server cursor value at last observed change
    last_id INTEGER NOT NULL DEFAULT 0  -- highest MeshChatX message id / RRC seq seen by the bridge
);
CREATE INDEX IF NOT EXISTS conv_cursor ON conv(change_cursor);
CREATE TABLE IF NOT EXISTS journal (
    phone TEXT NOT NULL, cmd_id TEXT NOT NULL, ts REAL NOT NULL,
    created REAL NOT NULL, response BLOB,
    PRIMARY KEY (phone, cmd_id)
);
CREATE TABLE IF NOT EXISTS pending (
    cmd_id TEXT PRIMARY KEY, phone TEXT NOT NULL, lxmf_hash TEXT NOT NULL,
    peer TEXT NOT NULL, state TEXT, created REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS pending_hash ON pending(lxmf_hash);
"""

TERMINAL_STATES = frozenset({"delivered", "rejected", "cancelled", "failed"})


class State:
    def __init__(self, path: str = ":memory:", clock=time.time):
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._lock = threading.RLock()
        self._clock = clock
        with self._lock:
            if path != ":memory:":
                self._db.execute("PRAGMA journal_mode=WAL")
            self._db.executescript(SCHEMA)
            self._db.execute("INSERT OR IGNORE INTO meta(k, v) VALUES('cursor', '0')")

    def close(self) -> None:
        with self._lock:
            self._db.close()

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

    # ---- cmd_id journal (anti-replay / idempotency) ---------------------------------------
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
