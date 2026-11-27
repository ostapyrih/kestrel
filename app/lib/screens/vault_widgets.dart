import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/vault_service.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/repo.dart';
import '../platform.dart';
import 'chat_screen.dart';
import 'widgets.dart';

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KiB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

String vaultStateText(Strings s, VaultState st) => switch (st) {
  VaultState.off => s.t('vault_state_off'),
  VaultState.needsKey => s.t('vault_state_needs_key'),
  VaultState.syncing => s.t('vault_state_syncing'),
  VaultState.idle => s.t('vault_state_idle'),
  VaultState.quotaFull => s.t('vault_state_quota_full'),
  VaultState.error => s.t('vault_state_error'),
};

/// Settings: state of the history sync (only shown while the bridge is on).
class VaultSettingsSection extends ConsumerWidget {
  const VaultSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final st = ref.watch(vaultStatusProvider).value;
    final text = Theme.of(context).textTheme;
    if (st == null) return const SizedBox.shrink();
    final names = {
      for (final d in ref.watch(bridgeDevicesProvider).value ?? const [])
        d.deviceId: d.name,
    };
    return Column(
      key: const ValueKey('vault-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(s.t('vault_title'), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          vaultStateText(s, st.state),
          key: const ValueKey('vault-state'),
          style:
              st.state == VaultState.error || st.state == VaultState.quotaFull
              ? text.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                )
              : text.bodyMedium,
        ),
        if (st.state == VaultState.needsKey)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.t('vault_needs_key_help'),
              key: const ValueKey('vault-needs-key-help'),
              style: text.bodySmall,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          s.t('vault_last_sync', {
            'time': st.lastSync == null
                ? s.t('vault_never')
                : formatTime(st.lastSync!.millisecondsSinceEpoch),
          }),
          key: const ValueKey('vault-last-sync'),
          style: text.bodySmall,
        ),
        Text(
          s.t('vault_usage', {
            'used': formatBytes(st.usedBytes),
            'quota': st.quotaBytes > 0 ? formatBytes(st.quotaBytes) : '?',
          }),
          key: const ValueKey('vault-usage'),
          style: text.bodySmall,
        ),
        Text(
          s.t('vault_remote_devices', {'n': '${st.remoteDevices}'}),
          key: const ValueKey('vault-remote-devices'),
          style: text.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(s.t('vault_diag_title'), style: text.labelLarge),
        Text(
          s.t('vault_diag_uploaded', {'n': '${st.uploadedBlobs}'}),
          key: const ValueKey('vault-diag-uploaded'),
          style: text.bodySmall,
        ),
        if (st.downloaded.isEmpty)
          Text(
            s.t('vault_diag_none'),
            key: const ValueKey('vault-diag-none'),
            style: text.bodySmall,
          ),
        for (final e in st.downloaded.entries)
          Text(
            s.t('vault_diag_downloaded', {
              'device': names[e.key] ?? shortHash(e.key),
              'n': '${e.value}',
            }),
            key: ValueKey('vault-diag-from-${e.key}'),
            style: text.bodySmall,
          ),
        if (st.lastError != null)
          Text(
            s.t('vault_diag_error', {'err': st.lastError!}),
            key: const ValueKey('vault-diag-error'),
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('vault-sync-now'),
          icon: const Icon(Icons.sync),
          label: Text(s.t('vault_sync_now')),
          onPressed: st.state == VaultState.syncing
              ? null
              : () {
                  final b = ref.read(bridgeProvider);
                  unawaited(b.vault.syncNow());
                  unawaited(b.resync());
                },
        ),
        const SizedBox(height: 4),
        Text(s.t('vault_note'), style: text.bodySmall),
      ],
    );
  }
}

/// The read-only banner of a remote history plus the reply button, shown instead
/// of the composer in a chat synced from another device.
class ReadOnlyBanner extends ConsumerWidget {
  const ReadOnlyBanner({super.key, required this.chat});
  final ChatRow chat;

  Future<void> _reply(
    BuildContext context,
    WidgetRef ref, {
    required bool bridgeOn,
  }) async {
    final peer = chat.peerHash;
    if (peer == null) return;
    final s = Strings.of(context);
    var identity = 'B';
    if (bridgeOn) {
      final picked = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(s.t('vault_reply_title'))),
              ListTile(
                key: const ValueKey('reply-as-B'),
                title: Text(
                  s.account('B', device: ref.read(ownDeviceNameProvider)),
                ),
                onTap: () => Navigator.of(ctx).pop('B'),
              ),
              ListTile(
                key: const ValueKey('reply-as-A'),
                title: Text(s.account('A')),
                onTap: () => Navigator.of(ctx).pop('A'),
              ),
            ],
          ),
        ),
      );
      if (picked == null) return;
      identity = picked;
    }
    final id = identity == 'A'
        ? await ref
              .read(bridgeProvider)
              .store
              .ensureChat(peer, name: chat.title)
        : await ref.read(nodeProvider).openChat(peer, name: chat.title);
    if (!context.mounted) return;
    if (MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint) {
      ref.read(selectedChatProvider.notifier).select(id);
    } else {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: id)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final bridgeOn = ref.watch(bridgeConfiguredProvider).value ?? false;
    return Container(
      key: const ValueKey('readonly-banner'),
      width: double.infinity,
      color: cs.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('vault_readonly', {'device': chat.remoteDeviceName ?? '?'}),
              key: const ValueKey('readonly-text'),
              style: TextStyle(color: cs.onSecondaryContainer),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: const ValueKey('vault-reply'),
                onPressed: () => _reply(context, ref, bridgeOn: bridgeOn),
                child: Text(s.t('vault_reply')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
