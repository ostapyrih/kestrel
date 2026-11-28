import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/bridge_connection.dart';
import '../l10n/strings.dart';
import '../node/node_service.dart';
import '../providers.dart';
import '../storage/database.dart';
import '../storage/repo.dart';
import 'chat_screen.dart';
import 'widgets.dart';

/// Start a chat by pasting an LXMF address (or picking an announced peer).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key, this.returnTarget = false});
  final bool returnTarget;

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  String? _error;

  /// Identity the chat starts under (only offered in bridge mode).
  String? _identity;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<String> _lastIdentity() async {
    try {
      final v = await ref
          .read(repoProvider)
          .getSetting(SettingKeys.newChatIdentity);
      return v == 'A' ? 'A' : 'B';
    } on Object {
      return 'B';
    }
  }

  @override
  void initState() {
    super.initState();
    _lastIdentity().then((v) {
      if (mounted && _identity == null) setState(() => _identity = v);
    });
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t != null) setState(() => _address.text = t);
  }

  Future<void> _open() async {
    final s = Strings.of(context);
    final a = _address.text.trim();
    if (!NodeService.isValidAddress(a)) {
      setState(() => _error = s.t('invalid_address'));
      return;
    }
    final nav = Navigator.of(context);
    final bridgeMode = ref.read(bridgeModeProvider);
    final identity = bridgeMode ? (_identity ?? await _lastIdentity()) : 'B';
    if (bridgeMode) {
      try {
        await ref
            .read(repoProvider)
            .setSetting(SettingKeys.newChatIdentity, identity);
      } on Object {
        // remembering the choice is a convenience
      }
    }
    final target = await ref
        .read(nodeProvider)
        .openChat(
          a,
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
          identity: identity,
        );
    if (widget.returnTarget) {
      nav.pop(target);
      return;
    }
    nav.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => target.isDraft
            ? ChatScreen(draft: target)
            : ChatScreen(chatId: target.chatId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final peers = ref.watch(peersProvider).value ?? const <PeerRow>[];
    final bridgeMode = ref.watch(bridgeModeProvider);
    final identity = _identity ?? 'B';
    final upstreamDown =
        bridgeMode &&
        identity == 'A' &&
        (ref.watch(bridgeStatusProvider).value?.state !=
                BridgeState.connected ||
            ref.watch(bridgeStatusProvider).value?.detail ==
                'upstream_unavailable');
    return Scaffold(
      appBar: AppBar(title: Text(s.t('new_chat'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('address-field'),
            controller: _address,
            decoration: InputDecoration(
              labelText: s.t('address'),
              hintText: s.t('address_hint'),
              errorText: _error,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: _paste,
              ),
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('name-field'),
            controller: _name,
            decoration: InputDecoration(
              labelText: s.t('name_optional'),
              border: const OutlineInputBorder(),
            ),
          ),
          if (bridgeMode) ...[
            const SizedBox(height: 12),
            Text(
              s.t('new_chat_as'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              key: const ValueKey('new-chat-identity'),
              segments: [
                ButtonSegment(
                  value: 'A',
                  label: Text(s.account('A')),
                  icon: const Icon(Icons.hub_outlined),
                ),
                ButtonSegment(
                  value: 'B',
                  label: Text(
                    s.account('B', device: ref.watch(ownDeviceNameProvider)),
                  ),
                  icon: const Icon(Icons.phone_android),
                ),
              ],
              selected: {identity},
              onSelectionChanged: (v) => setState(() => _identity = v.first),
            ),
            if (upstreamDown)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  s.t('new_chat_a_queued'),
                  key: const ValueKey('new-chat-a-queued'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('open-chat'),
            onPressed: _open,
            child: Text(s.t('open_chat')),
          ),
          const SizedBox(height: 24),
          Text(
            s.t('known_peers'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            Text(
              s.t('known_peers_empty'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          for (final p in peers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(
                p.displayName?.isNotEmpty == true
                    ? p.displayName!
                    : shortHash(p.hash),
              ),
              subtitle: Text(
                p.hash,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                formatTime(p.lastSeen),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              onTap: () => setState(() {
                _address.text = p.hash;
                _name.text = p.displayName ?? '';
                _error = null;
              }),
            ),
        ],
      ),
    );
  }
}
