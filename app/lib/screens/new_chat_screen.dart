import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../node/node_service.dart';
import '../providers.dart';
import '../storage/repo.dart';
import 'chat_screen.dart';
import 'widgets.dart';

/// Start a chat by pasting an LXMF address (or picking an announced peer).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    super.dispose();
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
    final id = await ref
        .read(nodeProvider)
        .openChat(
          a,
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        );
    nav.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => ChatScreen(chatId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final peers = ref.watch(peersProvider).value ?? const <PeerRow>[];
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
