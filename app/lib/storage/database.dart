import 'dart:async';

import 'package:sqflite/sqflite.dart';

/// One schema migration. [version] is the `PRAGMA user_version` the database
/// has after [statements] ran.
class Migration {
  const Migration(this.version, this.statements);
  final int version;
  final List<String> statements;
}

/// Schema per docs/PLAN.md section 4.
///
/// Rules that must hold for every future migration:
///  * Switching bridge mode changes `settings.bridge_enabled`. Turning the
///    bridge off additionally drops account A (a cache of MeshChatX) through
///    the one method `Repo.purgeBridgeAccountData`; account B (this device)
///    is never deleted by a mode switch. Only the user can delete chats, via
///    `Repo.deleteChats` (rows of the chats' own account), the bridge's
///    `chat_deleted` via `Repo.applyChatDeleted` (account A) and
///    `Repo.removeVaultHistory` (read-only histories of other devices).
///  * `outbox.sender_identity` and `outbox.route` are frozen when the row is
///    created (enforced by triggers).
const List<Migration> migrations = [
  Migration(1, [
    '''
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''',
    // A = remote bridge identity (placeholder row until Phase 4), B = local.
    '''
CREATE TABLE accounts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  identity TEXT NOT NULL UNIQUE CHECK (identity IN ('A', 'B')),
  kind TEXT NOT NULL CHECK (kind IN ('remote', 'local')),
  label TEXT NOT NULL,
  address_hash TEXT,
  display_name TEXT
)''',
    '''
CREATE TABLE chats (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  kind TEXT NOT NULL CHECK (kind IN ('lxmf', 'rrc')),
  peer_hash TEXT,
  room_id TEXT,
  title TEXT,
  last_ts INTEGER,
  unread INTEGER NOT NULL DEFAULT 0,
  CHECK (peer_hash IS NOT NULL OR room_id IS NOT NULL)
)''',
    'CREATE UNIQUE INDEX chats_peer ON chats(account_id, kind, peer_hash) '
        'WHERE peer_hash IS NOT NULL',
    'CREATE UNIQUE INDEX chats_room ON chats(account_id, kind, room_id) '
        'WHERE room_id IS NOT NULL',
    '''
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  chat_id INTEGER NOT NULL REFERENCES chats(id),
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  lxmf_hash TEXT,
  text TEXT NOT NULL,
  title TEXT,
  ts INTEGER NOT NULL,
  sender_identity TEXT NOT NULL CHECK (sender_identity IN ('A', 'B')),
  route TEXT CHECK (route IN
    ('direct', 'opportunistic', 'propagated', 'via_bridge')),
  transport TEXT NOT NULL DEFAULT 'none'
    CHECK (transport IN ('tcp', 'lora', 'none')),
  status TEXT NOT NULL,
  error TEXT,
  signature_valid INTEGER
)''',
    'CREATE INDEX messages_chat ON messages(chat_id, ts)',
    'CREATE UNIQUE INDEX messages_hash ON messages(account_id, lxmf_hash) '
        'WHERE lxmf_hash IS NOT NULL',
    '''
CREATE TABLE outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id INTEGER NOT NULL REFERENCES messages(id),
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  chat_id INTEGER NOT NULL REFERENCES chats(id),
  sender_identity TEXT NOT NULL CHECK (sender_identity IN ('A', 'B')),
  route TEXT NOT NULL CHECK (route IN
    ('direct', 'opportunistic', 'propagated', 'via_bridge')),
  destination_hash TEXT NOT NULL,
  lxmf_hash TEXT,
  packed BLOB,
  attempts INTEGER NOT NULL DEFAULT 0,
  state INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'blocked_bridge_off', 'done')),
  created_ts INTEGER NOT NULL
)''',
    // sender_identity and route are fixed when the message is queued.
    '''
CREATE TRIGGER outbox_frozen BEFORE UPDATE OF sender_identity, route ON outbox
WHEN NEW.sender_identity IS NOT OLD.sender_identity
  OR NEW.route IS NOT OLD.route
BEGIN
  SELECT RAISE(ABORT, 'outbox sender_identity and route are frozen');
END''',
    '''
CREATE TABLE delivery_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id INTEGER NOT NULL REFERENCES messages(id),
  stage TEXT NOT NULL,
  ts INTEGER NOT NULL,
  detail TEXT
)''',
    'CREATE INDEX delivery_log_msg ON delivery_log(message_id, ts)',
    "INSERT INTO settings(key, value) VALUES ('bridge_enabled', '0')",
  ]),
  // Peers learned from announces (new chat suggestions).
  Migration(2, [
    '''
CREATE TABLE peers (
  hash TEXT PRIMARY KEY,
  display_name TEXT,
  stamp_cost REAL,
  hops INTEGER,
  last_seen INTEGER NOT NULL
)''',
  ]),
  // Bridge mode (account A, protocol v2): per-chat cursors, origin device,
  // command ids, the device registry cache and RRC rooms. All of it is a
  // cache of the bridge and is purged when the bridge is turned off.
  Migration(3, [
    'ALTER TABLE chats ADD COLUMN bridge_last_id INTEGER',
    'ALTER TABLE chats ADD COLUMN bridge_older_done INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE messages ADD COLUMN origin_device TEXT',
    'ALTER TABLE messages ADD COLUMN bridge_id INTEGER',
    'ALTER TABLE messages ADD COLUMN cmd_id TEXT',
    'CREATE UNIQUE INDEX messages_cmd ON messages(account_id, cmd_id) '
        'WHERE cmd_id IS NOT NULL',
    'ALTER TABLE outbox ADD COLUMN cmd_id TEXT',
    '''
CREATE TABLE bridge_devices (
  device_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT,
  roles TEXT NOT NULL DEFAULT '',
  bootstrap INTEGER NOT NULL DEFAULT 0,
  added_at REAL,
  last_seen REAL,
  revoked_at REAL,
  online INTEGER NOT NULL DEFAULT 0
)''',
    '''
CREATE TABLE rrc_rooms (
  hub TEXT NOT NULL,
  hub_name TEXT,
  room TEXT NOT NULL,
  unread INTEGER NOT NULL DEFAULT 0,
  mention INTEGER NOT NULL DEFAULT 0,
  connected INTEGER,
  PRIMARY KEY (hub, room)
)''',
    '''
CREATE TABLE rrc_messages (
  hub TEXT NOT NULL,
  room TEXT NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT,
  nick TEXT,
  text TEXT NOT NULL,
  ts INTEGER NOT NULL,
  mention INTEGER NOT NULL DEFAULT 0,
  src TEXT,
  PRIMARY KEY (hub, room, seq)
)''',
  ]),
  // Standalone history vault (protocol 9, Phase 4b). `vault_chats` and
  // `vault_messages` hold the read-only histories of the user's OTHER
  // devices (a cache of the bridge vault, dropped when the bridge is turned
  // off). They are separate tables on purpose: `accounts`, `messages.sender_
  // identity` and the outbox triggers only know this device's A and B, and
  // remote histories must never be sendable. `vault_seen`, `vault_upload`
  // and `vault_pending` are bookkeeping of the sync itself.
  Migration(4, [
    '''
CREATE TABLE vault_chats (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  peer_hash TEXT NOT NULL,
  peer_name TEXT,
  last_ts INTEGER,
  UNIQUE (device_id, peer_hash)
)''',
    '''
CREATE TABLE vault_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id INTEGER NOT NULL REFERENCES vault_chats(id),
  device_id TEXT NOT NULL,
  lxmf_hash TEXT NOT NULL,
  direction TEXT NOT NULL,
  title TEXT,
  text TEXT NOT NULL,
  ts INTEGER NOT NULL,
  rts REAL NOT NULL,
  status TEXT NOT NULL,
  route TEXT,
  transport TEXT NOT NULL DEFAULT 'none',
  error TEXT,
  UNIQUE (device_id, lxmf_hash)
)''',
    'CREATE INDEX vault_messages_chat ON vault_messages(chat_id, ts)',
    // highest blob seq applied per remote device (continuity check)
    '''
CREATE TABLE vault_seen (
  device_id TEXT PRIMARY KEY,
  last_seq INTEGER NOT NULL
)''',
    // what of this device's own B messages was uploaded, in which state;
    // `gen` changes when the bridge database was recreated
    '''
CREATE TABLE vault_upload (
  message_id INTEGER PRIMARY KEY,
  gen INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error TEXT,
  lxmf_hash TEXT
)''',
    // the one blob being uploaded: persisted BEFORE the put, so a retry
    // sends the very same blob_id/seq/ciphertext (idempotent)
    '''
CREATE TABLE vault_pending (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  blob_id TEXT,
  seq INTEGER,
  key_epoch INTEGER,
  ciphertext BLOB,
  marks TEXT
)''',
  ]),
  // Chat deletion (docs/bridge-protocol.md 9.5, kind `delete_chat`).
  // `vault_tombstones` persists an applied deletion "the history of device
  // `device_id` with this peer is gone up to `before_ts`" (also for this
  // device's own chat): a vault re-download skips records that old. It
  // survives turning the bridge off. `vault_delete_out` queues `delete_chat`
  // blobs to upload (`owner_device` null = this device's own chat, else the
  // read-only chat of that other device); the uploader sends them in order.
  Migration(5, [
    '''
CREATE TABLE vault_tombstones (
  device_id TEXT NOT NULL,
  peer_hash TEXT NOT NULL,
  before_ts INTEGER NOT NULL,
  PRIMARY KEY (device_id, peer_hash)
)''',
    '''
CREATE TABLE vault_delete_out (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  peer_hash TEXT NOT NULL,
  owner_device TEXT,
  before_ts INTEGER NOT NULL
)''',
  ]),
  // NomadNet browser (Phase N): nodes learned from announces (or visited by
  // address), bookmarks, visit history and the page cache (#!c= expiry).
  Migration(6, [
    '''
CREATE TABLE nomad_nodes (
  hash TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  hops INTEGER,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  announced INTEGER NOT NULL DEFAULT 0,
  favourite INTEGER NOT NULL DEFAULT 0,
  identify INTEGER NOT NULL DEFAULT 0
)''',
    '''
CREATE TABLE nomad_bookmarks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL
)''',
    '''
CREATE TABLE nomad_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  ts INTEGER NOT NULL
)''',
    'CREATE INDEX nomad_history_ts ON nomad_history(ts)',
    '''
CREATE TABLE nomad_cache (
  url TEXT PRIMARY KEY,
  data BLOB NOT NULL,
  expires INTEGER NOT NULL
)''',
  ]),
  // Per-node page view preferences: pinch/menu zoom multiplier and "wrap
  // long lines" (structural lines wrap too).
  Migration(7, [
    'ALTER TABLE nomad_nodes ADD COLUMN font_scale REAL NOT NULL DEFAULT 1.0',
    'ALTER TABLE nomad_nodes ADD COLUMN wrap_all INTEGER NOT NULL DEFAULT 0',
  ]),
];

