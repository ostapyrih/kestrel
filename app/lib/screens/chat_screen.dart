import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/codec.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/chat_target.dart';
import '../storage/repo.dart';
import 'bridge_widgets.dart';
import 'delete_chat.dart';
import 'vault_widgets.dart';
import 'widgets.dart';

class ChatScreen extends ConsumerStatefulWidget {
  /// Opens an existing chat ([chatId]) or a draft conversation ([draft],
  /// no database row until the first message is sent).
  const ChatScreen({super.key, this.chatId, this.draft})
    : assert(chatId != null || draft != null);
  final int? chatId;
  final ChatTarget? draft;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _text = TextEditingController();

  /// The chat row; null while this is a draft (nothing stored yet).
  late int? _chatId = widget.chatId;
  late final DraftTexts _drafts;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(draftTextsProvider.notifier);
    final d = widget.draft;
    if (_chatId == null && d != null) {
      _text.text = ref.read(draftTextsProvider)[d.draftKey] ?? '';
      _text.addListener(() {
        // unsent text lives in memory for the session only
        if (_chatId == null) _drafts.set(d.draftKey, _text.text);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final id = _chatId;
      if (id == null) return;
      try {
        final repo = ref.read(repoProvider);
        // A chats: tell the bridge (it also clears the local flag first)
        unawaited(
          ref
              .read(bridgeProvider)
              .markRead(id)
              .catchError((Object _) {})
              .then((_) => repo.markRead(id)),
        );
      } on Object {
        // no repo (widget tests)
      }
    });
  }

  bool _loadingOlder = false;

  Future<void> _loadOlder() async {
    final id = _chatId;
    if (id == null) return;
    setState(() => _loadingOlder = true);
    try {
      await ref.read(bridgeProvider).loadOlder(id);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(bridgeErrorText(Strings.of(context), e))),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    final id = _chatId;
    if (id != null) {
      _text.clear();
      await ref.read(nodeProvider).sendMessage(id, t);
      return;
    }
    final d = widget.draft!;
    _text.clear();
    _drafts.set(d.draftKey, '');
    // first message: creates the chat row, message and outbox row at once
    final sent = await ref.read(nodeProvider).sendToPeer(d, t);
    if (mounted) setState(() => _chatId = sent.chatId);
  }

