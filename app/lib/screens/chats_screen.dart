import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../nomadnet/nomad_screen.dart';
import '../nomadnet/nomad_strings.dart';
import '../node/node_service.dart';
import '../platform.dart';
import '../providers.dart';
import '../storage/repo.dart';
import 'chat_screen.dart';
import 'bridge_widgets.dart';
import 'delete_chat.dart';
import 'group_screens.dart';
import 'new_chat_screen.dart';
import 'rooms_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  /// Multi-select mode: ids of the selected chats (null = not selecting).
  Set<int>? _sel;

  void _toggle(int id) {
    final sel = {...?_sel};
    if (!sel.remove(id)) sel.add(id);
    setState(() => _sel = sel.isEmpty ? null : sel);
  }

  Future<void> _deleteSelected(List<ChatRow> all) async {
    final chats = [
      for (final c in all)
        if (_sel?.contains(c.id) ?? false) c,
    ];
    final done = await deleteChatsFlow(context, ref, chats);
    if (done && mounted) setState(() => _sel = null);
  }

  /// Right click (desktop): a context menu with the delete action.
  Future<void> _contextMenu(ChatRow chat, Offset at) async {
    final s = Strings.of(context);
    final reason = await ref.read(nodeProvider).deleteBlockReason([chat.id]);
    if (!mounted) return;
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(
          key: const ValueKey('menu-select'),
          value: 'select',
          child: Text(s.t('select')),
        ),
        PopupMenuItem(
          key: const ValueKey('menu-delete'),
          value: 'delete',
          enabled: reason == null,
          child: Text(
            reason == null
                ? s.t('delete_chat')
                : '${s.t('delete_chat')} · ${s.t(reason)}',
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (pick == 'select') _toggle(chat.id);
    if (pick == 'delete') {
      final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
      final done = await deleteChatsFlow(context, ref, [chat]);
      if (done && wide && ref.read(selectedChatProvider) == chat.id) {
        ref.read(selectedChatProvider.notifier).select(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final conn = ref.watch(connectionProvider).value ?? NodeConnection.offline;
    final chats = ref.watch(chatsProvider);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
    final selected = ref.watch(selectedChatProvider);
    final bridgeMode = ref.watch(bridgeModeProvider);
    final sel = _sel;
    final chatList = chats.value ?? const <ChatRow>[];
    final list = Scaffold(
      appBar: sel != null
          ? AppBar(
              leading: IconButton(
                key: const ValueKey('select-close'),
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _sel = null),
              ),
              title: Text(s.t('selected_n', {'n': '${sel.length}'})),
              actions: [
                IconButton(
                  key: const ValueKey('select-delete'),
                  tooltip: s.t('delete_chat'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteSelected(chatList),
                ),
              ],
            )
          : AppBar(
              title: Text(s.t('app_title')),
              actions: [
                Center(child: ConnectionIndicator(conn)),
                if (bridgeMode &&
                    (ref.watch(bridgeConfiguredProvider).value ?? false))
                  IconButton(
                    key: const ValueKey('open-rooms'),
                    tooltip: s.t('rooms'),
                    icon: const Icon(Icons.forum_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RoomsScreen(),
                      ),
                    ),
                  ),
                IconButton(
                  key: const ValueKey('open-pages'),
                  tooltip: nt(context, 'nn_title'),
                  icon: const Icon(Icons.public),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NomadScreen(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: s.t('settings'),
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ],
            ),
      body: Column(
        children: [
          // bridge off = a plain messenger: no account chips at all
          if (bridgeMode) ...[
            const AccountSwitcher(),
            if (ref.watch(bridgeSyncingProvider).value ?? false)
              LinearProgressIndicator(
                key: const ValueKey('bridge-syncing'),
                semanticsLabel: s.t('bridge_syncing'),
              ),
          ],
          if (ref.watch(historyBackfillProvider) case AsyncData(:final value?))
            Column(
              key: const ValueKey('history-syncing'),
              children: [
                LinearProgressIndicator(value: value > 0 ? value : null),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(s.t('history_syncing')),
                ),
              ],
            ),
          Expanded(
            child: chats.when(
              data: (list) => list.isEmpty
                  ? Center(child: Text(s.t('chats_empty')))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (_, i) => ChatTile(
                        chat: list[i],
                        selected: wide && selected == list[i].id,
                        selecting: sel != null,
                        checked: sel?.contains(list[i].id) ?? false,
                        onLongPress: isDeletable(list[i])
                            ? () => _toggle(list[i].id)
                            : null,
                        onSecondaryTap: isDeletable(list[i])
                            ? (at) => _contextMenu(list[i], at)
                            : null,
                        onTap: sel != null
                            ? () => isDeletable(list[i])
                                  ? _toggle(list[i].id)
                                  : null
                            : wide
                            ? () => ref
                                  .read(selectedChatProvider.notifier)
                                  .select(list[i].id)
                            : null,
                      ),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
      floatingActionButton: sel != null
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.edit_outlined),
              label: Text(s.t('new_chat')),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const NewChatScreen()),
              ),
            ),
    );
    if (!wide) return list;
    return Row(
      children: [
        SizedBox(width: 360, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? Scaffold(body: Center(child: Text(s.t('chat_select'))))
              : ChatScreen(key: ValueKey('chat-$selected'), chatId: selected),
        ),
      ],
    );
  }
}

/// `B · <device name>` / `A (міст)` (disabled until the bridge exists) / `Усі`.
class AccountSwitcher extends ConsumerWidget {
  const AccountSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final sel = ref.watch(accountFilterProvider);
    final notifier = ref.read(accountFilterProvider.notifier);
    final configured = ref.watch(bridgeConfiguredProvider).value ?? false;
    final bridgeStatus = ref.watch(bridgeStatusProvider).value;
    final help = (configured && bridgeStatus != null)
        ? bridgeStateHelp(s, bridgeStatus)
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('chip-B'),
                label: Text(s.account('B')),
                selected: sel == 'B',
                onSelected: (_) => notifier.select('B'),
              ),
              Tooltip(
                message: s.t('bridge_hint'),
                child: ChoiceChip(
                  key: const ValueKey('chip-A'),
                  label: Text(s.account('A')),
                  selected: sel == 'A',
                  // Enabled once the bridge is configured.
                  onSelected: configured ? (_) => notifier.select('A') : null,
                ),
              ),
              if (ref.watch(hasRemoteChatsProvider).value ?? false)
                ChoiceChip(
                  key: const ValueKey('chip-R'),
                  label: Text(s.t('account_other')),
                  selected: sel == 'R',
                  onSelected: (_) => notifier.select('R'),
                ),
              ChoiceChip(
                key: const ValueKey('chip-all'),
                label: Text(s.t('account_all')),
                selected: sel == null,
                onSelected: (_) => notifier.select(null),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (configured && bridgeStatus != null) ...[
            BridgeIndicator(bridgeStatus),
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  help,
                  key: const ValueKey('bridge-help'),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ] else
            Text(
              '${s.account('A')}: ${s.t('bridge_hint')}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
        ],
      ),
    );
  }
}

class ChatTile extends ConsumerWidget {
  const ChatTile({
    super.key,
    required this.chat,
    this.selected = false,
    this.onTap,
    this.selecting = false,
    this.checked = false,
    this.onLongPress,
    this.onSecondaryTap,
  });
  final ChatRow chat;
  final bool selected;

  /// Multi-select mode: a check mark replaces the avatar.
  final bool selecting;
  final bool checked;
  final VoidCallback? onLongPress;

  /// Right click / secondary tap, with the global position.
  final void Function(Offset at)? onSecondaryTap;

  /// Overrides the default push navigation (two-pane layout).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final title = chat.displayTitle;
    final bridgeMode = ref.watch(bridgeModeProvider);
    final tile = ListTile(
      selected: selected || checked,
      onLongPress: onLongPress,
      leading: selecting && checked
          ? const CircleAvatar(
              key: ValueKey('chat-checked'),
              child: Icon(Icons.check),
            )
          : CircleAvatar(
              child: Text(
                title.isEmpty
                    ? '?'
                    : String.fromCharCode(title.runes.first).toUpperCase(),
              ),
            ),
      title: Row(
        children: [
          Flexible(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (bridgeMode) ...[
            const SizedBox(width: 8),
            if (chat.isRemote)
              Flexible(
                child: IdentityBadge(
                  'B',
                  key: const ValueKey('badge-remote'),
                  label: s.account('B', device: chat.remoteDeviceName),
                ),
              )
            else if (chat.accountIdentity == 'A')
              Flexible(child: IdentityBadge(chat.accountIdentity)),
          ],
        ],
      ),
      subtitle: Text(
        chat.lastText ??
            (chat.peerHash == null ? '' : shortHash(chat.peerHash!)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.lastTs != null)
            Text(
              formatTime(chat.lastTs!),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (chat.unread > 0) Badge(label: Text('${chat.unread}')),
        ],
      ),
      onTap:
          onTap ??
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatScreen(chatId: chat.id),
            ),
          ),
    );
    if (onSecondaryTap == null) return tile;
    return GestureDetector(
      key: ValueKey('chat-tile-${chat.id}'),
      onSecondaryTapUp: (d) => onSecondaryTap!(d.globalPosition),
      child: tile,
    );
  }
}
