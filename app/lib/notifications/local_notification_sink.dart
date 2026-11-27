import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_models.dart';

/// Called when the user taps a notification; [chatId] is the chat it names.
typedef NotificationTapHandler = void Function(int chatId);

const _androidIcon = '@drawable/ic_stat_kestrel';
const _channelSound = 'messages';
const _channelSilent = 'messages_silent';

/// [NotificationSink] on `flutter_local_notifications`: Android notification
/// channels, iOS/macOS UserNotifications, Linux DBus, Windows toasts.
///
/// Windows limitation of the plugin: an app that is not MSIX-packaged cannot
/// withdraw a toast it showed, so "read elsewhere" cannot clear those there.
class LocalNotificationSink implements NotificationSink {
  LocalNotificationSink({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// Initialises the plugin. [onTap] runs for a tap while the app lives. The
  /// result is the chat a tap launched the app with (cold start), if any.
  Future<int?> init({NotificationTapHandler? onTap}) async {
    const darwin = DarwinInitializationSettings(
      // asked explicitly by requestPermission()
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_androidIcon),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'Kestrel',
            appUserModelId: 'com.ostapyrih.Kestrel',
            guid: '6f1b7a3e-5d1e-4b7e-9a57-2c3d0f6e8a41',
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = chatIdOfPayload(r.payload);
          if (id != null) onTap?.call(id);
        },
      );
      _ready = true;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        return chatIdOfPayload(launch!.notificationResponse?.payload);
      }
    } on Object catch (e) {
      debugPrint('notifications: init failed: $e');
    }
    return null;
  }

  /// Asks for the permission to show notifications (Android 13+, iOS, macOS).
  /// True if granted or not needed.
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Platform.isAndroid) {
        final a = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        return await a?.requestNotificationsPermission() ?? true;
      }
      if (Platform.isIOS) {
        final i = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await i?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
      if (Platform.isMacOS) {
        final m = _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        return await m?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
    } on Object catch (e) {
      debugPrint('notifications: permission request failed: $e');
      return false;
    }
    return true;
  }

  int _id(int chatId) => chatId & 0x7fffffff;

  @override
  Future<void> show(NotificationRequest r) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _id(r.chatId),
        title: r.title,
        body: r.body,
        payload: r.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            r.sound ? _channelSound : _channelSilent,
            r.sound ? 'Messages' : 'Messages (silent)',
            channelDescription: 'New messages',
            importance: Importance.high,
            priority: Priority.high,
            playSound: r.sound,
            category: AndroidNotificationCategory.message,
            number: r.count,
            onlyAlertOnce: r.count > 1,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: r.sound,
            threadIdentifier: 'chat-${r.chatId}',
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: r.sound,
            threadIdentifier: 'chat-${r.chatId}',
          ),
          linux: LinuxNotificationDetails(
            suppressSound: !r.sound,
            category: LinuxNotificationCategory.imReceived,
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } on Object catch (e) {
      debugPrint('notifications: show failed: $e');
    }
  }

  @override
  Future<void> cancelChat(int chatId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _id(chatId));
    } on Object catch (e) {
      debugPrint('notifications: cancel failed: $e');
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } on Object catch (e) {
      debugPrint('notifications: cancelAll failed: $e');
    }
  }
}
