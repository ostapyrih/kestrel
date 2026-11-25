# CLAUDE.md — Kestrel

**Kestrel** — Flutter-клієнт Reticulum/LXMF (Android + iOS) + sidecar-міст `kestrel-bridge` для MeshChatX (окремий Docker-контейнер, не плагін — див. PLAN §3).
Повний план і статус фаз: [docs/PLAN.md](docs/PLAN.md). **Читай його на початку кожної сесії.**

## Ролі (обов'язково)
- **Claude (Opus) — оркестратор і мейнтейнер:** пише специфікації та брифи, ревʼюїть результат,
  оновлює `docs/PLAN.md`, веде версії, changelog і релізи.
- **Код пише Sonnet** (субагенти `model: sonnet`). Оркестратор сам код не пише, хіба що це
  тривіальна правка в один рядок. Кожен бриф: які файли, що вважається готовим, які тести мають пройти.
- Після кожного кроку агента оркестратор перевіряє diff і тести, а потім оновлює статус у `docs/PLAN.md`.

## Репозиторій — PUBLIC
`github.com/ostapyrih/kestrel` (публічний). Тому:
- **Ніколи не комітити:** приватні ключі identity, keystore, `.p12`/provisioning profiles, токени,
  SSH-користувачів і шляхи на сервері, IFAC-паролі, хеші/публічні ключі з whitelist реальної
  мережі, вміст конфігів Reticulum з сервера, дампи БД, особисті повідомлення.
- Звіти розвідки з внутрішніми деталями сервера лежать у `docs/private/` (у `.gitignore`).
- Секрети CI тільки в GitHub Actions Secrets. Конфіг мосту з реальним whitelist і логіном до MeshChatX — тільки на сервері;
  у репо лежить `config.example.toml` з фейковими значеннями.
- Публічні адреси, які можна згадувати: `rns.ostapyrih.com:4242` (TCP-вхід Reticulum).
- Перед кожним push: `git diff --cached` переглянути на предмет секретів.

## Структура (монорепо)
```
app/       Flutter-додаток (lib/rns, lib/lxmf, lib/bridge, lib/storage, lib/screens)
bridge/    sidecar kestrel-bridge (Python): Dockerfile, kestrel_bridge/, tests/, config.example.toml
packages/kestrel_rns/  pure-Dart RNS + LXMF (без Flutter, `dart test`), використовується app/
tools/     генератори golden-векторів (Python RNS/LXMF → JSON для Dart-тестів)
docs/      PLAN.md, протокол мосту, ADR; docs/private/ — не в git
.github/   workflows, release-please config
```

## Конвенції
- **Conventional Commits** обов'язково (`feat(app):`, `fix(bridge):`, `docs:`, `ci:`, `chore:`;
  `!` або `BREAKING CHANGE:` для ламаючих змін). На них працює автоматичний changelog.
- Scope: `app`, `bridge`, `rns`, `lxmf`, `bridge`, `ci`, `docs`.
- Зміни в протоколі мосту → оновити `docs/bridge-protocol.md` і підняти `protocol_version`,
  бо застосунок і міст мають перевіряти сумісність.
- Гілки: `main` завжди зелена; робота у `feat/...`, `fix/...`; PR з описом.
- Коміти закінчуються рядком `Co-Authored-By` з атрибуцією Claude.

## Версії, changelog, релізи
- **release-please** (manifest, монорепо): два компоненти з незалежними версіями та тегами:
  - `app` → тег `app-vX.Y.Z`, версія в `app/pubspec.yaml` (`X.Y.Z+build`), `app/CHANGELOG.md`
  - `bridge` → тег `bridge-vX.Y.Z`, версія в `bridge/pyproject.toml`, `bridge/CHANGELOG.md`
- SemVer; до стабільного протоколу — `0.x`.
- Процес: мержі в `main` → release-please відкриває Release PR → оркестратор ревʼюїть changelog
  (за потреби вручну дописує людський опис зверху) → мерж → тег + GitHub Release →
  workflow збирає артефакти і прикріплює до релізу.
- Опис релізу оформлюємо так: короткий підсумок людською мовою, розділи *Нове / Виправлено /
  Ламаючі зміни / Сумісність* (мін. версія мосту ↔ застосунку, `protocol_version`), артефакти з SHA256.

## CI (GitHub Actions)
- `ci.yml` (PR + push): `flutter analyze`, `flutter test`, `python -m unittest` для мосту,
  перевірка golden-векторів.
- `release.yml` (на теги `app-v*`): Android APK + AAB; iOS IPA.
  - Android: підпис release-keystore із secrets (`ANDROID_KEYSTORE_B64`, `ANDROID_KEY_ALIAS`,
    `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`). Без секретів — збірка unsigned з позначкою.
  - iOS: на `macos-latest`. Без Apple-сертифікатів — `--no-codesign`, unsigned `.ipa`
    (для sideload / AltStore). Коли буде акаунт Apple Developer — secrets для підпису й TestFlight.
- `release-bridge.yml` (на теги `bridge-v*`): Docker-образ `ghcr.io/ostapyrih/kestrel-bridge:<version>` + `:latest` (linux/amd64, arm64), SBOM, digest у описі релізу.

## Середовище
- Розробка: Windows (`C:\Users\ostap\Projects\meshchatx-mobile`), Flutter встановлено локально.
- iOS-збірка локально — на Mac (x86_64); інакше через CI.
- Образ MeshChatX на сервері лишається `latest-extra` (рішення користувача): міст перевіряє версію MeshChatX при старті, а CI має контракт-тести API.
- Сервер: MeshChatX у Docker на `amd1` (доступ по SSH, деталі не в репо). Будь-які зміни на сервері
  (деплой мосту, зміни compose, рестарт контейнерів) — тільки після явного «так» від користувача.
