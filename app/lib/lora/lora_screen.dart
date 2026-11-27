import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';

import 'lora_model.dart';
import 'lora_providers.dart';
import 'lora_service.dart';
import 'lora_strings.dart';

/// Settings -> "LoRa радіо": RNode device, radio parameters with presets,
/// regulations notice and live status.
class LoraScreen extends ConsumerStatefulWidget {
  const LoraScreen({super.key});

  @override
  ConsumerState<LoraScreen> createState() => _LoraScreenState();
}

class _LoraScreenState extends ConsumerState<LoraScreen> {
  final _freq = TextEditingController();
  final _bw = TextEditingController();
  final _txp = TextEditingController();
  int _sf = 8;
  int _cr = 5;
  bool _flow = false;
  String _preset = LoraPreset.reticulumEu.id;
  Map<String, String> _errors = {};
  bool _loaded = false;

  @override
  void dispose() {
    _freq.dispose();
    _bw.dispose();
    _txp.dispose();
    super.dispose();
  }

  static String _mhz(int hz) => _trim(hz / 1e6);
  static String _khz(int hz) => _trim(hz / 1e3);
  static String _trim(double v) {
    var s = v.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  void _fill(LoraSettings s) {
    _freq.text = _mhz(s.frequency);
    _bw.text = _khz(s.bandwidth);
    _txp.text = '${s.txPower}';
    _sf = s.spreadingFactor;
    _cr = s.codingRate;
    _flow = s.flowControl;
    _preset = s.presetId;
  }

  /// The radio fields as settings, or null (with [_errors] set) if a field
  /// is not a number or out of range.
  LoraSettings? _draft(LoraSettings base, String lang) {
    final errors = <String, String>{};
    final f = double.tryParse(_freq.text.trim().replaceAll(',', '.'));
    final b = double.tryParse(_bw.text.trim().replaceAll(',', '.'));
    final p = int.tryParse(_txp.text.trim());
    if (f == null) errors['frequency'] = ltFor(lang, 'lora_err_number');
    if (b == null) errors['bandwidth'] = ltFor(lang, 'lora_err_number');
    if (p == null) errors['txPower'] = ltFor(lang, 'lora_err_number');
    final next = base.copyWith(
      frequency: f == null ? null : (f * 1e6).round(),
      bandwidth: b == null ? null : (b * 1e3).round(),
      txPower: p,
      spreadingFactor: _sf,
      codingRate: _cr,
      flowControl: _flow,
    );
    for (final k in next.validate()) {
      errors.putIfAbsent(k, () => ltFor(lang, 'lora_err_$k'));
    }
    setState(() => _errors = errors);
    return errors.isEmpty ? next : null;
  }

  Future<void> _apply(LoraView v) async {
    final lang = Localizations.localeOf(context).languageCode;
    final next = _draft(v.settings, lang);
    if (next == null) return;
    await ref.read(loraControllerProvider).update(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(lt(context, 'lora_applied'))));
  }

