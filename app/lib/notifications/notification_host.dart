import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import 'notification_prefs_store.dart';
import 'notification_providers.dart';
import 'notification_strings.dart';

/// First-run prompts on mobile: the notification permission (Android 13+,
/// iOS) and, on Android, the explanation before the battery-optimisation
/// exemption. Each is asked once; Settings keeps the controls.
class NotificationHost extends ConsumerStatefulWidget {
  const NotificationHost({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget? child;

  @override
  ConsumerState<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends ConsumerState<NotificationHost> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ask()));
    }
  }

  Future<void> _ask() async {
    try {
      final repo = ref.read(repoProvider);
      final sink = ref.read(notificationSinkProvider);
      if (await repo.getSetting(NotifKeys.askedPermission) != '1') {
        await repo.setSetting(NotifKeys.askedPermission, '1');
        await sink?.requestPermission();
      }
      final service = ref.read(backgroundServiceProvider);
      if (service == null ||
          await repo.getSetting(NotifKeys.askedBattery) == '1' ||
          await service.batteryExempt()) {
        return;
      }
      await repo.setSetting(NotifKeys.askedBattery, '1');
      final ctx = widget.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final go = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: Text(nf(c, 'n_battery')),
          content: Text(nf(c, 'n_battery_why')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(nf(c, 'n_later')),
            ),
            FilledButton(
              key: const ValueKey('battery-allow'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(nf(c, 'n_allow')),
            ),
          ],
        ),
      );
      if (go ?? false) await service.requestBatteryExemption();
    } on Object {
      // prompts are a convenience; Settings has the same controls
    }
  }

  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}
