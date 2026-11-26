import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart' show fromHex, toHex, Identity;
import 'package:material_ui/material_ui.dart';

import '../bridge/codec.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import 'add_device_screen.dart';
import 'bridge_widgets.dart';
import 'widgets.dart';

/// Settings -> My devices: the device registry of the bridge.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      await ref.read(bridgeProvider).refreshDevices();
    } on Object {
      // offline: the cached list stays
    }
  }

  void _toast(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(bridgeErrorText(Strings.of(context), e))),
    );
  }

  Future<void> _rename(DeviceRecord d) async {
    final s = Strings.of(context);
    final c = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('device_rename')),
        content: TextField(
          key: const ValueKey('rename-input'),
          controller: c,
          autofocus: true,
          maxLength: 64,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('rename-ok'),
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(s.t('save')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == d.name) return;
    try {
      await ref.read(bridgeProvider).renameDevice(d.deviceId, name);
    } on Object catch (e) {
      _toast(e);
    }
  }

  Future<void> _revoke(DeviceRecord d) async {
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('revoke-dialog'),
        title: Text(s.t('device_revoke_title')),
        content: Text(s.t('device_revoke_body', {'name': d.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('revoke-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('device_revoke')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(bridgeProvider).revokeDevice(d.deviceId);
    } on Object catch (e) {
      _toast(e);
    }
  }

  Future<void> _toggleField(DeviceRecord d, bool on) async {
    try {
      await ref.read(bridgeProvider).setFieldRole(d.deviceId, on);
    } on Object catch (e) {
      _toast(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final devices =
        ref.watch(bridgeDevicesProvider).value ?? const <DeviceRecord>[];
    final own = ref.watch(ownDeviceIdProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('my_devices')),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('add-device'),
        icon: const Icon(Icons.add),
        label: Text(s.t('add_device')),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AddDeviceScreen()),
        ),
      ),
      body: devices.isEmpty
          ? Center(child: Text(s.t('devices_empty')))
          : ListView(
              children: [
                for (final d in devices)
                  _DeviceTile(
                    device: d,
                    isThis: d.deviceId == own,
                    onRename: () => _rename(d),
                    onRevoke: () => _revoke(d),
                    onField: (v) => _toggleField(d, v),
                  ),
              ],
            ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.isThis,
    required this.onRename,
    required this.onRevoke,
    required this.onField,
  });

  final DeviceRecord device;
  final bool isThis;
  final VoidCallback onRename;
  final VoidCallback onRevoke;
  final ValueChanged<bool> onField;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final d = device;
    final seen = d.lastSeen == null
        ? null
        : s.t('device_last_seen', {
            'time': formatTime((d.lastSeen! * 1000).round()),
          });
    return ListTile(
      key: ValueKey('device-${d.deviceId}'),
      enabled: !d.isRevoked,
      leading: Icon(
        _platformIcon(d.platform),
        color: d.isRevoked ? cs.outline : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              d.name,
              overflow: TextOverflow.ellipsis,
              style: d.isRevoked
                  ? const TextStyle(decoration: TextDecoration.lineThrough)
                  : null,
            ),
          ),
          if (isThis) ...[
            const SizedBox(width: 8),
            Text(
              '(${s.t('device_this')})',
              key: ValueKey('this-${d.deviceId}'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
      subtitle: Wrap(
        spacing: 8,
        children: [
          Text(d.platform),
          if (d.isRevoked)
            Text(
              s.t('device_revoked'),
              key: ValueKey('revoked-${d.deviceId}'),
              style: TextStyle(color: cs.error),
            )
          else
            Text(
              (d.online || isThis)
                  ? s.t('device_online')
                  : s.t('device_offline'),
              key: ValueKey('online-${d.deviceId}'),
              style: TextStyle(
                color: (d.online || isThis) ? Colors.green : cs.outline,
              ),
            ),
          if (d.isField) Text(s.t('device_field')),
          if (seen != null) Text(seen),
        ],
      ),
      trailing: d.isRevoked
          ? null
          : PopupMenuButton<String>(
              key: ValueKey('menu-${d.deviceId}'),
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    onRename();
                  case 'field':
                    onField(!d.isField);
                  case 'revoke':
                    onRevoke();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(s.t('device_rename')),
                ),
                CheckedPopupMenuItem(
                  value: 'field',
                  checked: d.isField,
                  child: Text(s.t('device_set_field')),
                ),
                PopupMenuItem(
                  value: 'revoke',
                  child: Text(
                    s.t('device_revoke'),
                    style: TextStyle(color: cs.error),
                  ),
                ),
              ],
            ),
    );
  }
}

IconData _platformIcon(String p) => switch (p) {
  'android' || 'ios' => Icons.smartphone,
  'windows' || 'macos' || 'linux' => Icons.computer,
  _ => Icons.devices_other,
};

/// Device id of identity B (hash of the public key) for the settings data.
final ownDeviceIdProvider = Provider<String?>((ref) {
  final info = ref.watch(identityInfoProvider).value;
  if (info == null) return null;
  return toHex(Identity.fromPublicKey(fromHex(info.publicKey)).hash);
});
