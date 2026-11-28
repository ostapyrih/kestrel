import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/strings.dart';
import '../node/node_service.dart';
import '../providers.dart';
import '../storage/repo.dart' show shortHash;
import 'bridge_setup_screen.dart';

/// Progress of the history backfill on a freshly paired device (null while
/// no backfill runs). Polled: the runtime starts and stops with the router.
final historyBackfillProvider = StreamProvider<double?>((ref) async* {
  final node = ref.watch(nodeProvider);
  double? last = -1;
  while (true) {
    final p = node.groupRuntime?.backfill.progress;
    final v = (p != null && p.active && !p.done) ? (p.fraction ?? 0.0) : null;
    if (v != last) {
      last = v;
      yield v;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
});

/// "My devices": the devices of the group (all share one address), add,
/// join, rename, remove.
class MyDevicesScreen extends ConsumerWidget {
  const MyDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Strings.of(context);
    ref.watch(groupChangesProvider);
    final node = ref.watch(nodeProvider);
    final g = node.group;
    final devices = g.devices;
    final rt = node.groupRuntime;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('group_devices'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('group_devices_hint')),
          const SizedBox(height: 12),
          for (final d in devices)
            ListTile(
              key: ValueKey('group-device-${d.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(_icon(d.platform)),
              title: Text(
                d.id == g.ownId ? '${d.name} (${s.t('this_device')})' : d.name,
              ),
              subtitle: Text(
                [
                  d.platform,
                  shortHash(d.id),
                  if (rt != null && rt.isAnnouncer && d.id == g.ownId)
                    s.t('announcer_badge'),
                ].join(' · '),
              ),
              trailing: PopupMenuButton<String>(
                key: ValueKey('group-device-menu-${d.id}'),
                onSelected: (v) => v == 'rename'
                    ? _rename(context, ref, d)
                    : _remove(context, ref, d),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(s.t('device_rename')),
                  ),
                  if (d.id != g.ownId)
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(s.t('device_remove')),
                    ),
                ],
              ),
            ),
          const Divider(height: 32),
          ListTile(
            key: const ValueKey('group-add'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.qr_code_2),
            title: Text(s.t('add_group_device')),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AddGroupDeviceScreen(),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('group-join'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.login),
            title: Text(s.t('join_group')),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const JoinGroupScreen()),
            ),
          ),
          ListTile(
            key: const ValueKey('group-address'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.alternate_email),
            title: Text(s.t('my_address')),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MyAddressScreen()),
            ),
          ),
          if (g.isGroup)
            ListTile(
              key: const ValueKey('group-pull-history'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sync),
              title: Text(s.t('sync_group_history')),
              onTap: () async {
                await node.pullGroupHistory();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(s.t('sync_group_history_started'))),
                  );
                }
              },
            ),
        ],
      ),
    );
  }

  static IconData _icon(String platform) => switch (platform) {
    'android' || 'ios' => Icons.smartphone,
    _ => Icons.computer,
  };

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    GroupDevice d,
  ) async {
    final s = Strings.of(context);
    final c = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('device_rename')),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: Text(s.t('apply')),
          ),
        ],
      ),
    );
    if (name != null) {
      await ref.read(nodeProvider).group.renameDevice(d.id, name);
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    GroupDevice d,
  ) async {
    final s = Strings.of(context);
    final node = ref.read(nodeProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('remove-device-dialog'),
        title: Text(s.t('device_remove_title', {'name': d.name})),
        content: Text(s.t('device_remove_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('device_remove')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await node.removeDevice(d.id);
    if (!context.mounted) return;
    // the honest limit: the removed device still holds the address key
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const MyAddressScreen()));
  }
}

/// Existing device: shows the pairing QR and asks to confirm the code.
class AddGroupDeviceScreen extends ConsumerStatefulWidget {
  const AddGroupDeviceScreen({super.key});

  @override
  ConsumerState<AddGroupDeviceScreen> createState() => _AddGroupState();
}

class _AddGroupState extends ConsumerState<AddGroupDeviceScreen> {
  PairingHost? _host;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final h = await ref
          .read(nodeProvider)
          .startPairing(
            confirm: _confirm,
            onPaired: (_) {
              if (mounted) setState(() => _done = true);
            },
          );
      if (mounted) setState(() => _host = h);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<bool> _confirm(PairingRequest r) async {
    if (!mounted) return false;
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('pair-confirm-dialog'),
        title: Text(s.t('pair_code_title')),
        content: Text(
          s.t('pair_code_body', {
            'name': r.name,
            'platform': r.platform,
            'code': r.code,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('pair_no')),
          ),
          FilledButton(
            key: const ValueKey('pair-match'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('pair_match')),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  void dispose() {
    unawaited(_host?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final text = _host?.invite.encode();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('add_group_device'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('pair_host_hint')),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!),
          if (text != null && !_done)
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(
                  key: const ValueKey('group-invite-qr'),
                  data: text,
                  size: 240,
                  errorCorrectionLevel: QrErrorCorrectLevel.L,
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (text != null && !_done)
            SelectableText(
              text,
              key: const ValueKey('group-invite-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          if (text != null && !_done)
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              child: Text(s.t('copy')),
            ),
          if (_done) Text(s.t('join_done'), key: const ValueKey('pair-done')),
        ],
      ),
    );
  }
}

/// New device: paste or scan the code, compare the code, join.
class JoinGroupScreen extends ConsumerStatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinState();
}

class _JoinState extends ConsumerState<JoinGroupScreen> {
  final _text = TextEditingController();
  String? _code;
  String? _message;
  bool _busy = false;

