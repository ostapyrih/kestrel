import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'background_service.dart';
import 'local_notification_sink.dart';
import 'notification_models.dart';
import 'notification_prefs_store.dart';
import 'notification_runtime.dart';

export 'notification_runtime.dart' show ChatFocus;

/// Which chat is on screen. Overridden in `main()` with the instance the
/// notification runtime uses; a stand-alone one in widget tests.
final chatFocusProvider = Provider<ChatFocus>((ref) => ChatFocus());

/// Overridden in `main()` on platforms that show notifications.
final notificationSinkProvider = Provider<LocalNotificationSink?>(
  (ref) => null,
);

/// Overridden in `main()` on Android.
final backgroundServiceProvider = Provider<BackgroundService?>((ref) => null);

/// Applies the "Run in background" setting. Overridden in `main()`.
final backgroundModeProvider = Provider<BackgroundModeController?>(
  (ref) => null,
);

final notificationPrefsStoreProvider = Provider<NotificationPrefsStore>(
  (ref) => NotificationPrefsStore(ref.watch(repoProvider)),
);

/// The notification settings, live.
final notificationPrefsProvider = StreamProvider<NotificationPrefs>((ref) {
  final repo = ref.watch(repoProvider);
  final store = ref.watch(notificationPrefsStoreProvider);
  return repo.watch(store.load);
});

/// "Run in background" (default on).
final runInBackgroundProvider = StreamProvider<bool>((ref) {
  final repo = ref.watch(repoProvider);
  final store = ref.watch(notificationPrefsStoreProvider);
  return repo.watch(store.backgroundOn);
});
