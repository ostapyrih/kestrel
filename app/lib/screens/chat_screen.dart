import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/repo.dart';
import 'widgets.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId});
  final int chatId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        unawaited(ref.read(repoProvider).markRead(widget.chatId));
      } on Object {
        // no repo (widget tests)
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await ref.read(nodeProvider).sendMessage(widget.chatId, t);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final chat = ref.watch(chatProvider(widget.chatId)).value;
    final msgs = ref.watch(messagesProvider(widget.chatId));
    final identity = chat?.accountIdentity ?? 'B';
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(
                chat?.displayTitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            IdentityBadge(identity),
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
                itemCount: list.length,
                itemBuilder: (_, i) =>
                    MessageBubble(message: list[list.length - 1 - i]),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.t('from', {'account': s.account(identity)}),
                    key: const ValueKey('composer-from'),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
  _ => Icons.south_west,
};

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final MessageRow message;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final m = message;
    final out = m.outgoing;
    final failed = m.status == MsgStatus.failed;
    final meta = [
      s.account(m.senderIdentity),
      if (m.route != null) m.route!,
      s.t('transport_${m.transport}'),
    ].join(' · ');
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
            row(s.t('sender'), s.account(m.senderIdentity)),
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