  Future<void> _toggle(LoraView v, bool on) async {
    final c = ref.read(loraControllerProvider);
    var s = v.settings;
    if (!on) {
      await c.update(s.copyWith(enabled: false));
      return;
    }
    if (!s.hasDevice) {
      final picked = await _pickDevice(c);
      if (picked == null) return;
      s = s.copyWith(
        kind: picked.kind,
        deviceId: picked.id,
        deviceName: picked.name,
      );
    }
    if (!s.regulationsAcknowledged) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('lora-regs-dialog'),
          title: Text(lt(ctx, 'lora_regs_title')),
          content: Text(lt(ctx, 'lora_regs_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(lt(ctx, 'lora_cancel')),
            ),
            FilledButton(
              key: const ValueKey('lora-regs-accept'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(lt(ctx, 'lora_regs_accept')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      s = s.copyWith(regulationsAcknowledged: true);
    }
    await c.update(s.copyWith(enabled: true));
  }

  Future<LoraDevice?> _pickDevice(LoraController c) =>
      showModalBottomSheet<LoraDevice>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _DevicePicker(controller: c),
      );

  Future<void> _changeDevice(LoraView v) async {
    final c = ref.read(loraControllerProvider);
    final d = await _pickDevice(c);
    if (d == null) return;
    await c.update(
      v.settings.copyWith(kind: d.kind, deviceId: d.id, deviceName: d.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(loraViewProvider);
    final c = ref.watch(loraControllerProvider);
    final v = view.value ?? c.view;
    if (!_loaded) {
      _loaded = true;
      _fill(v.settings);
    }
    final text = Theme.of(context).textTheme;
    final warn = Theme.of(context).colorScheme.error;
    final s = v.settings;
    return Scaffold(
      appBar: AppBar(title: Text(lt(context, 'lora_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(view: v),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('lora-enable'),
            contentPadding: EdgeInsets.zero,
            title: Text(lt(context, 'lora_enable')),
            subtitle: Text(lt(context, 'lora_enable_hint')),
            value: s.enabled,
            onChanged: (on) => _toggle(v, on),
          ),
          const Divider(height: 32),
          Text(lt(context, 'lora_device'), style: text.titleSmall),
          ListTile(
            key: const ValueKey('lora-pick-device'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(s.kind == LoraKind.usb ? Icons.usb : Icons.bluetooth),
            title: Text(
              s.hasDevice
                  ? (s.deviceName ?? s.deviceId!)
                  : lt(context, 'lora_no_device'),
            ),
            subtitle: s.hasDevice && s.deviceName != s.deviceId
                ? Text(s.deviceId!)
                : null,
            trailing: TextButton(
              onPressed: () => _changeDevice(v),
              child: Text(
                s.hasDevice
                    ? lt(context, 'lora_change_device')
                    : lt(
                        context,
                        c.supportedKinds.contains(LoraKind.usb)
                            ? 'lora_pick_usb'
                            : 'lora_pick_ble',
                      ),
              ),
            ),
          ),
          if (c.supportedKinds.contains(LoraKind.ble))
            Text(lt(context, 'lora_pairing_hint'), style: text.bodySmall),
          const Divider(height: 32),
          Text(lt(context, 'lora_radio'), style: text.titleSmall),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey('lora-preset'),
            child: DropdownButtonFormField<String>(
              key: ValueKey('preset-$_preset'),
              isExpanded: true,
              initialValue: _preset,
              decoration: InputDecoration(
                labelText: lt(context, 'lora_preset'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final p in LoraPreset.all)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(lt(context, 'lora_preset_${p.id}')),
                  ),
                DropdownMenuItem(
                  value: LoraPreset.custom,
                  child: Text(lt(context, 'lora_preset_custom')),
                ),
              ],
              onChanged: (id) {
                if (id == null) return;
                setState(() {
                  _preset = id;
                  _errors = {};
                  for (final p in LoraPreset.all) {
                    if (p.id == id) {
                      _fill(s.withPreset(p).copyWith(flowControl: _flow));
                    }
                  }
                  _preset = id;
                });
              },
            ),
          ),
          const SizedBox(height: 4),
          Text(lt(context, 'lora_preset_source'), style: text.bodySmall),
          const SizedBox(height: 12),
          _field('lora-frequency', 'lora_frequency', _freq, 'frequency'),
          _field('lora-bandwidth', 'lora_bandwidth', _bw, 'bandwidth'),
          Row(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('lora-sf'),
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('sf-$_sf'),
                    isExpanded: true,
                    initialValue: _sf,
                    decoration: InputDecoration(
                      labelText: lt(context, 'lora_sf'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (var i = 5; i <= 12; i++)
                        DropdownMenuItem(value: i, child: Text('SF$i')),
                    ],
                    onChanged: (x) => setState(() {
                      _sf = x ?? _sf;
                      _preset = LoraPreset.custom;
                    }),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('lora-cr'),
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('cr-$_cr'),
                    isExpanded: true,
                    initialValue: _cr,
                    decoration: InputDecoration(
                      labelText: lt(context, 'lora_cr'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (var i = 5; i <= 8; i++)
                        DropdownMenuItem(value: i, child: Text('4/$i')),
                    ],
                    onChanged: (x) => setState(() {
                      _cr = x ?? _cr;
                      _preset = LoraPreset.custom;
                    }),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _field('lora-txpower', 'lora_txpower', _txp, 'txPower'),
          SwitchListTile(
            key: const ValueKey('lora-flow'),
            contentPadding: EdgeInsets.zero,
            title: Text(lt(context, 'lora_flow')),
            subtitle: Text(lt(context, 'lora_flow_hint')),
            value: _flow,
            onChanged: (x) => setState(() => _flow = x),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.warning_amber, size: 18, color: warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  lt(context, 'lora_warning_short'),
                  key: const ValueKey('lora-warning'),
                  style: text.bodySmall?.copyWith(color: warn),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('lora-apply'),
              onPressed: () => _apply(v),
              child: Text(lt(context, 'lora_apply')),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            lt(context, 'lora_large_hint', {
              'kb':
                  '${const LxmRouterConfig().slowInterfaceMaxResource ~/ 1024}',
            }),
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _field(
    String key,
    String label,
    TextEditingController ctl,
    String errKey,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(key),
      controller: ctl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() => _preset = LoraPreset.custom),
      decoration: InputDecoration(
        labelText: lt(context, label),
        errorText: _errors[errKey],
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.view});
  final LoraView view;

  @override
  Widget build(BuildContext context) {
    final st = view.status;
    final s = view.settings;
    final text = Theme.of(context).textTheme;
    final stateKey = switch (view.state) {
      InterfaceState.online => 'lora_state_online',
      InterfaceState.connecting => 'lora_state_connecting',
      InterfaceState.offline => 'lora_state_offline',
    };
    final rows = <(String, String)>[];
    if (st != null && view.connected) {
      if (st.firmware != null) {
        rows.add((lt(context, 'lora_firmware'), st.firmware!));
      }
      if (st.platform != null) {
        rows.add((lt(context, 'lora_platform'), st.platform!));
      }
      final cfg = s.config;
      final bitrate = st.bitrate > 0 ? st.bitrate : cfg.bitrate;
      rows.add((
        lt(context, 'lora_bitrate'),
        lt(context, 'lora_bitrate_value', {'v': bitrate.toStringAsFixed(0)}),
      ));
      rows.add((
        lt(context, 'lora_airtime_packet'),
        lt(context, 'lora_airtime_value', {
          's': RNodeInterface.airtimeOf(500, cfg).toStringAsFixed(1),
        }),
      ));
      if (st.airtimeShort != null) {
        rows.add((
          lt(context, 'lora_airtime_used'),
          lt(context, 'lora_airtime_used_value', {
            'short': st.airtimeShort!.toStringAsFixed(1),
            'long': (st.airtimeLong ?? 0).toStringAsFixed(1),
          }),
        ));
      }
      rows.add((
        lt(context, 'lora_last_packet'),
        st.rssi == null && st.snr == null
            ? lt(context, 'lora_last_packet_none')
            : lt(context, 'lora_rssi_snr', {
                'rssi': '${st.rssi ?? '–'}',
                'snr': st.snr?.toStringAsFixed(2) ?? '–',
              }),
      ));
    }
    return Card(
      key: const ValueKey('lora-status'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  view.connected ? Icons.sensors : Icons.sensors_off,
                  color: view.connected ? Colors.green : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.hasDevice && s.enabled
                        ? '${s.deviceName ?? s.deviceId} · ${lt(context, stateKey)}'
                        : lt(context, 'lora_subtitle_off'),
                    key: const ValueKey('lora-state'),
                    style: text.titleSmall,
                  ),
                ),
              ],
            ),
            if (st?.error != null && !view.connected)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  lt(context, 'lora_error', {'e': st!.error!}),
                  key: const ValueKey('lora-error'),
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r.$1, style: text.bodySmall),
                    Flexible(child: Text(r.$2, style: text.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet: BLE scan results or the serial ports present.
class _DevicePicker extends StatefulWidget {
  const _DevicePicker({required this.controller});
  final LoraController controller;

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  Stream<List<LoraDevice>>? _scan;
  List<LoraDevice> _usb = const [];

  bool get _ble => widget.controller.supportedKinds.contains(LoraKind.ble);
  bool get _usbOk => widget.controller.supportedKinds.contains(LoraKind.usb);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      if (_ble) _scan = widget.controller.scanBle();
      if (_usbOk) _usb = widget.controller.listUsb();
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget list(List<LoraDevice> devices, {required bool scanning}) {
      if (devices.isEmpty) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            scanning
                ? lt(context, 'lora_scanning')
                : lt(
                    context,
                    _ble ? 'lora_no_devices_ble' : 'lora_no_devices_usb',
                  ),
          ),
        );
      }
      return Column(
        children: [
          for (final d in devices)
            ListTile(
              key: ValueKey('lora-device-${d.id}'),
              leading: Icon(
                d.kind == LoraKind.usb ? Icons.usb : Icons.bluetooth,
              ),
              title: Text(d.name),
              subtitle: (d.detail ?? '').isEmpty ? null : Text(d.detail!),
              onTap: () => Navigator.pop(context, d),
            ),
        ],
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    lt(context, _ble ? 'lora_pick_ble' : 'lora_pick_usb'),
                    style: text.titleMedium,
                  ),
                ),
                TextButton(
                  key: const ValueKey('lora-rescan'),
                  onPressed: _refresh,
                  child: Text(
                    lt(context, _ble ? 'lora_scan_again' : 'lora_refresh'),
                  ),
                ),
              ],
            ),
            if (!_ble && !_usbOk)
              Text(lt(context, 'lora_unsupported'))
            else if (_ble)
              StreamBuilder<List<LoraDevice>>(
                stream: _scan,
                builder: (_, snap) => list(
                  snap.data ?? const [],
                  scanning: snap.connectionState != ConnectionState.done,
                ),
              )
            else
              list(_usb, scanning: false),
          ],
        ),
      ),
    );
  }
}

/// The "LoRa радіо" entry in Settings: its own section, opens [LoraScreen].
class LoraSettingsTile extends ConsumerWidget {
  const LoraSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(loraViewProvider).value;
    final subtitle = v == null || !v.settings.enabled
        ? lt(context, 'lora_subtitle_off')
        : lt(context, switch (v.state) {
            InterfaceState.online => 'lora_state_online',
            InterfaceState.connecting => 'lora_state_connecting',
            InterfaceState.offline => 'lora_state_offline',
          });
    return ListTile(
      key: const ValueKey('lora-settings'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cell_tower),
      title: Text(lt(context, 'lora_title')),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const LoraScreen())),
    );
  }
}
