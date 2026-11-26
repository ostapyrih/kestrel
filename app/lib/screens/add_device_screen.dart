import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../bridge/bridge_connection.dart';
import '../bridge/codec.dart';
import '../l10n/strings.dart';
import '../providers.dart';
import 'bridge_setup_screen.dart';
import 'bridge_widgets.dart';

/// "Add a device": either this is the NEW device (shows its pairing code) or
/// a TRUSTED device approves the code of another one.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  bool _newDevice = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('add_device'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            key: const ValueKey('pair-mode'),
            segments: [
              ButtonSegment(
                value: false,
                label: Text(s.t('pair_approve_title')),
                icon: const Icon(Icons.verified_user_outlined),
              ),
              ButtonSegment(
                value: true,
                label: Text(s.t('pair_new_title')),
                icon: const Icon(Icons.qr_code_2),
              ),
            ],
            selected: {_newDevice},
            onSelectionChanged: (v) => setState(() => _newDevice = v.first),
          ),
          const SizedBox(height: 16),
          if (_newDevice) const NewDevicePane() else const ApproveDevicePane(),
        ],
      ),
    );
  }
}

/// On the NEW device: shows the pairing QR (regenerated before it expires)
/// and retries the bridge connection until a trusted device approved it.
class NewDevicePane extends ConsumerStatefulWidget {
  const NewDevicePane({super.key});

  @override
  ConsumerState<NewDevicePane> createState() => _NewDevicePaneState();
}

class _NewDevicePaneState extends ConsumerState<NewDevicePane> {
  String? _code;
  Timer? _refresh;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final bridge = ref.read(bridgeProvider);
    try {
      await bridge.beginPairing();
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    await _regenerate();
    // a code is valid for 10 minutes: show a fresh one every 5
    _refresh = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_regenerate()),
    );
  }

  Future<void> _regenerate() async {
    final p = await ref.read(bridgeProvider).newPairingPayload();
    if (mounted) setState(() => _code = encodePairingQr(p));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    try {
      ref.read(bridgeProvider).endPairing();
    } on Object {
      // already disposed
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final configured = ref.watch(bridgeConfiguredProvider).value ?? false;
    final st = ref.watch(bridgeStatusProvider).value;
    if (!configured) {
      return Column(
        children: [
          Text(s.t('pair_need_bridge')),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BridgeSetupScreen(),
              ),
            ),
            child: Text(s.t('bridge_setup')),
          ),
        ],
      );
    }
    final approved = st?.state == BridgeState.connected;
    return Column(
      children: [
        Text(s.t('pair_new_hint')),
        const SizedBox(height: 16),
        if (_code != null)
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                key: const ValueKey('pair-qr'),
                data: _code!,
                size: 240,
                errorCorrectionLevel: QrErrorCorrectLevel.L,
              ),
            ),
          ),
        const SizedBox(height: 12),
        if (_code != null) ...[
          SelectableText(
            _code!,
            key: const ValueKey('pair-text'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: Text(s.t('pair_copy_code')),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final copied = s.t('copied');
              await Clipboard.setData(ClipboardData(text: _code!));
              messenger.showSnackBar(SnackBar(content: Text(copied)));
            },
          ),
        ],
        const SizedBox(height: 12),
        if (_error != null)
          Text(bridgeErrorText(s, _error!))
        else if (approved)
          Row(
            key: const ValueKey('pair-done'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Text(s.t('pair_done')),
            ],
          )
        else
          Row(
            key: const ValueKey('pair-waiting'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(s.t('pair_waiting')),
            ],
          ),
      ],
    );
  }
}

/// On a TRUSTED device: scan or paste the code of the new device, confirm
/// name/platform/fingerprint, sign and send the approval.
class ApproveDevicePane extends ConsumerStatefulWidget {
  const ApproveDevicePane({super.key});

  @override
  ConsumerState<ApproveDevicePane> createState() => _ApproveDevicePaneState();
}

class _ApproveDevicePaneState extends ConsumerState<ApproveDevicePane> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final v = await scanQr(context);
    if (v == null) return;
    _text.text = v;
    await _next();
  }

  Future<void> _next() async {
    final s = Strings.of(context);
    final DecodedPairing d;
    try {
      d = decodePairingQr(_text.text);
    } on FormatException {
      setState(() => _error = s.t('pair_invalid'));
      return;
    }
    setState(() => _error = null);
    final choice = await showDialog<({bool field})>(
      context: context,
      builder: (_) => _ConfirmDialog(pairing: d),
    );
    if (choice == null || !mounted) return;
    try {
      await ref.read(bridgeProvider).approveDevice(d, field: choice.field);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.t('pair_added'))));
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) setState(() => _error = bridgeErrorText(s, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('pair-input'),
          controller: _text,
          minLines: 3,
          maxLines: 6,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          decoration: InputDecoration(
            labelText: s.t('pair_paste_hint'),
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (canScanQr)
              OutlinedButton.icon(
                key: const ValueKey('pair-scan'),
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(s.t('bridge_scan')),
                onPressed: _scan,
              ),
            const Spacer(),
            FilledButton(
              key: const ValueKey('pair-next'),
              onPressed: _next,
              child: Text(s.t('pair_continue')),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.pairing});
  final DecodedPairing pairing;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  bool _field = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = widget.pairing.payload;
    Widget row(String k, String v, Key key) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(v, key: key),
        ],
      ),
    );
    return AlertDialog(
      key: const ValueKey('pair-confirm'),
      title: Text(s.t('pair_confirm_title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(s.t('pair_name'), p.name, const ValueKey('confirm-name')),
            row(
              s.t('pair_platform'),
              p.platform,
              const ValueKey('confirm-platform'),
            ),
            row(
              s.t('pair_fingerprint'),
              p.fingerprint,
              const ValueKey('confirm-fingerprint'),
            ),
            CheckboxListTile(
              key: const ValueKey('confirm-field'),
              contentPadding: EdgeInsets.zero,
              value: _field,
              title: Text(s.t('pair_field_role')),
              onChanged: (v) => setState(() => _field = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('cancel')),
        ),
        FilledButton(
          key: const ValueKey('confirm-approve'),
          onPressed: () => Navigator.pop(context, (field: _field)),
          child: Text(s.t('pair_approve')),
        ),
      ],
    );
  }
}
