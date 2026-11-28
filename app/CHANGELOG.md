# Changelog

## [0.11.2](https://github.com/ostapyrih/kestrel/compare/app-v0.11.1...app-v0.11.2) (2026-11-28)


### Bug Fixes

* **app:** sync deviceRouter inbox and head using configured interval ([#60](https://github.com/ostapyrih/kestrel/issues/60)) ([b663009](https://github.com/ostapyrih/kestrel/commit/b663009d40612506bcd829b18da6092d2b67953c))
* **rns,app:** raise link receipt timeout on slow LoRa links and add close button to MessageDetails ([#62](https://github.com/ostapyrih/kestrel/issues/62)) ([10ba0f0](https://github.com/ostapyrih/kestrel/commit/10ba0f0817f099c4d15a1a3417f0652102632081))

## [0.11.1](https://github.com/ostapyrih/kestrel/compare/app-v0.11.0...app-v0.11.1) (2026-11-28)


### Bug Fixes

* **app:** fix Windows RNode COM port native crash ([#58](https://github.com/ostapyrih/kestrel/issues/58)) ([654bbb3](https://github.com/ostapyrih/kestrel/commit/654bbb33b181949096532626a4f4d8255d9aa4c5))

## [0.11.0](https://github.com/ostapyrih/kestrel/compare/app-v0.10.1...app-v0.11.0) (2026-11-28)


### Features

* **app:** add RNS key import/export across group and manual history pull ([#56](https://github.com/ostapyrih/kestrel/issues/56)) ([f0b79b8](https://github.com/ostapyrih/kestrel/commit/f0b79b8a09cbcc4a7c7811857f28e22b9e17115d))

## [0.10.1](https://github.com/ostapyrih/kestrel/compare/app-v0.10.0...app-v0.10.1) (2026-11-27)


### Bug Fixes

* **app:** register iOS BGTask launch handler ([61298d5](https://github.com/ostapyrih/kestrel/commit/61298d598d9dfa205d537d1b28a07694991f0bfa))

## [0.10.0](https://github.com/ostapyrih/kestrel/compare/app-v0.9.1...app-v0.10.0) (2026-11-27)


### Features

* address change spreads to all group devices; history backfill for new devices ([#51](https://github.com/ostapyrih/kestrel/issues/51)) ([038883e](https://github.com/ostapyrih/kestrel/commit/038883ede524d0cecfa390fc0f40762936a25fb5))
* **app:** compact mail-via-node settings, node picker, default propagation node ([#44](https://github.com/ostapyrih/kestrel/issues/44)) ([ff7f1e7](https://github.com/ostapyrih/kestrel/commit/ff7f1e70c9aac90d53b614a695a5e010e8dc3875))
* **app:** notifications and background operation (Phase 7) ([#46](https://github.com/ostapyrih/kestrel/issues/46)) ([254aa5d](https://github.com/ostapyrih/kestrel/commit/254aa5dec0feba27a8c8de5cd854935735a59a8c))
* device group sync without the bridge (Phase S) ([#50](https://github.com/ostapyrih/kestrel/issues/50)) ([e7fb4e4](https://github.com/ostapyrih/kestrel/commit/e7fb4e456a89d1c44b3b162f64a252811f29d3a2))
* RNode LoRa interface over BLE and USB serial, radio settings (Phase 6) ([#47](https://github.com/ostapyrih/kestrel/issues/47)) ([8d3e069](https://github.com/ostapyrih/kestrel/commit/8d3e06921ee746bea97f4f132ef3896dedf5b6cf))


### Bug Fixes

* **app:** chat list badge overflow; update outdated tests ([#52](https://github.com/ostapyrih/kestrel/issues/52)) ([af3381b](https://github.com/ostapyrih/kestrel/commit/af3381bc3c945db9a09103903ca34bc5dd6ec642))
* **app:** keep Micron cells on the character grid ([#48](https://github.com/ostapyrih/kestrel/issues/48)) ([b5c61cf](https://github.com/ostapyrih/kestrel/commit/b5c61cf1fc6d8e99af854c3c33c7b754f719676f))
* **app:** update default propagation node hash ([#53](https://github.com/ostapyrih/kestrel/issues/53)) ([65a6ca9](https://github.com/ostapyrih/kestrel/commit/65a6ca90224b8c2d9e575533db8e66ce27d03800))

## [0.9.1](https://github.com/ostapyrih/kestrel/compare/app-v0.9.0...app-v0.9.1) (2026-11-27)


### Features

* **app:** desktop apps hide to the tray on close; single instance ([#40](https://github.com/ostapyrih/kestrel/issues/40)) ([4077c49](https://github.com/ostapyrih/kestrel/commit/4077c4912aeec8961379e5a7f5ec5ff4a801c1ee))
* **app:** Enter sends, Shift+Enter inserts a new line ([#41](https://github.com/ostapyrih/kestrel/issues/41)) ([a12dd68](https://github.com/ostapyrih/kestrel/commit/a12dd685be74d57630d53a69ebc9a4b195a519bb))
* LXMF propagation (offline mail via a propagation node, Phase 5) ([#43](https://github.com/ostapyrih/kestrel/issues/43)) ([87509a6](https://github.com/ostapyrih/kestrel/commit/87509a62c2f1ee28eef9388ffec300ddaec217c9))

## [0.9.0](https://github.com/ostapyrih/kestrel/compare/app-v0.8.3...app-v0.9.0) (2026-11-27)


### Features

* **app:** sync NomadNet bookmarks, favourites, history and per-node settings across devices ([#38](https://github.com/ostapyrih/kestrel/issues/38)) ([ba7f661](https://github.com/ostapyrih/kestrel/commit/ba7f6610c19c4522a7f0880e2f3b14088927633b))

## [0.8.3](https://github.com/ostapyrih/kestrel/compare/app-v0.8.2...app-v0.8.3) (2026-11-27)


### Bug Fixes

* **app:** catch up on deletions missed by older versions; durable A tombstones; full resync ([#34](https://github.com/ostapyrih/kestrel/issues/34)) ([781828d](https://github.com/ostapyrih/kestrel/commit/781828dc076d561338abc2b968af107817ea35b9))
* **app:** Windows updater launches the installer directly and relaunches after install ([#37](https://github.com/ostapyrih/kestrel/issues/37)) ([a3f36ff](https://github.com/ostapyrih/kestrel/commit/a3f36ffacd2769b0a1b72270faa00e2cebd342a9))

## [0.8.2](https://github.com/ostapyrih/kestrel/compare/app-v0.8.1...app-v0.8.2) (2026-11-27)


### Bug Fixes

* **app:** no empty chats; a chat is created with its first message ([#32](https://github.com/ostapyrih/kestrel/issues/32)) ([4a71966](https://github.com/ostapyrih/kestrel/commit/4a719666bc1587de8ec6cf797f4c1ea0d2d259a1))

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
