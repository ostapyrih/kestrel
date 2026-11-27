import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'notification_prefs_store.dart';

/// The Android foreground service that keeps the process (and with it the
/// Reticulum connection, the LXMF router and the bridge Link) alive while the
/// app is in the background. Implemented natively (`KeepAliveService`).
abstract class BackgroundService {
  /// Shows the persistent notification and starts the service.
  Future<void> start({required String title, required String text});
  Future<void> stop();

  /// True if the system does not restrict this app's battery use.
  Future<bool> batteryExempt();

  /// Opens the system prompt that exempts the app from battery optimisation.
  Future<void> requestBatteryExemption();
}

class AndroidBackgroundService implements BackgroundService {
  static const _channel = MethodChannel('com.ostapyrih.kestrel/background');

  @override
  Future<void> start({required String title, required String text}) =>
      _call('start', {'title': title, 'text': text});

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<bool> batteryExempt() async =>
      (await _call<bool>('batteryExempt')) ?? false;

  @override
  Future<void> requestBatteryExemption() => _call('requestBatteryExemption');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('background service: $method failed: $e');
    } on MissingPluginException {
      // not on Android (tests)
    }
    return null;
  }
}

/// The service on this platform; null where there is none (everything but
/// Android: desktop keeps running in the tray, iOS uses background tasks).
BackgroundService? platformBackgroundService() =>
    Platform.isAndroid ? AndroidBackgroundService() : null;

/// Starts or stops the service according to the "Run in background" setting
/// (default on).
class BackgroundModeController {
  BackgroundModeController({
    required this.service,
    required this.isOn,
    required this.title,
    required this.text,
  });

  final BackgroundService? service;
  final Future<bool> Function() isOn;
  final String Function() title;
  final String Function() text;
  bool? _running;

  /// Brings the service in line with the setting.
  Future<void> apply() async {
    final s = service;
    if (s == null) return;
    final want = await isOn();
    if (want == _running) return;
    _running = want;
    if (want) {
      await s.start(title: title(), text: text());
    } else {
      await s.stop();
    }
  }

  Future<void> shutdown() async {
    _running = false;
    await service?.stop();
  }

  /// The setting itself.
  static Future<bool> readSetting(NotificationPrefsStore store) =>
      store.backgroundOn();
}
