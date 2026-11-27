import 'dart:io';

import 'package:path/path.dart' as p;

import 'releases.dart';
import 'update_outcome.dart';
import 'windows_launch.dart';

class InstallException implements Exception {
  InstallException(this.message, {this.noPermission = false});

  final String message;
  final bool noPermission;

  @override
  String toString() => 'InstallException($message)';
}

/// Installs a downloaded and already verified update, then relaunches the app.
/// A successful [install] normally ends the process via [exitApp].
abstract class UpdateInstaller {
  Future<void> install(File verified, {required void Function() exitApp});
}

/// The installer for the running platform, or null when the app cannot update
/// itself here (mobile, or Linux outside an AppImage).
UpdateInstaller? installerForCurrentPlatform() {
  if (Platform.isWindows) return WindowsInstaller();
  if (Platform.isMacOS) return MacInstaller();
  if (Platform.isLinux && Platform.environment['APPIMAGE'] != null) {
    return AppImageInstaller(Platform.environment['APPIMAGE']!);
  }
  return null;
}

UpdatePlatform? currentUpdatePlatform() {
  if (Platform.isWindows) return UpdatePlatform.windows;
  if (Platform.isMacOS) return UpdatePlatform.macos;
  if (Platform.isLinux) return UpdatePlatform.linux;
  if (Platform.isAndroid) return UpdatePlatform.android;
  if (Platform.isIOS) return UpdatePlatform.ios;
  return null;
}

// ------------------------------------------------------------------ Windows

/// Starts a command line as an independent process (injectable for tests).
typedef DetachedLauncher = void Function(String commandLine);

/// The command line that runs the Inno Setup installer silently. Paths are
/// quoted so that spaces in the temp directory or user name are safe.
String windowsInstallerCommandLine(String installer, String log) =>
    '"$installer" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART '
    '/CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOG="$log"';

/// Runs the verified Inno Setup installer directly (no script in between) and
/// exits. Setup closes this process through the Restart Manager if it lingers
/// and relaunches the app itself (a silent-only `[Run]` entry in kestrel.iss).
/// The installer is per-user (no admin rights).
class WindowsInstaller implements UpdateInstaller {
  WindowsInstaller({
    DetachedLauncher? launch,
    this.exitDelay = const Duration(seconds: 2),
  }) : _launch = launch ?? launchDetachedWindows;

  final DetachedLauncher _launch;

  /// Time left to flush the database before the process exits.
  final Duration exitDelay;

  @override
  Future<void> install(
    File verified, {
    required void Function() exitApp,
  }) async {
    try {
      _launch(
        windowsInstallerCommandLine(verified.path, updateLogPath(verified)),
      );
    } on LaunchException catch (e) {
      throw InstallException(e.message);
    }
    await Future<void>.delayed(exitDelay);
    exitApp();
  }
}

// -------------------------------------------------------------------- macOS

/// `/Applications/Kestrel.app/Contents/MacOS/kestrel` -> `/Applications/Kestrel.app`.
String macBundlePath(String resolvedExecutable) =>
    p.dirname(p.dirname(p.dirname(resolvedExecutable)));

/// Mounts the DMG, copies the new bundle next to the running one, then (after
/// this process exits) swaps them, clears quarantine and relaunches.
class MacInstaller implements UpdateInstaller {
  @override
  Future<void> install(
    File verified, {
    required void Function() exitApp,
  }) async {
    final bundle = macBundlePath(Platform.resolvedExecutable);
    if (!bundle.endsWith('.app')) {
      throw InstallException('not running from an app bundle');
    }
    final parent = p.dirname(bundle);
    final staged = p.join(parent, '.Kestrel-update.app');
    try {
      final probe = File(p.join(parent, '.kestrel-write-test'));
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw InstallException('no write access to $parent', noPermission: true);
    }
    final mount = await Directory.systemTemp.createTemp('kestrel-dmg');
    var attached = false;
    try {
      final a = await Process.run('hdiutil', [
        'attach',
        '-nobrowse',
        '-readonly',
        '-noverify',
        '-mountpoint',
        mount.path,
        verified.path,
      ]);
      if (a.exitCode != 0) {
        throw InstallException('hdiutil attach: ${a.stderr}');
      }
      attached = true;
      final apps = mount
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) throw InstallException('no .app in the disk image');
      if (await Directory(staged).exists()) {
        await Directory(staged).delete(recursive: true);
      }
      final c = await Process.run('ditto', [apps.first.path, staged]);
      if (c.exitCode != 0) throw InstallException('ditto: ${c.stderr}');
      await Process.run('xattr', ['-dr', 'com.apple.quarantine', staged]);
    } finally {
      if (attached) {
        await Process.run('hdiutil', ['detach', '-force', mount.path]);
      }
      try {
        await mount.delete();
      } on FileSystemException {
        // still busy; the OS cleans the temp directory
      }
    }
    const script = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
rm -rf "$2" && mv "$3" "$2" && xattr -dr com.apple.quarantine "$2"
open "$2"
''';
    await Process.start('/bin/sh', [
      '-c',
      script,
      'sh',
      '$pid',
      bundle,
      staged,
    ], mode: ProcessStartMode.detached);
    exitApp();
  }
}

// -------------------------------------------------------------------- Linux

/// Replaces the running AppImage file (`$APPIMAGE`) atomically and relaunches.
class AppImageInstaller implements UpdateInstaller {
  AppImageInstaller(this.target);

  final String target;

  @override
  Future<void> install(
    File verified, {
    required void Function() exitApp,
  }) async {
    // Same directory as the target so that the rename is atomic.
    final staged = File('$target.new');
    try {
      await verified.copy(staged.path);
      final ch = await Process.run('chmod', ['755', staged.path]);
      if (ch.exitCode != 0) throw InstallException('chmod: ${ch.stderr}');
      await staged.rename(target);
    } on FileSystemException catch (e) {
      if (await staged.exists()) await staged.delete();
      throw InstallException(
        '${e.message} ${e.path ?? ''}'.trim(),
        noPermission: true,
      );
    }
    await Process.start(target, const [], mode: ProcessStartMode.detached);
    exitApp();
  }
}
