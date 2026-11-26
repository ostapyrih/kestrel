# CLAUDE.md — Kestrel

**Kestrel** — a Flutter Reticulum/LXMF client (Android + iOS) plus the `kestrel-bridge` sidecar for MeshChatX (a separate Docker container, not a plugin — see PLAN §3).
Full plan and phase status: [docs/PLAN.md](docs/PLAN.md). **Read it at the start of every session.**

## Roles (mandatory)
- **Claude (Opus) — orchestrator and maintainer:** writes specs and briefs, reviews results,
  updates `docs/PLAN.md`, manages versions, changelogs and releases.
- **Sonnet writes the code** (subagents with `model: sonnet`). The orchestrator does not write code itself,
  except for a trivial one-line fix. Every brief states: which files, what counts as done, which tests must pass.
- After each agent step the orchestrator checks the diff and the tests, then updates the status in `docs/PLAN.md`.

## Repository — PUBLIC
`github.com/ostapyrih/kestrel` (public). Therefore:
- **Never commit:** identity private keys, keystores, `.p12`/provisioning profiles, tokens,
  SSH users and server paths, IFAC passwords, hashes/public keys from the real network's whitelist,
  contents of the server's Reticulum configs, DB dumps, personal messages.
- Reconnaissance reports with internal server details live in `docs/private/` (in `.gitignore`).
- CI secrets only in GitHub Actions Secrets. The bridge config with the real whitelist and the MeshChatX login lives only on the server;
  the repo contains `config.example.toml` with fake values.
- Public addresses that may be mentioned: `rns.ostapyrih.com:4242` (Reticulum TCP entry point).
- Before every push: review `git diff --cached` for secrets.

## Structure (monorepo)
```
app/       Flutter app (lib/rns, lib/lxmf, lib/bridge, lib/storage, lib/screens)
bridge/    kestrel-bridge sidecar (Python): Dockerfile, kestrel_bridge/, tests/, config.example.toml
packages/kestrel_rns/  pure-Dart RNS + LXMF (no Flutter, `dart test`), used by app/
tools/     golden-vector generators (Python RNS/LXMF → JSON for Dart tests)
docs/      PLAN.md, bridge protocol, ADRs; docs/private/ is not in git
.github/   workflows, release-please config
```

## Conventions
- **Conventional Commits** are mandatory (`feat(app):`, `fix(bridge):`, `docs:`, `ci:`, `chore:`;
  `!` or `BREAKING CHANGE:` for breaking changes). The automatic changelog is built from them.
- Scopes: `app`, `bridge`, `rns`, `lxmf`, `bridge`, `ci`, `docs`.
- Changes to the bridge protocol → update `docs/bridge-protocol.md` and bump `protocol_version`,
  because the app and the bridge must check compatibility.
- Branches: `main` is always green; work happens in `feat/...`, `fix/...`; PRs come with a description.
- Commits end with a `Co-Authored-By` line attributing Claude.
- All repo-facing text (docs, README, changelogs, release notes, PR/issue text, commit messages) is written in English. App UI strings are localized (Ukrainian default, English fallback).

## Versions, changelog, releases
- **release-please** (manifest, monorepo): two components with independent versions and tags:
  - `app` → tag `app-vX.Y.Z`, version in `app/pubspec.yaml` (`X.Y.Z+build`), `app/CHANGELOG.md`
  - `bridge` → tag `bridge-vX.Y.Z`, version in `bridge/pyproject.toml`, `bridge/CHANGELOG.md`
- SemVer; `0.x` until the protocol is stable.
- Process: merges to `main` → release-please opens a Release PR → the orchestrator reviews the changelog
  (hand-writes a human-readable summary on top if needed) → merge → tag + GitHub Release →
  the workflow builds the artifacts and attaches them to the release.
- Release notes are structured as: a short human-language summary, sections *Features / Bug Fixes /
  Breaking changes / Compatibility* (minimum bridge ↔ app version, `protocol_version`), artifacts with SHA256.

## CI (GitHub Actions)
- `ci.yml` (PR + push): `flutter analyze`, `flutter test`, `python -m unittest` for the bridge,
  golden-vector check.
- `release.yml` (on `app-v*` tags): Android APK + AAB; iOS IPA.
  - Android: signed with the release keystore from secrets (`ANDROID_KEYSTORE_B64`, `ANDROID_KEY_ALIAS`,
    `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`). Without secrets the build is unsigned and marked as such.
  - iOS: on `macos-latest`. Without Apple certificates — `--no-codesign`, unsigned `.ipa`
    (for sideloading / AltStore). Once an Apple Developer account exists — signing and TestFlight secrets.
- `release-bridge.yml` (on `bridge-v*` tags): Docker image `ghcr.io/ostapyrih/kestrel-bridge:<version>` + `:latest` (linux/amd64, arm64), SBOM, digest in the release notes.

## Environment
- Development: Windows (`C:\Users\ostap\Projects\meshchatx-mobile`), Flutter installed locally.
- iOS builds locally — on a Mac (x86_64); otherwise via CI.
- The MeshChatX image on the server stays `latest-extra` (user's decision): the bridge checks the MeshChatX version at startup, and CI has API contract tests.
- Server: MeshChatX in Docker on `amd1` (SSH access, details not in the repo). Any change on the server
  (bridge deploy, compose changes, container restarts) — only after an explicit "yes" from the user.