  Future<void> _scan() async {
    final v = await scanQr(context);
    if (v != null && mounted) setState(() => _text.text = v);
  }

  Future<void> _join() async {
    final s = Strings.of(context);
    final invite = PairingInvite.parse(_text.text);
    if (invite == null) {
      setState(() => _message = s.t('join_invalid'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(nodeProvider)
          .joinGroup(
            invite,
            onCode: (c) {
              if (mounted) setState(() => _code = c);
            },
            confirm: (c) async {
              if (!mounted) return false;
              final ok = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => AlertDialog(
                  title: Text(c),
                  content: Text(s.t('join_confirm')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(s.t('pair_no')),
                    ),
                    FilledButton(
                      key: const ValueKey('join-match'),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(s.t('pair_match')),
                    ),
                  ],
                ),
              );
              return ok ?? false;
            },
          );
      if (mounted) setState(() => _message = s.t('join_done'));
    } on PairingException catch (e) {
      if (mounted) {
        setState(() => _message = s.t('join_failed', {'error': e.error.name}));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _message = s.t('join_failed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('join_group'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('join_hint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('join-text'),
            controller: _text,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (canScanQr)
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(s.t('bridge_scan')),
                  onPressed: _busy ? null : _scan,
                ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('join-button'),
                onPressed: _busy ? null : _join,
                child: Text(s.t('join_button')),
              ),
            ],
          ),
          if (_code != null) ...[
            const SizedBox(height: 16),
            Text(
              s.t('join_code', {'code': _code!}),
              key: const ValueKey('join-code'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, key: const ValueKey('join-message')),
          ],
        ],
      ),
    );
  }
}

/// "My address": the group identity, the one synced name, "Change address".
class MyAddressScreen extends ConsumerStatefulWidget {
  const MyAddressScreen({super.key});

  @override
  ConsumerState<MyAddressScreen> createState() => _AddressState();
}

class _AddressState extends ConsumerState<MyAddressScreen> {
  late final TextEditingController _name;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: ref.read(nodeProvider).group.displayName,
    );
  }

  Future<void> _change() async {
    final s = Strings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('change_address')),
        content: Text(s.t('change_address_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('change-address-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('change_address')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(nodeProvider).changeAddress();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('change_address_done', {'n': '$n'}))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportKey() async {
    final s = Strings.of(context);
    final node = ref.read(nodeProvider);
    final bytes = node.exportGroupKeyBytes();
    final saved = await FilePicker.saveFile(
      fileName: 'kestrel-${shortHash(node.addressHex)}.rns',
      bytes: bytes,
    );
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.t('export_identity_done'))),
      );
    }
  }

  Future<void> _importKey() async {
    final s = Strings.of(context);
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final f = picked.first;
    final raw = f.path != null ? await File(f.path!).readAsBytes() : null;
    if (raw == null) return;
    final Identity imported;
    try {
      imported = await NodeService.parseImportedKey(raw);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('import_identity_invalid'))),
        );
      }
      return;
    }
    if (!mounted) return;
    final newAddr = toHex(LXMessage.deliveryHash(imported));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('import_identity_title')),
        content: Text(s.t('import_identity_body', {'address': newAddr})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('import-identity-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('import_identity')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(nodeProvider).importGroupIdentity(imported);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('import_identity_done', {'address': shortHash(newAddr)}))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    ref.watch(groupChangesProvider);
    final node = ref.watch(nodeProvider);
    final address = node.isRunning ? node.addressHex : '';
    return Scaffold(
      appBar: AppBar(title: Text(s.t('my_address'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.t('my_address_hint')),
          const SizedBox(height: 12),
          SelectableText(
            address,
            key: const ValueKey('group-address-text'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: address)),
            child: Text(s.t('copy')),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('group-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: s.t('group_name'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => node.setDisplayName(v),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => node.setDisplayName(_name.text),
              child: Text(s.t('apply')),
            ),
          ),
          const Divider(height: 32),
          OutlinedButton.icon(
            key: const ValueKey('export-identity'),
            onPressed: _busy ? null : _exportKey,
            icon: const Icon(Icons.upload_file),
            label: Text(s.t('export_identity')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('import-identity'),
            onPressed: _busy ? null : _importKey,
            icon: const Icon(Icons.download),
            label: Text(s.t('import_identity')),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const ValueKey('change-address'),
            onPressed: _busy ? null : _change,
            child: Text(s.t('change_address')),
          ),
        ],
      ),
    );
  }
}
