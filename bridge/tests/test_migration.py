"""State schema versioning and the v1 -> v2 migration."""
import glob
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

from kestrel_bridge import state as state_mod
from kestrel_bridge.state import SCHEMA_VERSION, SchemaTooNew, State, device_id_of_pubkey
from tests.helpers import OTHER_KEY, PHONE_KEY

# The schema exactly as protocol v1 (bridge <= 0.3.x) created it.
V1_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS conv (
    key TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    change_cursor INTEGER NOT NULL,
    last_id INTEGER NOT NULL DEFAULT 0
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


def make_v1_db(path: str) -> None:
    db = sqlite3.connect(path)
    db.executescript(V1_SCHEMA)
    db.execute("INSERT INTO meta(k, v) VALUES('cursor', '41')")
    db.execute("INSERT INTO conv VALUES('lxmf:" + "aa" * 16 + "', 'fp', 40, 17)")
    db.execute("INSERT INTO conv VALUES('lxmf:" + "bb" * 16 + "', 'fp2', 41, 3)")
    db.execute("INSERT INTO journal VALUES(?, 'cmd-old-0001', 1.0, 2.0, ?)", (PHONE_KEY, b"cached-response"))
    db.execute("INSERT INTO journal VALUES(?, 'cmd-old-0002', 1.0, 2.0, NULL)", (OTHER_KEY,))
    db.execute("INSERT INTO pending VALUES('cmd-old-0001', ?, ?, ?, 'sent', 2.0)", (PHONE_KEY, "h1" * 16, "aa" * 16))
    db.commit()
    db.close()


class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "bridge.sqlite3")

    def version(self):
        db = sqlite3.connect(self.path)
        try:
            return int(db.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()[0])
        finally:
            db.close()

    def test_fresh_database_is_current(self):
        s = State(self.path)
        self.addCleanup(s.close)
        self.assertEqual(s.migrated_from, None)
        self.assertEqual(self.version(), SCHEMA_VERSION)
        self.assertEqual((s.cursor(), len(s.state_id())), (0, 16))
        self.assertEqual(s.meta_get("vault_epoch"), "1")
        self.assertEqual(s.meta_get("vault_keys_epoch"), "0")
        tables = {r[0] for r in s.query("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue({"devices", "device_keys", "pair_nonces", "outbound", "vault_blobs", "conv", "journal",
                         "pending", "meta"} <= tables)

    def test_v1_state_is_migrated_and_keeps_its_data(self):
        make_v1_db(self.path)
        s = State(self.path)
        self.addCleanup(s.close)
        self.assertEqual(s.migrated_from, 1)
        self.assertEqual(self.version(), 2)
        # cursors and conversations survive: devices keep their cursors valid across the upgrade
        self.assertEqual(s.cursor(), 41)
        self.assertEqual(s.conv_cursor("lxmf:" + "aa" * 16), 40)
        self.assertEqual(s.get_last_id("lxmf:" + "aa" * 16), 17)
        keys, more = s.convs_since(40, "", 10)
        self.assertEqual((keys, more), (["lxmf:" + "bb" * 16], False))
        # journal and pending were keyed by the phone's public key and are now keyed by its device_id
        pid, oid = device_id_of_pubkey(PHONE_KEY), device_id_of_pubkey(OTHER_KEY)
        self.assertFalse(s.journal_reserve(pid, "cmd-old-0001", 1.0))      # replay protection survives
        self.assertEqual(s.journal_get(pid, "cmd-old-0001"), b"cached-response")
        self.assertFalse(s.journal_reserve(oid, "cmd-old-0002", 1.0))
        self.assertTrue(s.journal_reserve(PHONE_KEY, "cmd-old-0001", 1.0))  # the old key-based rows are gone
        p = s.pending_by_hash("h1" * 16)
        self.assertEqual((p["phone"], p["cmd_id"], p["state"]), (pid, "cmd-old-0001", "sent"))
        self.assertEqual(s.query("SELECT COUNT(*) FROM devices")[0][0], 0)  # bootstrap devices come from the config

    def test_backup_of_the_old_database_is_kept(self):
        make_v1_db(self.path)
        State(self.path).close()
        baks = glob.glob(self.path + ".v1.bak")
        self.assertEqual(len(baks), 1)
        db = sqlite3.connect(baks[0])
        self.assertIsNone(db.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone())   # still v1
        self.assertEqual(db.execute("SELECT v FROM meta WHERE k='cursor'").fetchone()[0], "41")
        db.close()

    def test_migration_is_idempotent_and_keeps_state_id(self):
        make_v1_db(self.path)
        s = State(self.path)
        sid = s.state_id()
        s.close()
        s = State(self.path)
        self.addCleanup(s.close)
        self.assertEqual((s.migrated_from, s.state_id(), s.cursor()), (None, sid, 41))
        self.assertEqual(len(glob.glob(self.path + ".*.bak")), 1)           # no second backup

    def test_failed_migration_rolls_back_completely(self):
        make_v1_db(self.path)

        def broken(db):
            state_mod._migrate_2(db)
            raise RuntimeError("disk full")
        with mock.patch.dict(state_mod.MIGRATIONS, {2: broken}):
            with self.assertRaises(RuntimeError):
                State(self.path)
        db = sqlite3.connect(self.path)
        self.assertIsNone(db.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone())
        self.assertIsNone(db.execute("SELECT name FROM sqlite_master WHERE name='devices'").fetchone())
        self.assertEqual(db.execute("SELECT phone FROM journal WHERE cmd_id='cmd-old-0001'").fetchone()[0], PHONE_KEY)
        db.close()
        State(self.path).close()                                            # and the next start migrates fine
        self.assertEqual(self.version(), 2)

    def test_newer_schema_is_refused(self):
        State(self.path).close()
        db = sqlite3.connect(self.path)
        db.execute("UPDATE meta SET v='99' WHERE k='schema_version'")
        db.commit()
        db.close()
        with self.assertRaises(SchemaTooNew):
            State(self.path)

    def test_in_memory_state(self):
        s = State()
        self.addCleanup(s.close)
        self.assertEqual(s.meta_get("schema_version"), str(SCHEMA_VERSION))

    def test_transactions_are_reentrant_and_roll_back(self):
        s = State()
        self.addCleanup(s.close)
        with self.assertRaises(RuntimeError):
            with s.transaction():
                s.meta_set("x", "1")
                with s.transaction():
                    s.meta_set("y", "2")
                raise RuntimeError
        self.assertEqual((s.meta_get("x"), s.meta_get("y")), (None, None))
        with s.transaction():
            with s.transaction():
                s.meta_set("x", "1")
        self.assertEqual(s.meta_get("x"), "1")


if __name__ == "__main__":
    unittest.main()
