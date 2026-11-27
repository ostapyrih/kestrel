# Changelog

## [0.8.1](https://github.com/ostapyrih/kestrel/compare/app-v0.8.0...app-v0.8.1) (2026-11-27)


### Bug Fixes

* **app:** keep Micron fixed-width layout on narrow screens ([#31](https://github.com/ostapyrih/kestrel/issues/31)) ([216a649](https://github.com/ostapyrih/kestrel/commit/216a649cb0ac93aaee5b6c755dd50d59366e5ff9))
* **app:** vault push topic, A/B choice for new chats, robust A delete, deletion catch-up, Windows updater ([#29](https://github.com/ostapyrih/kestrel/issues/29)) ([d438fe9](https://github.com/ostapyrih/kestrel/commit/d438fe9e2e158610fe53e338bf5fa77333830dd5))

## [0.8.0](https://github.com/ostapyrih/kestrel/compare/app-v0.7.0...app-v0.8.0) (2026-11-27)


### Features

* delete chats on every device (own B, account A via MeshChatX, other devices' chats) ([#26](https://github.com/ostapyrih/kestrel/issues/26)) ([4ee6320](https://github.com/ostapyrih/kestrel/commit/4ee63205ab7e55269046b11616af60eee1e638f9))
* NomadNet browser (Phase N) ([#28](https://github.com/ostapyrih/kestrel/issues/28)) ([d38ff56](https://github.com/ostapyrih/kestrel/commit/d38ff56873d0dee0aea01f114ab58746156270fa))

## [0.7.0](https://github.com/ostapyrih/kestrel/compare/app-v0.6.0...app-v0.7.0) (2026-11-27)


### Features

* end-to-end encrypted history sync between devices (vault, Phase 4b) ([#24](https://github.com/ostapyrih/kestrel/issues/24)) ([d268021](https://github.com/ostapyrih/kestrel/commit/d268021dbf28168a2c5dd33285dd8ff5a66549ca))

## [0.6.0](https://github.com/ostapyrih/kestrel/compare/app-v0.5.0...app-v0.6.0) (2026-11-26)


### Features

* **app:** desktop updater with signed releases ([fc7c9ed](https://github.com/ostapyrih/kestrel/commit/fc7c9ed9ff78c6f235491ec643cfbbf6cee18a96))
* **ci:** signed Android builds and release signatures ([a00a059](https://github.com/ostapyrih/kestrel/commit/a00a059ef2a4fd76bde6263bb66bc1e6cd906901))
* invite-QR pairing, app-owned device name, plain messenger when the bridge is off ([#22](https://github.com/ostapyrih/kestrel/issues/22)) ([c316067](https://github.com/ostapyrih/kestrel/commit/c316067f2c5a110ccc5b587d77f97f817a6c22ff))


### Bug Fixes

* **app:** satisfy curly_braces lint in the macOS installer ([0418b11](https://github.com/ostapyrih/kestrel/commit/0418b114928f64f24f0391f6c2f826bdea366953))
* **app:** show waiting-for-approval and revoked states from the bridge reject reason ([41532d9](https://github.com/ostapyrih/kestrel/commit/41532d90c9f83efc4e026900c4d6c3243208dd3e))

## [0.5.0](https://github.com/ostapyrih/kestrel/compare/app-v0.4.0...app-v0.5.0) (2026-11-26)


### Features

* **app:** bridge mode UI, devices, pairing and RRC rooms ([2764d6e](https://github.com/ostapyrih/kestrel/commit/2764d6e5fda8453ebf9c657a31027259ee3afef5))
* **app:** bridge protocol v2 client and account A sync ([79b8e91](https://github.com/ostapyrih/kestrel/commit/79b8e91d1c122c227bfd7463cb30e900268395e3))

## [0.4.0](https://github.com/ostapyrih/kestrel/compare/app-v0.3.0...app-v0.4.0) (2026-11-26)


### Features

* **app:** app icon ([132d1d6](https://github.com/ostapyrih/kestrel/commit/132d1d6323dd6fb89f02b6bd17fbf9ad716735de))

## [0.3.0](https://github.com/ostapyrih/kestrel/compare/app-v0.2.0...app-v0.3.0) (2026-11-26)


### Features

* **app:** add Windows, macOS and Linux platform scaffolding ([9f352ea](https://github.com/ostapyrih/kestrel/commit/9f352ea3c8a8a441454b6ebef5d90e4f398e4a97))
* **app:** run on desktop with two-pane layout and device name ([3a60150](https://github.com/ostapyrih/kestrel/commit/3a601500ccc8ef8b6b026c7ed1eca7caf9078259))

## [0.2.0](https://github.com/ostapyrih/kestrel/compare/app-v0.1.0...app-v0.2.0) (2026-11-26)


### Features

* **app:** chats, chat detail, new chat and settings screens ([b863703](https://github.com/ostapyrih/kestrel/commit/b8637035dd114d4b471782f0012967b3615ea540))
* **app:** NodeService runs Reticulum and the LXMF router for identity B ([9991d4a](https://github.com/ostapyrih/kestrel/commit/9991d4aff0d6605904f8046ccfdddef4fb1fe2f0))
* **app:** SQLite schema with migrations and mode-safe repository ([baf43ed](https://github.com/ostapyrih/kestrel/commit/baf43ed147812aaa033edaf7691a27013a27687d))
