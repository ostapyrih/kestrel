import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/strings.dart';
import '../providers.dart';

/// Camera scanning exists on phones only; desktop pastes the text.
bool get canScanQr => Platform.isAndroid || Platform.isIOS;

/// Opens the camera and returns the text of the first QR code, or null.
Future<String?> scanQr(BuildContext context) =>
    Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Strings.of(context).t('bridge_scan'))),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.isNotEmpty) {
              _done = true;
              Navigator.of(context).pop(v);
              return;
            }
          }
        },
      ),
    );
  }
}

/// Paste or scan the bridge's `--print-address` output (or just the public
/// key) and connect.
class BridgeSetupScreen extends ConsumerStatefulWidget {
  const BridgeSetupScreen({super.key});

  @override
  ConsumerState<BridgeSetupScreen> createState() => _BridgeSetupScreenState();
}

class _BridgeSetupScreenState extends ConsumerState<BridgeSetupScreen> {
  final _text = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final v = await scanQr(context);
    if (v != null) setState(() => _text.text = v);
  }

  Future<void> _connect() async {
    final s = Strings.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(bridgeProvider).configure(_text.text);
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException {
      setState(() => _error = s.t('bridge_key_invalid'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('bridge_setup'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('bridge-key'),
            controller: _text,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              labelText: s.t('bridge_key_hint'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (canScanQr)
                OutlinedButton.icon(
                  key: const ValueKey('bridge-scan'),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(s.t('bridge_scan')),
                  onPressed: _scan,
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('bridge-connect'),
                onPressed: _busy ? null : _connect,
                child: Text(s.t('bridge_connect')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
