import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../node/node_service.dart';
import '../platform.dart';
import '../providers.dart';
import '../storage/repo.dart';
import 'chat_screen.dart';
import 'bridge_widgets.dart';
import 'new_chat_screen.dart';
import 'rooms_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    final conn = ref.watch(connectionProvider).value ?? NodeConnection.offline;
    final chats = ref.watch(chatsProvider);
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
    final selected = ref.watch(selectedChatProvider);
    final list = Scaffold(
      appBar: AppBar(
        title: Text(s.t('app_title')),
        actions: [
          Center(child: ConnectionIndicator(conn)),
          if (ref.watch(bridgeConfiguredProvider).value ?? false)
            IconButton(
              key: const ValueKey('open-rooms'),
              tooltip: s.t('rooms'),
              icon: const Icon(Icons.forum_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const RoomsScreen()),
              ),
            ),
          IconButton(
            tooltip: s.t('settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const AccountSwitcher(),
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
                        onTap: wide
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
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit_outlined),
        label: Text(s.t('new_chat')),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const NewChatScreen())),
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
                label: Text(
                  s.account('B', device: ref.watch(ownDeviceNameProvider)),
                ),
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

class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.chat,
    this.selected = false,
    this.onTap,
  });
  final ChatRow chat;
  final bool selected;

  /// Overrides the default push navigation (two-pane layout).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final title = chat.displayTitle;
    return ListTile(
      selected: selected,
      leading: CircleAvatar(
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
          const SizedBox(width: 8),
          IdentityBadge(chat.accountIdentity),
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
  }
}
