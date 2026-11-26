import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/bridge_connection.dart';
import '../bridge/bridge_service.dart';
import '../bridge/codec.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/repo.dart';

/// Text of a bridge state for the indicator.
String bridgeStateText(Strings s, BridgeStatus st) => switch (st.state) {
  BridgeState.off => s.t('bridge_status_off'),
  BridgeState.connecting => s.t('bridge_status_connecting'),
  BridgeState.connected => s.t('bridge_status_connected'),
  BridgeState.unreachable =>
    st.fallback
        ? s.t('bridge_status_unreachable_lxmf')
        : s.t('bridge_status_unreachable'),
  BridgeState.rejected => s.t('bridge_status_rejected'),
  BridgeState.awaitingApproval => s.t('bridge_status_awaiting_approval'),
  BridgeState.revoked => s.t('bridge_status_revoked'),
  BridgeState.mismatch => s.t('bridge_status_mismatch'),
};

/// Longer explanation for states that need user action, else null.
String? bridgeStateHelp(Strings s, BridgeStatus st) {
  switch (st.state) {
    case BridgeState.rejected:
      return s.t('bridge_rejected_detail');
    case BridgeState.awaitingApproval:
      return s.t('bridge_awaiting_approval_detail');
    case BridgeState.revoked:
      return s.t('bridge_revoked_banner');
    case BridgeState.mismatch:
      final m = st.mismatch ?? const {};
      return s.t('bridge_mismatch_detail', {
        'server': '${m['server_version'] ?? '?'}',
        'min': '${m['min_version'] ?? '?'}',
        'max': '${m['max_version'] ?? '?'}',
        'client': '${m['client_version'] ?? bridgeProtocolVersion}',
      });
    case BridgeState.connected:
      final h = st.hello;
      if (h != null && h.upstreamIncompatible) {
        return s.t('bridge_meshchatx_incompatible', {
          'version': h.meshchatxVersion ?? '?',
        });
      }
      if (st.detail == 'upstream_unavailable' ||
          (h != null && !h.compatChecked)) {
        return s.t('bridge_upstream_starting');
      }
      return null;
    default:
      return null;
  }
}

/// `Міст: онлайн` next to the TCP indicator (connected / connecting /
/// unreachable / revoked...).
class BridgeIndicator extends StatelessWidget {
  const BridgeIndicator(this.status, {super.key});
  final BridgeStatus status;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final color = switch (status.state) {
      BridgeState.connected => Colors.green,
      BridgeState.connecting => Colors.orange,
      BridgeState.off => cs.outline,
      _ => cs.error,
    };
    return Row(
      key: const ValueKey('bridge-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            bridgeStateText(s, status),
            style: Theme.of(context).textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Message text for an error of a bridge action.
String bridgeErrorText(Strings s, Object e) {
  if (e is VaultKeysUnsupported) return s.t('vault_unsupported');
  if (e is RrcCommandBlocked) return s.t('room_send_blocked');
  if (e is InviteExpired) return s.t('invite_expired_local');
  if (e is BridgeNotConfigured || e is BridgeTransportError) {
    return s.t('bridge_not_connected');
  }
  if (e is BridgeError) {
    return switch (e.code) {
      'pairing_expired' => s.t('pair_expired'),
      'pairing_replay' => s.t('pair_replay'),
      'pairing_invalid' => s.t('pair_invalid'),
      'device_exists' => s.t('pair_exists'),
      'vault_in_use' => s.t('pair_invite_unavailable'),
      _ => s.t('error_code', {'code': e.code}),
    };
  }
  return '$e';
}

/// The choices of the "turn the bridge off" confirmation.
enum TurnOffChoice { cancel, sendFromB, discard }

/// Asks before the bridge goes off: account A's chats are removed from this
/// device (they stay in MeshChatX). Unsent A messages are not on MeshChatX
/// yet, so when there are [queued] the dialog says they will be lost and
/// offers to send them from this device (B) instead. Cancel has the focus.
Future<TurnOffChoice?> confirmTurnOffBridge(
  BuildContext context, {
  required int queued,
}) {
  final s = Strings.of(context);
  return showDialog<TurnOffChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('bridge-off-dialog'),
      title: Text(s.t('bridge_off_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('bridge_off_body')),
          if (queued > 0) ...[
            const SizedBox(height: 12),
            Text(
              s.t('bridge_off_queued', {'n': '$queued'}),
              key: const ValueKey('bridge-off-queued'),
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('bridge-off-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(ctx).pop(TurnOffChoice.cancel),
          child: Text(s.t('cancel')),
        ),
        if (queued > 0)
          TextButton(
            key: const ValueKey('bridge-off-send-b'),
            onPressed: () => Navigator.of(ctx).pop(TurnOffChoice.sendFromB),
            child: Text(s.t('bridge_off_send_b')),
          ),
        TextButton(
          key: const ValueKey('bridge-off-confirm'),
          onPressed: () => Navigator.of(ctx).pop(TurnOffChoice.discard),
          child: Text(
            queued > 0 ? s.t('bridge_off_discard') : s.t('bridge_off_confirm'),
          ),
        ),
      ],
    ),
  );
}

/// What the user can do with a queued A message while the bridge cannot take
/// it: wait (nothing), cancel, or explicitly send from B instead. Never
/// automatic.
class QueuedBridgeActions extends ConsumerStatefulWidget {
  const QueuedBridgeActions({super.key, required this.message});
  final MessageRow message;

  @override
  ConsumerState<QueuedBridgeActions> createState() =>
      _QueuedBridgeActionsState();
}

class _QueuedBridgeActionsState extends ConsumerState<QueuedBridgeActions> {
  bool _waiting = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final st = ref.watch(bridgeStatusProvider).value;
    final canSend = st != null && (st.connected || st.fallback);
    if (st == null || canSend || _waiting) return const SizedBox.shrink();
    final off = st.state == BridgeState.off;
    final bridge = ref.read(bridgeProvider);
    final id = widget.message.id;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            off ? s.t('bridge_off_msg') : s.t('bridge_unreachable_msg'),
            key: ValueKey('bridge-unreachable-$id'),
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                key: ValueKey('wait-$id'),
                onPressed: () => setState(() => _waiting = true),
                child: Text(s.t('action_wait')),
              ),
              TextButton(
                key: ValueKey('cancel-$id'),
                onPressed: () => unawaited(bridge.cancelQueued(id)),
                child: Text(s.t('action_cancel')),
              ),
              TextButton(
                key: ValueKey('send-b-$id'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final done = s.t('send_b_done');
                  final r = await bridge.sendFromBInstead(id);
                  if (r != null) {
                    messenger.showSnackBar(SnackBar(content: Text(done)));
                  }
                },
                child: Text(s.t('action_send_b')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
