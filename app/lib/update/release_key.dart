/// Ed25519 public key (raw 32 bytes, base64) that signs `SHA256SUMS.txt` of every
/// app release. The matching private key lives only in the `RELEASE_SIGNING_KEY`
/// GitHub secret. Same value as `PUBLIC_KEY_B64` in tools/release/verify.py.
const releasePublicKeyB64 = 'GeeSuwmBoGEsCARLxFniM3qIlf2w2htnnGT7wYeH7as=';

/// GitHub Releases listing the updater polls.
const releasesApiUrl =
    'https://api.github.com/repos/ostapyrih/kestrel/releases?per_page=30';

/// Asset URLs must start with this prefix to be downloaded.
const trustedDownloadPrefix =
    'https://github.com/ostapyrih/kestrel/releases/download/';

/// Setting key: "Check for updates automatically" ('1' / '0', default on).
const updateAutoCheckKey = 'update_auto_check';