  String _draftTitle() {
    final d = widget.draft;
    if (d == null) return '';
    return (d.name != null && d.name!.isNotEmpty) ? d.name! : shortHash(d.peer);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final id = _chatId;
    final chat = id == null ? null : ref.watch(chatProvider(id)).value;
    final msgs = id == null
        ? const AsyncValue<List<MessageRow>>.data(<MessageRow>[])
        : ref.watch(messagesProvider(id));
    final identity = chat?.accountIdentity ?? widget.draft?.identity ?? 'B';
    final isA = identity == 'A';
    final deviceNames = isA
        ? {
            for (final d
                in ref.watch(bridgeDevicesProvider).value ??
                    const <DeviceRecord>[])
              d.deviceId: d.name,
          }
        : const <String, String>{};
    // a history synced from another device: read only (vault)
    final remote = chat?.isRemote ?? (id != null && isRemoteId(id));
    final ownDevice = remote
        ? (chat?.remoteDeviceName ?? '')
        : ref.watch(ownDeviceNameProvider);
    final bridgeMode = ref.watch(bridgeModeProvider);
    final olderItem = isA && !(chat?.olderDone ?? true);
    final deleteBlock = id == null
        ? null
        : ref.watch(deleteBlockProvider(id)).value;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (chat != null && isDeletable(chat))
            PopupMenuButton<String>(
              key: const ValueKey('chat-menu'),
              onSelected: (v) async {
                if (v != 'delete') return;
                final done = await deleteChatsFlow(context, ref, [chat]);
                if (!done || !context.mounted) return;
                if (ref.read(selectedChatProvider) == id) {
                  ref.read(selectedChatProvider.notifier).select(null);
                } else if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const ValueKey('menu-delete-chat'),
                  value: 'delete',
                  enabled: deleteBlock == null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.t('delete_chat')),
                      if (deleteBlock != null)
                        Text(
                          s.t(deleteBlock),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
        title: Row(
          children: [
            Flexible(
              child: Text(
                chat?.displayTitle ?? _draftTitle(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (bridgeMode) ...[
              const SizedBox(width: 8),
              if (remote)
                IdentityBadge(
                  'B',
                  key: const ValueKey('badge-remote'),
                  label: s.account('B', device: chat?.remoteDeviceName),
                )
              else
                IdentityBadge(identity),
            ],
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.when(
              data: (list) => ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: list.length + (olderItem ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == list.length) {
                    return Center(
                      child: TextButton(
                        key: const ValueKey('load-older'),
                        onPressed: _loadingOlder ? null : _loadOlder,
                        child: Text(s.t('load_older')),
                      ),
                    );
                  }
                  final m = list[list.length - 1 - i];
                  return MessageBubble(
                    message: m,
                    deviceName: ownDevice,
                    showAccount: bridgeMode,
                    originLabel: originLabel(s, m, deviceNames),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
          if (remote && chat != null)
            ReadOnlyBanner(chat: chat)
          else
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (bridgeMode)
                      Text(
                        isA
                            ? s.t('from_a_bridge')
                            : s.t('from', {'account': s.account(identity)}),
                        key: const ValueKey('composer-from'),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('composer-input'),
                            controller: _text,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: s.t('message_hint'),
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        IconButton.filled(
                          key: const ValueKey('composer-send'),
                          tooltip: s.t('send'),
                          icon: const Icon(Icons.send),
                          onPressed: _send,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

IconData statusIcon(String status) => switch (status) {
  MsgStatus.queued => Icons.schedule,
  MsgStatus.sending => Icons.upload,
  MsgStatus.sent => Icons.done,
  MsgStatus.delivered => Icons.done_all,
  MsgStatus.failed => Icons.error_outline,
  MsgStatus.cancelled => Icons.block,
  _ => Icons.south_west,
};

/// "from iPhone" / "from MeshChatX" for outgoing messages of account A
/// (spec 6.4); null for everything else.
String? originLabel(Strings s, MessageRow m, Map<String, String> names) {
  if (m.senderIdentity != 'A' || !m.outgoing) return null;
  final o = m.originDevice;
  if (o == null) return s.t('from_meshchatx');
  return s.t('from_device', {'device': names[o] ?? shortHash(o)});
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.originLabel,
    this.deviceName,
    this.showAccount = true,
  });
  final MessageRow message;

  /// False when the bridge is off: no `B · name` / `A` label in the line.
  final bool showAccount;

  /// Name of this device, shown as `B · <name>` on messages sent from B.
  final String? deviceName;

  /// Label of the sending device (account A), see [originLabel].
  final String? originLabel;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final m = message;
    final out = m.outgoing;
    final failed = m.status == MsgStatus.failed;
    final meta = [
      if (showAccount) s.account(m.senderIdentity, device: deviceName),
      if (showAccount) ?originLabel,
      if (m.route != null)
        m.route == 'via_bridge' ? s.t('route_via_bridge') : m.route!,
      s.t('transport_${m.transport}'),
    ].join(' · ');
    final waitingForBridge =
        out &&
        m.senderIdentity == 'A' &&
        m.status == MsgStatus.queued &&
        m.lxmfHash == null;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Card(
          color: out ? cs.primaryContainer : cs.surfaceContainerHigh,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showMessageDetails(context, m),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.text),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          meta,
                          key: ValueKey('meta-${m.id}'),
                          style: Theme.of(context).textTheme.labelSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: s.t('status_${m.status}'),
                        child: Icon(
                          statusIcon(m.status),
                          key: ValueKey('status-${m.id}'),
                          size: 14,
                          color: failed ? cs.error : cs.outline,
                        ),
                      ),
                    ],
                  ),
                  if (waitingForBridge) QueuedBridgeActions(message: m),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showMessageDetails(BuildContext context, MessageRow m) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MessageDetails(message: m),
    );

class MessageDetails extends ConsumerWidget {
  const MessageDetails({super.key, required this.message});
  final MessageRow message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final m = message;
    final log = ref.watch(deliveryLogProvider(m.id)).value ?? const <LogRow>[];
    Widget row(String k, String v, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(child: SelectableText(v, key: key)),
        ],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.t('details'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            row(
              s.t('hash'),
              m.lxmfHash ?? '-',
              key: const ValueKey('detail-hash'),
            ),
            if (ref.watch(bridgeModeProvider))
              row(
                s.t('sender'),
                isRemoteId(m.id)
                    ? s.account(
                        'B',
                        device:
                            ref
                                .watch(bridgeDevicesProvider)
                                .value
                                ?.where((d) => d.deviceId == m.originDevice)
                                .firstOrNull
                                ?.name ??
                            (m.originDevice == null
                                ? null
                                : shortHash(m.originDevice!)),
                      )
                    : s.account(m.senderIdentity),
              ),
            if (ref.watch(bridgeModeProvider) &&
                m.senderIdentity == 'A' &&
                m.outgoing)
              row(
                s.t('origin_device'),
                m.originDevice == null
                    ? s.t('from_meshchatx')
                    : (ref
                              .watch(bridgeDevicesProvider)
                              .value
                              ?.where((d) => d.deviceId == m.originDevice)
                              .firstOrNull
                              ?.name ??
                          shortHash(m.originDevice!)),
                key: const ValueKey('detail-origin'),
              ),
            row(s.t('route'), m.route ?? '-'),
            row(s.t('transport'), s.t('transport_${m.transport}')),
            row(s.t('status'), s.t('status_${m.status}')),
            if (m.error != null) row(s.t('error'), m.error!),
            if (m.signatureValid == false) row('', s.t('signature_unverified')),
            const Divider(height: 24),
            Text(
              s.t('timeline'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final l in log)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        formatTimeSeconds(l.ts),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    Expanded(child: Text(stageLabel(s, l))),
                  ],
                ),
              ),
            if (m.lxmfHash != null)
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: Text(s.t('copy')),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: m.lxmfHash!)),
              ),
          ],
        ),
      ),
    );
  }
}

String stageLabel(Strings s, LogRow l) {
  final base = s.t('stage_${l.stage}');
  final d = l.detail;
  if (d == null || d.isEmpty) return base;
  return '$base: $d';
}

String formatTimeSeconds(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}