int get latestSchemaVersion => migrations.last.version;

/// Runs every migration with `version > from`.
Future<void> migrate(DatabaseExecutor db, int from, int to) async {
  for (final m in migrations) {
    if (m.version <= from || m.version > to) continue;
    for (final s in m.statements) {
      await db.execute(s);
    }
  }
}

/// Well known setting keys.
abstract final class SettingKeys {
  static const bridgeEnabled = 'bridge_enabled';
  static const displayName = 'display_name';
  static const serverHost = 'server_host';
  static const serverPort = 'server_port';
  static const deviceName = 'device_name';

  /// Identity (`A`/`B`) the new-chat screen preselects: the last one used.
  static const newChatIdentity = 'new_chat_identity';

  // Bridge (account A). The public key is the S identity; the cursor and the
  // state id belong together and are reset together.
  static const bridgePubkey = 'bridge_pubkey';
  static const bridgeStateId = 'bridge_state_id';
  static const bridgeCursor = 'bridge_cursor';
  static const bridgeLxmfFallback = 'bridge_lxmf_fallback';
  static const bridgeClockOffset = 'bridge_clock_offset';
  static const bridgeRevoked = 'bridge_revoked';
  static const bridgeOwnRoles = 'bridge_own_roles';

  // Vault sync. Cursor and downloaded histories are reset when the bridge is
  // turned off; the upload sequence, `vault_gen` and the key chain (secure
  // storage) belong to the pairing and survive.
  static const vaultCursor = 'vault_cursor';
  static const vaultLastSeq = 'vault_last_seq';
  static const vaultGen = 'vault_gen';
  static const vaultLastSync = 'vault_last_sync';
  static const vaultLastError = 'vault_last_error';
  static const vaultUsedBytes = 'vault_used_bytes';
  static const vaultQuotaBytes = 'vault_quota_bytes';
  static const vaultQuotaFull = 'vault_quota_full';
}

const defaultServerHost = 'rns.ostapyrih.com';
const defaultServerPort = 4242;

/// The app database: opens, migrates and notifies listeners about changes.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;
  final _changes = StreamController<void>.broadcast();

  /// Emits after every write through [Repo]-level helpers ([notify]).
  Stream<void> get changes => _changes.stream;

  void notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Opens (and migrates) the database at [path] with [factory]; use
  /// `inMemoryDatabasePath` for tests.
  static Future<AppDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: latestSchemaVersion,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, v) => migrate(d, 0, v),
        onUpgrade: (d, from, to) => migrate(d, from, to),
      ),
    );
    final a = AppDatabase._(db);
    await a._ensureAccounts();
    return a;
  }

  Future<void> _ensureAccounts() async {
    await db.insert('accounts', {
      'identity': 'B',
      'kind': 'local',
      'label': 'B',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('accounts', {
      'identity': 'A',
      'kind': 'remote',
      'label': 'A',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> close() async {
    await _changes.close();
    await db.close();
  }
}
