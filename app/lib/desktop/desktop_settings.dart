import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../platform.dart';
import '../providers.dart';
import 'desktop_strings.dart';

/// Settings key of "Close to tray" ('0' = off; default on).
const closeToTrayKey = 'close_to_tray';

/// Reads the setting (default on).
bool closeToTrayFrom(String? stored) => stored != '0';

/// "Close to tray" switch. Desktop only.
class DesktopSettingsSection extends ConsumerWidget {
  const DesktopSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) return const SizedBox.shrink();
    final on = closeToTrayFrom(
      ref.watch(settingProvider(closeToTrayKey)).value,
    );
    return SwitchListTile(
      key: const ValueKey('close-to-tray'),
      contentPadding: EdgeInsets.zero,
      title: Text(dt(context, 'close_to_tray')),
      subtitle: Text(dt(context, 'close_to_tray_hint')),
      value: on,
      onChanged: (v) =>
          ref.read(repoProvider).setSetting(closeToTrayKey, v ? '1' : '0'),
    );
  }
}
