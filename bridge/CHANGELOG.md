# Changelog

## [0.7.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.6.0...bridge-v0.7.0) (2026-11-27)


### Features

* delete chats on every device (own B, account A via MeshChatX, other devices' chats) ([#26](https://github.com/ostapyrih/kestrel/issues/26)) ([4ee6320](https://github.com/ostapyrih/kestrel/commit/4ee63205ab7e55269046b11616af60eee1e638f9))

## [0.6.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.5.0...bridge-v0.6.0) (2026-11-27)


### Features

* end-to-end encrypted history sync between devices (vault, Phase 4b) ([#24](https://github.com/ostapyrih/kestrel/issues/24)) ([d268021](https://github.com/ostapyrih/kestrel/commit/d268021dbf28168a2c5dd33285dd8ff5a66549ca))

## [0.5.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.4.1...bridge-v0.5.0) (2026-11-26)


### Features

* invite-QR pairing, app-owned device name, plain messenger when the bridge is off ([#22](https://github.com/ostapyrih/kestrel/issues/22)) ([c316067](https://github.com/ostapyrih/kestrel/commit/c316067f2c5a110ccc5b587d77f97f817a6c22ff))


### Bug Fixes

* **bridge:** tell rejected and revoked devices why their link is closed ([733b77f](https://github.com/ostapyrih/kestrel/commit/733b77f0e94bef5c3ab4a17bf99859ed79de0a9c))

## [0.4.1](https://github.com/ostapyrih/kestrel/compare/bridge-v0.4.0...bridge-v0.4.1) (2026-11-26)


### Bug Fixes

* **bridge:** report pending MeshChatX compat as unavailable, not incompatible ([b30a2b8](https://github.com/ostapyrih/kestrel/commit/b30a2b8f65f59a3ea005d005e370b535f1e3c0a4))

## [0.4.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.3.0...bridge-v0.4.0) (2026-11-26)


### ⚠ BREAKING CHANGES

* **bridge:** the wire protocol is now version 2 and v1 clients get protocol_mismatch. The config key [whitelist] is deprecated in favour of [[devices]] (still read as bootstrap devices). Clients and bridge must be upgraded together; the app has no bridge client yet, so there is no impact.

### Features

* **bridge:** protocol v2 with multi-device support ([dc577b5](https://github.com/ostapyrih/kestrel/commit/dc577b51c14c3edded37351bfba25bd0f6fee3be))


### Bug Fixes

* **bridge:** disable RNS announce/path-request stamping by default ([b63b383](https://github.com/ostapyrih/kestrel/commit/b63b3831941417b4c1e09ca98ef83769a3a412b2))

## [0.3.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.2.0...bridge-v0.3.0) (2026-11-26)


### Features

* **bridge:** standalone RNS mode with own Reticulum instance ([0032ef7](https://github.com/ostapyrih/kestrel/commit/0032ef7666c3b724016cd76ff5746dadb0b1b9e1))


### Bug Fixes

* **bridge:** follow-up announces after start and reconnect ([3c396e2](https://github.com/ostapyrih/kestrel/commit/3c396e21c198dda8d725dd95c161d8d7fb85ef37))


### Documentation

* **bridge:** document standalone and shared RNS modes, health and push profile ([406ab63](https://github.com/ostapyrih/kestrel/commit/406ab632d7ca435f6647375e93f2615987d5cea4))

## [0.2.0](https://github.com/ostapyrih/kestrel/compare/bridge-v0.1.0...bridge-v0.2.0) (2026-11-26)


### Features

* **bridge:** docker packaging, compose example and README ([be6b168](https://github.com/ostapyrih/kestrel/commit/be6b168618bdc51b5f64af924584ef14342263d2))
* **bridge:** implement kestrel-bridge sidecar ([fc4218c](https://github.com/ostapyrih/kestrel/commit/fc4218cd0172b8de08a72f2d492cbedcffd1730a))
