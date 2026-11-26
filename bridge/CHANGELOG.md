# Changelog

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
