import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../platform.dart';
import '../storage/repo.dart';
import 'installer.dart';
import 'release_key.dart';
import 'update_service.dart';
import 'version.dart';

/// Builds the updater for this platform. Mobile gets an inert service (iOS
/// updates through AltStore, Android through Obtainium).
Future<UpdateService> createUpdateService(Repo repo) async {
  if (!isDesktop) return UpdateService.disabled();
  final info = await PackageInfo.fromPlatform();
  final current = AppVersion.tryParse(info.version);
  final platform = currentUpdatePlatform();
  if (current == null || platform == null) return UpdateService.disabled();
  return UpdateService(
    currentVersion: current,
    platform: platform,
    tempDir: await getTemporaryDirectory(),
    installer: installerForCurrentPlatform(),
    linuxAppImage: Platform.environment['APPIMAGE'] != null,
    autoCheckEnabled: () async =>
        await repo.getSetting(updateAutoCheckKey) != '0',
  );
}
