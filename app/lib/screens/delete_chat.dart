import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/codec.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/repo.dart';
import 'bridge_widgets.dart';

/// Upper bound for the whole delete action (the bridge call has its own,
/// shorter timeout).
const deleteFlowTimeout = Duration(seconds: 30);

/// Whether [chat] can be deleted at all (RRC rooms have their own leave).
bool isDeletable(ChatRow chat) => chat.kind == 'lxmf';

/// Short explanation for a [NodeService.deleteBlockReason] key.
String deleteBlockText(Strings s, String reason) => s.t(reason);

/// The confirmation: says exactly what will happen for every kind of chat in
/// [chats]. Cancel has the focus. When [blockReason] is set the delete button
/// is disabled and the reason is shown instead. True = delete.
Future<bool> confirmDeleteChats(
  BuildContext context, {
  required List<ChatRow> chats,
  required int unsent,
  required bool bridgeMode,
  String? blockReason,
}) async {
  final s = Strings.of(context);
  final own = chats.where((c) => !c.isRemote && c.accountIdentity == 'B');
  final a = chats.where((c) => !c.isRemote && c.accountIdentity == 'A');
  final remote = chats.where((c) => c.isRemote);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('delete-chat-dialog'),
      title: Text(
        chats.length == 1
            ? s.t('delete_title', {'name': chats.first.displayTitle})
            : s.t('delete_title_n', {'n': '${chats.length}'}),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (own.isNotEmpty)
              Text(s.t('delete_b_body'), key: const ValueKey('delete-b-body')),
            if (own.isNotEmpty && bridgeMode)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  s.t('delete_b_vault'),
                  key: const ValueKey('delete-b-vault'),
                ),
              ),
            if (a.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: own.isEmpty ? 0 : 12),
                child: Text(
                  s.t('delete_a_body'),
                  key: const ValueKey('delete-a-body'),
                ),
              ),
            for (final c in remote)
              Padding(
                padding: EdgeInsets.only(
                  top: own.isEmpty && a.isEmpty && c == remote.first ? 0 : 12,
                ),
                child: Text(
                  s.t('delete_remote_body', {
                    'device': c.remoteDeviceName ?? '?',
                  }),
                  key: const ValueKey('delete-remote-body'),
                ),
              ),
            if (unsent > 0) ...[
              const SizedBox(height: 12),
              Text(
                s.t('delete_unsent', {'n': '$unsent'}),
                key: const ValueKey('delete-unsent'),
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(s.t('delete_irreversible')),
            if (blockReason != null) ...[
              const SizedBox(height: 12),
              Text(
                deleteBlockText(s, blockReason),
                key: const ValueKey('delete-blocked'),
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('delete-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(s.t('cancel')),
        ),
        TextButton(
          key: const ValueKey('delete-confirm'),
          onPressed: blockReason == null
              ? () => Navigator.of(ctx).pop(true)
              : null,
          child: Text(
            s.t('delete_confirm'),
            style: blockReason == null
                ? TextStyle(color: Theme.of(ctx).colorScheme.error)
                : null,
          ),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirms and deletes [chats]; true if they were deleted. Errors of the
/// bridge become a snackbar and nothing local is removed for those chats.
Future<bool> deleteChatsFlow(
  BuildContext context,
  WidgetRef ref,
  List<ChatRow> chats,
) async {
  final list = chats.where(isDeletable).toList();
  if (list.isEmpty) return false;
  final node = ref.read(nodeProvider);
  final ids = [for (final c in list) c.id];
  final unsent = await node.unsentCount(ids);
  final reason = await node.deleteBlockReason(ids);
  if (!context.mounted) return false;
  final ok = await confirmDeleteChats(
    context,
    chats: list,
    unsent: unsent,
    bridgeMode: ref.read(bridgeModeProvider),
    blockReason: reason,
  );
  if (!ok || !context.mounted) return false;
  // a visible, bounded wait: the bridge call times out on its own, so this
  // never turns into an endless spinner
  final nav = Navigator.of(context, rootNavigator: true);
  final working = Strings.of(context).t('delete_progress');
  var progressShown = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('delete-progress'),
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Text(working),
            ],
          ),
        ),
      ),
    ),
  );
  void closeProgress() {
    if (progressShown) {
      progressShown = false;
      nav.pop();
    }
  }

  try {
    await node
        .deleteChats(ids)
        .timeout(
          deleteFlowTimeout,
          onTimeout: () => throw BridgeTransportError('request timed out'),
        );
    closeProgress();
  } on Object catch (e) {
    closeProgress();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(bridgeErrorText(Strings.of(context), e))),
      );
    }
    return false;
  }
  return true;
}

/// Why deleting [chatId] is disabled right now, for menu items.
final deleteBlockProvider = FutureProvider.family<String?, int>((
  ref,
  id,
) async {
  try {
    ref.watch(bridgeStatusProvider);
    return await ref.watch(nodeProvider).deleteBlockReason([id]);
  } on Object {
    return null;
  }
});
