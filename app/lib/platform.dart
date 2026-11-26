import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Application windows at least this wide (logical px) get the two-pane layout.
const double wideLayoutBreakpoint = 900;

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// sqflite has no desktop plugin; on desktop it runs on `sqlite3` via FFI
/// (the sqlite3 package bundles the native library). Mobile is unchanged.
void initDatabaseFactory() {
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}

/// Default for the per-install "device name" setting.
String defaultDeviceName() {
  if (Platform.isWindows) return 'Windows PC';
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iPhone';
  return 'Device';
}

/// Platform name for the bridge protocol (`[a-z0-9][a-z0-9._-]*`).
String platformId() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'unknown';
}
