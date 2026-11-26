# Kestrel app

Flutter client for Reticulum/LXMF. Phase 3b: **Standalone mode** (identity B, the phone), with a
data model that is ready for the bridge (Phase 4).

* `lib/storage` - SQLite schema per `docs/PLAN.md` section 4 with a migrations list. Switching
  `settings.bridge_enabled` never deletes chats or messages (tested, and no delete path exists).
* `lib/node` - `NodeService`: Reticulum over `TcpClientInterface` (default `rns.ostapyrih.com:4242`,
  editable in settings), the `LxmRouter` from `packages/kestrel_rns`, every state transition written
  to `messages` + `delivery_log`. Identity B's private key lives only in the platform keystore.
* `lib/screens` - chats list (account chips, identity badges, connection indicator), chat detail
  (sender / route / transport / status per message, details sheet with timeline), new chat,
  settings (display name, server, address, public key + QR, stored bridge toggle).
* `lib/l10n` - Ukrainian (default) and English strings.

Tests: `flutter test` (DB, NodeService with in-memory interfaces, widgets). Tests tagged
`integration` start `tools/it/lxmf_peer.py` (needs `tools/.venv`, skipped otherwise).
Screenshots: `KESTREL_SCREENSHOTS=1 FLUTTER_ROOT=<sdk> flutter test test/screenshots_test.dart`
writes `docs/screenshots/*.png`.

Deferred: QR scanning of addresses, background service, bridge (A) features, propagation.
