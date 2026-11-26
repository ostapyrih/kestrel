import 'dart:io';

import 'package:path/path.dart' as p;

import 'releases.dart';

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

/// Runs the Inno Setup installer silently once this process has exited, then
/// starts the installed app. The installer is per-user (no admin rights).
class WindowsInstaller implements UpdateInstaller {
  static const script = r'''
param([int]$AppPid, [string]$Installer, [string]$Exe)
try { Wait-Process -Id $AppPid -Timeout 60 -ErrorAction SilentlyContinue } catch {}
$p = Start-Process -FilePath $Installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
if (Test-Path $Exe) { Start-Process -FilePath $Exe }
''';

  /// The per-user install location of the Inno Setup installer.
  static String installedExe() => p.join(
    Platform.environment['LOCALAPPDATA'] ?? '',
    'Programs',
    'Kestrel',
    'kestrel.exe',
  );

  @override
  Future<void> install(
    File verified, {
    required void Function() exitApp,
  }) async {
    final dir = verified.parent.path;
    final ps1 = File(p.join(dir, 'kestrel-update.ps1'));
    await ps1.writeAsString(script);
    // Relaunch the copy the user runs if it is the installed one, otherwise the
    // freshly installed copy.
    final running = Platform.resolvedExecutable;
    final exe = p.isWithin(p.dirname(installedExe()), running)
        ? running
        : installedExe();
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      ps1.path,
      '-AppPid',
      '$pid',
      '-Installer',
      verified.path,
      '-Exe',
      exe,
    ], mode: ProcessStartMode.detached);
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
      if (a.exitCode != 0)
        throw InstallException('hdiutil attach: ${a.stderr}');
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
