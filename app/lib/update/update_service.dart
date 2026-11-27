import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'installer.dart';
import 'release_key.dart';
import 'update_outcome.dart';
import 'releases.dart';
import 'verify.dart';
import 'version.dart';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  installing,
  error,
}

enum UpdateError {
  network,
  assetMissing,
  badSignature,
  checksumMismatch,
  noPermission,
  installFailed,
}

class UpdateState {
  const UpdateState({
    this.status = UpdateStatus.idle,
    this.current,
    this.release,
    this.progress,
    this.error,
    this.errorDetail = '',
    this.manualOnly = false,
    this.dismissed = false,
    this.lastChecked,
    this.failure,
  });

  final UpdateStatus status;
  final AppVersion? current;

  /// The newer release, when one was found.
  final ReleaseInfo? release;

  /// Download progress 0..1 (null when unknown).
  final double? progress;
  final UpdateError? error;
  final String errorDetail;

  /// A newer release exists but this install cannot update itself (Linux
  /// without AppImage): the UI links to the release page instead.
  final bool manualOnly;

  /// The user closed the banner for this release.
  final bool dismissed;
  final DateTime? lastChecked;

  /// The previous start tried to update and the old version came back: where
  /// the installer log is and the installer to run by hand.
  final UpdateOutcome? failure;

  UpdateState copyWith({
    UpdateStatus? status,
    ReleaseInfo? release,
    bool clearRelease = false,
    double? progress,
    bool clearProgress = false,
    UpdateError? error,
    String? errorDetail,
    bool clearError = false,
    bool? manualOnly,
    bool? dismissed,
    DateTime? lastChecked,
    UpdateOutcome? failure,
    bool clearFailure = false,
  }) => UpdateState(
    status: status ?? this.status,
    current: current,
    release: clearRelease ? null : (release ?? this.release),
    progress: clearProgress ? null : (progress ?? this.progress),
    error: clearError ? null : (error ?? this.error),
    errorDetail: clearError ? '' : (errorDetail ?? this.errorDetail),
    manualOnly: manualOnly ?? this.manualOnly,
    dismissed: dismissed ?? this.dismissed,
    lastChecked: lastChecked ?? this.lastChecked,
    failure: clearFailure ? null : (failure ?? this.failure),
  );

  UpdateState withCurrent(AppVersion? v) => UpdateState(
    status: status,
    current: v,
    release: release,
    progress: progress,
    error: error,
    errorDetail: errorDetail,
    manualOnly: manualOnly,
    dismissed: dismissed,
    lastChecked: lastChecked,
    failure: failure,
  );
}

typedef FetchBytes = Future<List<int>> Function(Uri url, {int maxBytes});
typedef DownloadFile = Future<void> Function(
  Uri url,
  File dest,
  void Function(int received, int? total) onProgress,
);

const _userAgent = 'kestrel-updater';

Future<List<int>> httpFetchBytes(Uri url, {int maxBytes = 4 << 20}) async {
  final client = HttpClient()..userAgent = _userAgent;
  try {
    final req = await client.getUrl(url);
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > maxBytes) throw HttpException('too large', uri: url);
    }
    return out.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<void> httpDownloadFile(
  Uri url,
  File dest,
  void Function(int received, int? total) onProgress,
) async {
  final client = HttpClient()..userAgent = _userAgent;
  try {
    final req = await client.getUrl(url);
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final total = res.contentLength >= 0 ? res.contentLength : null;
    final sink = dest.openWrite();
    var got = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        onProgress(got, total);
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close(force: true);
  }
}

/// Checks GitHub Releases for a newer `app-v*` release and installs it after
/// verifying the Ed25519 signature of `SHA256SUMS.txt` and the asset's SHA-256.
class UpdateService {
  UpdateService({
    required this.currentVersion,
    required this.platform,
    required this.tempDir,
    this.installer,
    this.linuxAppImage = false,
    this.autoCheckEnabled,
    FetchBytes? fetch,
    DownloadFile? download,
    this.publicKeyB64 = releasePublicKeyB64,
    this.exitApp = _exit,
    this.checkInterval = const Duration(hours: 6),
  }) : _fetch = fetch ?? httpFetchBytes,
       _download = download ?? httpDownloadFile,
       _state = UpdateState(current: currentVersion);

