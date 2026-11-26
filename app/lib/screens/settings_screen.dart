import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/strings.dart';
import '../providers.dart';
import '../storage/database.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _loadOnce() {
    if (_loaded) return;
    final n = ref.read(settingProvider(SettingKeys.displayName));
    final h = ref.read(settingProvider(SettingKeys.serverHost));
    final p = ref.read(settingProvider(SettingKeys.serverPort));
    if (n.isLoading || h.isLoading || p.isLoading) return;
    _loaded = true;
    _name.text = n.value ?? '';
    _host.text = h.value ?? defaultServerHost;
    _port.text = p.value ?? '$defaultServerPort';
  }

  Future<void> _copy(String v) async {
    await Clipboard.setData(ClipboardData(text: v));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(Strings.of(context).t('copied'))));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    // Re-evaluate when the settings stream delivers its first values.
    ref.watch(settingProvider(SettingKeys.displayName));
    ref.watch(settingProvider(SettingKeys.serverHost));
    ref.watch(settingProvider(SettingKeys.serverPort));
    _loadOnce();
    final info = ref.watch(identityInfoProvider);
    final bridge = ref.watch(bridgeEnabledProvider).value ?? false;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('display-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: s.t('display_name'),
              border: const OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('save-name'),
              onPressed: () =>
                  ref.read(nodeProvider).setDisplayName(_name.text),
              child: Text(s.t('save')),
            ),
          ),
          const Divider(height: 32),
          Text(s.t('server'), style: text.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const ValueKey('server-host'),
                  controller: _host,
                  decoration: InputDecoration(
                    labelText: s.t('host'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('server-port'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: s.t('port'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('apply-server'),
              onPressed: () {
                final port = int.tryParse(_port.text.trim());
                if (port == null || _host.text.trim().isEmpty) return;
                ref.read(nodeProvider).setServer(_host.text, port);
              },
              child: Text(s.t('apply')),
            ),
          ),
          const Divider(height: 32),
          Text(s.t('identity'), style: text.titleSmall),
          const SizedBox(height: 8),
          info.when(
            data: (i) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ValueRow(
                  label: s.t('lxmf_address'),
                  value: i.address,
                  valueKey: const ValueKey('lxmf-address'),
                  onCopy: () => _copy(i.address),
                ),
                const SizedBox(height: 12),
                _ValueRow(
                  label: s.t('public_key'),
                  value: i.publicKey,
                  valueKey: const ValueKey('public-key'),
                  onCopy: () => _copy(i.publicKey),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                      key: const ValueKey('public-key-qr'),
                      data: i.publicKey,
                      size: 180,
                    ),
                  ),
                ),
              ],
            ),
            loading: () => Text(s.t('starting')),
            error: (e, _) => Text('$e'),
          ),
          const Divider(height: 32),
          Text(s.t('bridge'), style: text.titleSmall),
          SwitchListTile(
            key: const ValueKey('bridge-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(s.t('bridge_enable')),
            subtitle: Text(s.t('bridge_soon')),
            value: bridge,
            onChanged: (v) => ref.read(repoProvider).setBridgeEnabled(v),
          ),
          Text(s.t('bridge_note'), style: text.bodySmall),
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.label,
    required this.value,
    required this.onCopy,
    required this.valueKey,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                key: valueKey,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: onCopy,
            ),
          ],
        ),
      ],
    );
  }
}
