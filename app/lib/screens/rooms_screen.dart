import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/bridge_service.dart';
import '../bridge/bridge_store.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import 'bridge_widgets.dart';
import 'widgets.dart';

/// RRC rooms of account A (read and write through the bridge).
class RoomsScreen extends ConsumerStatefulWidget {
  const RoomsScreen({super.key});

  @override
  ConsumerState<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends ConsumerState<RoomsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        unawaited(ref.read(bridgeProvider).refreshRooms());
      } on Object {
        // no bridge (widget tests)
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final rooms = ref.watch(rrcRoomsProvider).value ?? const <RrcRoomRow>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('rooms')),
        actions: [
          Center(child: IdentityBadge('A')),
          const SizedBox(width: 12),
        ],
      ),
      body: rooms.isEmpty
          ? Center(child: Text(s.t('rooms_empty')))
          : ListView(
              children: [
                for (final r in rooms)
                  ListTile(
                    key: ValueKey('room-${r.hub}-${r.room}'),
                    leading: const Icon(Icons.tag),
                    title: Text(r.room),
                    subtitle: Text(
                      (r.hubName?.isNotEmpty ?? false)
                          ? r.hubName!
                          : r.hub.substring(0, 8),
                    ),
                    trailing: r.unread > 0
                        ? Badge(
                            label: Text('${r.unread}'),
                            backgroundColor: r.mention
                                ? Theme.of(context).colorScheme.error
                                : null,
                          )
                        : null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RoomScreen(hub: r.hub, room: r.room),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key, required this.hub, required this.room});
  final String hub;
  final String room;

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  final _text = TextEditingController();
  bool _older = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _toast(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(bridgeErrorText(Strings.of(context), e))),
    );
  }

  Future<void> _load() async {
    try {
      await ref.read(bridgeProvider).loadRoom(widget.hub, widget.room);
    } on Object catch (e) {
      _toast(e);
    }
  }

  Future<void> _loadOlder() async {
    setState(() => _older = true);
    try {
      await ref.read(bridgeProvider).loadOlderRoom(widget.hub, widget.room);
    } on Object catch (e) {
      _toast(e);
    } finally {
      if (mounted) setState(() => _older = false);
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || BridgeService.isRrcCommand(t)) return;
    try {
      await ref.read(bridgeProvider).sendRrc(widget.hub, widget.room, t);
      _text.clear();
      unawaited(_load());
    } on Object catch (e) {
      _toast(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final msgs =
        ref
            .watch(rrcMessagesProvider((hub: widget.hub, room: widget.room)))
            .value ??
        const <RrcMessageRow>[];
    final blocked = BridgeService.isRrcCommand(_text.text);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(widget.room, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            IdentityBadge('A'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: msgs.length + 1,
              itemBuilder: (_, i) {
                if (i == msgs.length) {
                  return Center(
                    child: TextButton(
                      key: const ValueKey('room-older'),
                      onPressed: _older ? null : _loadOlder,
                      child: Text(s.t('room_older')),
                    ),
                  );
                }
                final m = msgs[msgs.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${formatTime(m.tsMs)} ',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        TextSpan(
                          text: '${m.nick ?? ''}: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: m.mention
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                        TextSpan(text: m.text),
                      ],
                    ),
                  ),
                );
              },
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
                    s.t('from_a_bridge'),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  if (blocked)
                    Text(
                      s.t('room_send_blocked'),
                      key: const ValueKey('room-blocked'),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('room-input'),
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          decoration: InputDecoration(
                            hintText: s.t('room_message_hint'),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      IconButton.filled(
                        key: const ValueKey('room-send'),
                        tooltip: s.t('send'),
                        icon: const Icon(Icons.send),
                        onPressed: blocked ? null : _send,
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