  /// Inert service (tests, mobile): never checks and never touches the network.
  UpdateService.disabled()
    : currentVersion = null,
      platform = null,
      tempDir = Directory.systemTemp,
      installer = null,
      linuxAppImage = false,
      autoCheckEnabled = null,
      publicKeyB64 = releasePublicKeyB64,
      exitApp = _exit,
      checkInterval = const Duration(hours: 6),
      _fetch = httpFetchBytes,
      _download = httpDownloadFile,
      _state = const UpdateState(),
      _disabled = true;

  static void _exit() => exit(0);

  final AppVersion? currentVersion;
  final UpdatePlatform? platform;
  final Directory tempDir;
  final UpdateInstaller? installer;
  final bool linuxAppImage;

  /// Reads the "check automatically" setting (default on when null).
  final Future<bool> Function()? autoCheckEnabled;
  final String publicKeyB64;
  final void Function() exitApp;
  final Duration checkInterval;
  final FetchBytes _fetch;
  final DownloadFile _download;
  bool _disabled = false;

  final _changes = StreamController<UpdateState>.broadcast();
  UpdateState _state;
  Timer? _timer;

  bool get enabled => !_disabled;
  UpdateState get state => _state;
  Stream<UpdateState> get changes => _changes.stream;

  void _set(UpdateState s) {
    _state = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  /// Starts the first check shortly after launch and then every [checkInterval].
  void start() {
    if (_disabled) return;
    _timer?.cancel();
    unawaited(checkPreviousInstall());
    Timer(const Duration(seconds: 5), _auto);
    _timer = Timer.periodic(checkInterval, (_) => _auto());
  }

  /// After an update attempt: says whether the new version is running. A
  /// failed attempt (the old version came back) puts the log path and the
  /// installer in [UpdateState.failure]; a successful one only clears the
  /// marker.
  Future<UpdateOutcome> checkPreviousInstall({DateTime? now}) async {
    final cur = currentVersion;
    if (_disabled || cur == null) {
      return const UpdateOutcome(UpdateOutcomeKind.none);
    }
    final pending = await readPendingUpdate(tempDir);
    final out = evaluateUpdateOutcome(
      pending: pending,
      running: cur,
      now: now ?? DateTime.now(),
      exitCode: pending == null ? null : await readInstallerExitCode(pending),
    );
    if (out.failed) {
      _set(_state.copyWith(failure: out));
    }
    // the verdict is shown once: the marker goes either way
    if (pending != null) await clearPendingUpdate(tempDir);
    return out;
  }

  /// Hides the "update failed" notice.
  void dismissFailure() => _set(_state.copyWith(clearFailure: true));

  /// Runs the installer of a failed attempt visibly (the manual fallback).
  Future<void> installManually(UpdateOutcome failure) async {
    final path = failure.pending?.installerPath;
    if (path == null || !await File(path).exists()) return;
    if (Platform.isWindows) {
      await Process.start(path, const [], mode: ProcessStartMode.detached);
    } else {
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [
        path,
      ], mode: ProcessStartMode.detached);
    }
  }

  Future<void> _auto() async {
    if (_busy) return;
    final on = autoCheckEnabled == null ? true : await autoCheckEnabled!();
    if (on) await checkNow();
  }

  bool get _busy => switch (_state.status) {
    UpdateStatus.checking ||
    UpdateStatus.downloading ||
    UpdateStatus.verifying ||
    UpdateStatus.installing => true,
    _ => false,
  };

  void dispose() {
    _timer?.cancel();
    _changes.close();
  }

  void dismiss() => _set(_state.copyWith(dismissed: true));

