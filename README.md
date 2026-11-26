# Kestrel

Kestrel is a [Reticulum](https://reticulum.network/) / LXMF messenger for Android, iOS, Windows, macOS and Linux,
written in Flutter, plus a server-side sidecar (`kestrel-bridge`) that lets the phone
act on behalf of a MeshChatX identity.

**Status: early development.** Nothing here is usable yet.

## Two modes

- **Standalone** - the phone has its own identity and talks LXMF directly over TCP
  (`rns.ostapyrih.com:4242`) or, later, BLE to an RNode (LoRa).
- **Bridge** - in addition, the phone talks to the `kestrel-bridge` sidecar next to
  MeshChatX, which sends and receives on behalf of the MeshChatX identity. Switching modes
  never deletes data.

See [docs/PLAN.md](docs/PLAN.md) for the full plan and phase status, and
[docs/bridge-protocol.md](docs/bridge-protocol.md) for the bridge protocol.

## Platforms

| Platform | Status | Notes |
| --- | --- | --- |
| Android | built | signed APK / AAB; updates via Obtainium |
| iOS | built | unsigned IPA (sideload) |
| Windows | built | per-user installer and zip, not code-signed (SmartScreen warning); updates in-app |
| macOS | built | unsigned DMG (Gatekeeper warning); updates in-app |
| Linux | built | AppImage (updates in-app) and tar.gz; needs libsecret and a Secret Service (GNOME Keyring / KWallet) |

### Install on Android

Releases carry release-signed APKs (`kestrel-<version>-arm64-v8a.apk`, `armeabi-v7a`, `x86_64`) and an AAB.
[Obtainium](https://obtainium.imranr.dev/) installs and updates them straight from GitHub Releases.
On the phone with Obtainium installed, tap **[Add Kestrel to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.ostapyrih.kestrel%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fostapyrih%2Fkestrel%22%2C%22author%22%3A%22ostapyrih%22%2C%22name%22%3A%22Kestrel%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22arm64-v8a%5C%22%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5Ebridge%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Atrue%7D%22%7D)**
(it preselects the `arm64-v8a` APK, ignores pre-releases and skips the `bridge-v*` releases).
If the link does not open, copy this into the phone's browser:

```
obtainium://app/%7B%22id%22%3A%22com.ostapyrih.kestrel%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fostapyrih%2Fkestrel%22%2C%22author%22%3A%22ostapyrih%22%2C%22name%22%3A%22Kestrel%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22arm64-v8a%5C%22%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5Ebridge%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Atrue%7D%22%7D
```

Or add the app by hand: *Add app*, source URL `https://github.com/ostapyrih/kestrel`, then in the
app's additional options set *Filter APKs by regular expression* to `arm64-v8a`, *Filter release
titles by regular expression* to `^bridge` with *Invert* on, and leave *Include prereleases* off.
The inverted title filter keeps the `bridge-v*` releases out of the update checks.

Verify the signature before the first install with
[AppVerifier](https://github.com/soupslurpr/AppVerifier) (package `com.ostapyrih.kestrel`) or
`apksigner verify --print-certs <apk>`. The release certificate SHA-256 is:

```
99:74:09:CA:9C:93:87:F6:7E:29:24:19:14:21:60:31:2B:AA:0F:63:CA:76:56:94:AF:85:50:D9:8E:40:04:C2
```

### Desktop updates

The Windows, macOS and AppImage builds check GitHub Releases at start-up and every 6 hours
(Settings, *Check for updates automatically*, on by default; *Check now* is manual), show the
release notes and install the update on request. Before installing, the app verifies the Ed25519
signature of `SHA256SUMS.txt` against the public key embedded in the app and then the SHA-256 of
the downloaded file; on any mismatch it refuses. Windows runs the per-user installer silently
(`kestrel-<version>-windows-x64-setup.exe`, installs to `%LOCALAPPDATA%\Programs\Kestrel`),
macOS replaces the app bundle from the DMG, an AppImage replaces itself. The `tar.gz` build and
mobile platforms have no in-app updater.

### Verify a release

Every release has `SHA256SUMS.txt` and `SHA256SUMS.txt.sig`, a base64 Ed25519 signature over the exact
bytes of the checksum file. The public key (raw 32 bytes, base64) is:

```
GeeSuwmBoGEsCARLxFniM3qIlf2w2htnnGT7wYeH7as=
```

Download the files of a release into one directory and run (needs Python and `pip install cryptography`):

```
python tools/release/verify.py SHA256SUMS.txt SHA256SUMS.txt.sig --check-files .
```

The script checks the signature and then the SHA-256 of every listed file that is present.
The Android certificate fingerprint above is independent of this key.

### Install on iOS

The IPA is unsigned; AltStore and SideStore sign it with your Apple ID and keep it updated.
Add the Kestrel source (AltStore: Browse, Sources, `+`; SideStore: Sources, `+`) with this URL:

```
https://ostapyrih.github.io/kestrel/altstore.json
```

Or open a deep link on the iPhone:
[AltStore](altstore://source?url=https://ostapyrih.github.io/kestrel/altstore.json) /
[SideStore](sidestore://source?url=https://ostapyrih.github.io/kestrel/altstore.json)
(`altstore://source?url=...`, `sidestore://source?url=...`; some viewers do not open custom
schemes, in which case use the [source page](https://ostapyrih.github.io/kestrel/)).
The source is regenerated from the GitHub releases after every app release (`tools/altstore/generate.py`).

Each install generates its own identity (a desktop install is its own identity B).
RNode (LoRa) support is planned: BLE on mobile, USB serial on desktop.

Linux build dependencies: `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev`.

## Repository layout

```
app/       Flutter app
bridge/    kestrel-bridge sidecar (Python, Docker)
tools/     golden-vector generators
docs/      plan, protocol, ADRs
```

## Build and test

App (requires Flutter stable):

```
cd app
flutter pub get
flutter analyze
flutter test
```

Bridge (requires Python 3.11+):

```
cd bridge
python -m unittest discover -s tests -t .
docker build -t kestrel-bridge .
```

## Contributing

Conventional Commits are required (`feat(app):`, `fix(bridge):`, `docs:`, ...); changelogs and
releases are generated by release-please.

## License

MIT, see [LICENSE](LICENSE).
