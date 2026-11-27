import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../platform.dart';
import 'notification_prefs_store.dart';
import 'notification_providers.dart';
import 'notification_strings.dart';

/// Settings section "Notifications": enable, content, sound, background mode
/// (Android) and the honest note about iOS.
class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPrefsProvider).value;
    NotificationPrefsStore store() => ref.read(notificationPrefsStoreProvider);
    final on = prefs?.enabled ?? true;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(nf(context, 'n_title'), style: text.titleMedium),
        SwitchListTile(
          key: const ValueKey('notif-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(nf(context, 'n_enable')),
          value: on,
          onChanged: (v) async {
            await store().setFlag(NotifKeys.enabled, v);
            if (v) {
              await ref.read(notificationSinkProvider)?.requestPermission();
            }
          },
        ),
        SwitchListTile(
          key: const ValueKey('notif-content'),
          contentPadding: EdgeInsets.zero,
          title: Text(nf(context, 'n_content')),
          subtitle: Text(nf(context, 'n_content_hint')),
          value: prefs?.showContent ?? true,
          onChanged: on ? (v) => store().setFlag(NotifKeys.content, v) : null,
        ),
        SwitchListTile(
          key: const ValueKey('notif-sound'),
          contentPadding: EdgeInsets.zero,
          title: Text(nf(context, 'n_sound')),
          value: prefs?.sound ?? true,
          onChanged: on ? (v) => store().setFlag(NotifKeys.sound, v) : null,
        ),
        if (Platform.isAndroid) const _AndroidBackground(),
        if (Platform.isIOS)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              nf(context, 'n_ios_info'),
              key: const ValueKey('notif-ios-info'),
              style: text.bodySmall,
            ),
          ),
        if (isDesktop)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(nf(context, 'n_desktop_info'), style: text.bodySmall),
          ),
      ],
    );
  }
}

class _AndroidBackground extends ConsumerStatefulWidget {
  const _AndroidBackground();

  @override
  ConsumerState<_AndroidBackground> createState() => _AndroidBackgroundState();
}

class _AndroidBackgroundState extends ConsumerState<_AndroidBackground> {
  Future<bool>? _exempt;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _exempt = ref.read(backgroundServiceProvider)?.batteryExempt();
  }

  @override
  Widget build(BuildContext context) {
    final bg = ref.watch(runInBackgroundProvider).value ?? true;
    return Column(
      children: [
        SwitchListTile(
          key: const ValueKey('notif-background'),
          contentPadding: EdgeInsets.zero,
          title: Text(nf(context, 'n_background')),
          subtitle: Text(nf(context, 'n_background_hint')),
          value: bg,
          onChanged: (v) async {
            await ref
                .read(notificationPrefsStoreProvider)
                .setFlag(NotifKeys.background, v);
            await ref.read(backgroundModeProvider)?.apply();
          },
        ),
        FutureBuilder<bool>(
          future: _exempt,
          builder: (context, snap) {
            final ok = snap.data ?? false;
            return ListTile(
              key: const ValueKey('notif-battery'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                ok ? Icons.battery_charging_full : Icons.battery_alert,
              ),
              title: Text(nf(context, ok ? 'n_battery_ok' : 'n_battery')),
              subtitle: ok ? null : Text(nf(context, 'n_battery_hint')),
              onTap: ok
                  ? null
                  : () async {
                      await ref
                          .read(backgroundServiceProvider)
                          ?.requestBatteryExemption();
                      if (mounted) setState(_refresh);
                    },
            );
          },
        ),
      ],
    );
  }
}
