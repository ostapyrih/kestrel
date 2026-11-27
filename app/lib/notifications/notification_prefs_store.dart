import '../storage/repo.dart';
import 'notification_models.dart';

/// Settings keys of the notification feature.
abstract final class NotifKeys {
  static const enabled = 'notif_enabled';
  static const content = 'notif_content';
  static const sound = 'notif_sound';
  static const muted = 'notif_muted';

  /// Android foreground service ("Run in background"); default on.
  static const background = 'run_in_background';

  /// The one-time permission / battery explanations were shown.
  static const askedBattery = 'notif_asked_battery';
  static const askedPermission = 'notif_asked_permission';
}

/// Reads and writes [NotificationPrefs] in the settings table. Every flag
/// defaults to on; the mutes are a list of [muteKey]s.
class NotificationPrefsStore {
  NotificationPrefsStore(this.repo);
  final Repo repo;

  Future<NotificationPrefs> load() async => NotificationPrefs(
    enabled: flag(await repo.getSetting(NotifKeys.enabled)),
    showContent: flag(await repo.getSetting(NotifKeys.content)),
    sound: flag(await repo.getSetting(NotifKeys.sound)),
    mutedChats: parseMuted(await repo.getSetting(NotifKeys.muted)),
  );

  Future<bool> backgroundOn() async =>
      flag(await repo.getSetting(NotifKeys.background));

  Future<void> setFlag(String key, bool on) =>
      repo.setSetting(key, on ? '1' : '0');

  Future<void> setMuted(String identity, String? peerHash, bool muted) async {
    final set = parseMuted(await repo.getSetting(NotifKeys.muted));
    final k = muteKey(identity, peerHash);
    if (muted ? !set.add(k) : !set.remove(k)) return;
    await repo.setSetting(NotifKeys.muted, set.join('\n'));
  }

  static bool flag(String? stored) => stored != '0';

  static Set<String> parseMuted(String? stored) => {
    for (final l in (stored ?? '').split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  };
}