  /// Looks for a newer release. Network errors are reported in the state.
  Future<void> checkNow() async {
    if (_disabled || _busy || currentVersion == null) return;
    _set(_state.copyWith(status: UpdateStatus.checking, clearError: true));
    try {
      final raw = await _fetch(Uri.parse(releasesApiUrl));
      final newest = newestUpdate(
        parseAppReleases(jsonDecode(utf8.decode(raw))),
        currentVersion!,
      );
      final now = DateTime.now();
      if (newest == null) {
        _set(
          _state.copyWith(
            status: UpdateStatus.upToDate,
            clearRelease: true,
            lastChecked: now,
          ),
        );
        return;
      }
      final same = _state.release?.version == newest.version;
      final manual =
          platform != null &&
          platform != UpdatePlatform.android &&
          platform != UpdatePlatform.ios &&
          selectAsset(newest, platform!, linuxAppImage: linuxAppImage) == null;
      _set(
        _state.copyWith(
          status: UpdateStatus.available,
          release: newest,
          manualOnly: manual,
          dismissed: same ? _state.dismissed : false,
          lastChecked: now,
        ),
      );
    } on Object catch (e) {
      _set(
        _state.copyWith(
          status: UpdateStatus.error,
          error: UpdateError.network,
          errorDetail: '$e',
        ),
      );
    }
  }

  /// Downloads, verifies and installs the available release.
  Future<void> install() async {
    final release = _state.release;
    if (_disabled || _busy || release == null || platform == null) return;
    final asset = selectAsset(release, platform!, linuxAppImage: linuxAppImage);
    final sumsAsset = release.asset('SHA256SUMS.txt');
    final sigAsset = release.asset('SHA256SUMS.txt.sig');
    if (asset == null ||
        sumsAsset == null ||
        sigAsset == null ||
        installer == null) {
      _fail(
        UpdateError.assetMissing,
        asset == null ? 'installer asset' : 'SHA256SUMS.txt or .sig',
      );
      return;
    }
    File? file;
    try {
      _set(
        _state.copyWith(
          status: UpdateStatus.downloading,
          progress: 0,
          clearError: true,
        ),
      );
      final dir = await tempDir.createTemp('kestrel-update');
      file = File(p.join(dir.path, asset.name));
      await _download(Uri.parse(asset.url), file, (got, total) {
        _set(
          _state.copyWith(
            progress: total == null || total == 0 ? null : got / total,
            clearProgress: total == null || total == 0,
          ),
        );
      });
      final sums = await _fetch(Uri.parse(sumsAsset.url));
      final sig = await _fetch(Uri.parse(sigAsset.url), maxBytes: 1024);

      _set(
        _state.copyWith(status: UpdateStatus.verifying, clearProgress: true),
      );
      await verifySumsSignature(
        sums,
        utf8.decode(sig),
        publicKeyB64: publicKeyB64,
      );
      verifyAssetDigest(
        parseSums(utf8.decode(sums)),
        asset.name,
        await sha256OfFile(file),
      );

      _set(_state.copyWith(status: UpdateStatus.installing));
      // remembered across the restart: the next start checks that the new
      // version is really the one running
      await writePendingUpdate(
        tempDir,
        PendingUpdate(
          from: '${currentVersion ?? ''}',
          target: '${release.version}',
          installerPath: file.path,
          logPath: updateLogPath(file),
          resultPath: updateResultPath(file),
          startedAt: DateTime.now(),
        ),
      );
      await installer!.install(file, exitApp: exitApp);
    } on UpdateVerifyException catch (e) {
      await _discard(file);
      _fail(switch (e.failure) {
        VerifyFailure.checksumMismatch ||
        VerifyFailure.notListed => UpdateError.checksumMismatch,
        VerifyFailure.badSignature => UpdateError.badSignature,
      }, e.detail);
    } on InstallException catch (e) {
      await clearPendingUpdate(tempDir);
      _fail(
        e.noPermission ? UpdateError.noPermission : UpdateError.installFailed,
        e.message,
      );
    } on Object catch (e) {
      await _discard(file);
      _fail(UpdateError.network, '$e');
    }
  }

  Future<void> _discard(File? f) async {
    try {
      if (f != null && await f.exists()) await f.parent.delete(recursive: true);
    } on FileSystemException {
      // best effort
    }
  }

  void _fail(UpdateError e, String detail) => _set(
    _state.copyWith(
      status: UpdateStatus.error,
      error: e,
      errorDetail: detail,
      clearProgress: true,
    ),
  );
}

/// Overridden in main() on desktop; the default is inert so tests never poll.
final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService.disabled(),
);

final updateStateProvider = StreamProvider<UpdateState>((ref) async* {
  final s = ref.watch(updateServiceProvider);
  yield s.state;
  yield* s.changes;
});
