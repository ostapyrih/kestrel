import 'package:kestrel_rns/kestrel_rns.dart';

import '../storage/repo.dart';

/// How the RNode is attached.
enum LoraKind { ble, usb }

/// A radio preset. Only presets with a documented source are listed; the
/// other entries are variations of the same frequency with a different
/// speed/range trade-off, labelled as such.
class LoraPreset {
  const LoraPreset(
    this.id,
    this.frequency,
    this.bandwidth,
    this.spreadingFactor,
    this.codingRate,
    this.txPower,
  );

  final String id;
  final int frequency;
  final int bandwidth;
  final int spreadingFactor;
  final int codingRate;
  final int txPower;

  /// The example RNode interface of the Reticulum manual
  /// (https://reticulum.network/manual/interfaces.html): 867.2 MHz, 125 kHz,
  /// 7 dBm (5 mW), SF8, CR 4/5. The default.
  static const reticulumEu = LoraPreset(
    'reticulum_eu',
    867200000,
    125000,
    8,
    5,
    7,
  );

  /// Same frequency/bandwidth as the manual example, faster and shorter range.
  static const faster = LoraPreset('faster', 867200000, 125000, 7, 5, 7);

  /// Same frequency/bandwidth as the manual example, slower and longer range.
  static const longer = LoraPreset('longer', 867200000, 125000, 10, 5, 7);

  static const all = [reticulumEu, faster, longer];
  static const custom = 'custom';

  RNodeConfig toConfig() => RNodeConfig(
    frequency: frequency,
    bandwidth: bandwidth,
    txPower: txPower,
    spreadingFactor: spreadingFactor,
    codingRate: codingRate,
  );
}

/// Every setting of the LoRa interface, persisted in the settings table.
class LoraSettings {
  const LoraSettings({
    this.enabled = false,
    this.kind,
    this.deviceId,
    this.deviceName,
    this.frequency = 867200000,
    this.bandwidth = 125000,
    this.spreadingFactor = 8,
    this.codingRate = 5,
    this.txPower = 7,
    this.flowControl = false,
    this.regulationsAcknowledged = false,
  });

  final bool enabled;
  final LoraKind? kind;

  /// BLE remote id or serial port name.
  final String? deviceId;
  final String? deviceName;
  final int frequency;
  final int bandwidth;
  final int spreadingFactor;
  final int codingRate;
  final int txPower;
  final bool flowControl;

  /// The user confirmed the local-regulations notice (shown before the radio
  /// is switched on for the first time).
  final bool regulationsAcknowledged;

  bool get hasDevice => kind != null && (deviceId ?? '').isNotEmpty;

  RNodeConfig get config => RNodeConfig(
    frequency: frequency,
    bandwidth: bandwidth,
    txPower: txPower,
    spreadingFactor: spreadingFactor,
    codingRate: codingRate,
    flowControl: flowControl,
  );

  /// Id of the preset these parameters equal, or [LoraPreset.custom].
  String get presetId {
    for (final p in LoraPreset.all) {
      if (p.frequency == frequency &&
          p.bandwidth == bandwidth &&
          p.spreadingFactor == spreadingFactor &&
          p.codingRate == codingRate &&
          p.txPower == txPower) {
        return p.id;
      }
    }
    return LoraPreset.custom;
  }

  /// Invalid field names (`frequency`, `bandwidth`, `txPower`,
  /// `spreadingFactor`, `codingRate`).
  List<String> validate() => config.validate();

  LoraSettings copyWith({
    bool? enabled,
    LoraKind? kind,
    String? deviceId,
    String? deviceName,
    int? frequency,
    int? bandwidth,
    int? spreadingFactor,
    int? codingRate,
    int? txPower,
    bool? flowControl,
    bool? regulationsAcknowledged,
    bool clearDevice = false,
  }) => LoraSettings(
    enabled: enabled ?? this.enabled,
    kind: clearDevice ? null : (kind ?? this.kind),
    deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
    deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
    frequency: frequency ?? this.frequency,
    bandwidth: bandwidth ?? this.bandwidth,
    spreadingFactor: spreadingFactor ?? this.spreadingFactor,
    codingRate: codingRate ?? this.codingRate,
    txPower: txPower ?? this.txPower,
    flowControl: flowControl ?? this.flowControl,
    regulationsAcknowledged:
        regulationsAcknowledged ?? this.regulationsAcknowledged,
  );

  LoraSettings withPreset(LoraPreset p) => copyWith(
    frequency: p.frequency,
    bandwidth: p.bandwidth,
    spreadingFactor: p.spreadingFactor,
    codingRate: p.codingRate,
    txPower: p.txPower,
  );
}

/// Keys of the LoRa settings in the settings table.
abstract final class LoraKeys {
  static const enabled = 'lora_enabled';
  static const kind = 'lora_kind';
  static const deviceId = 'lora_device_id';
  static const deviceName = 'lora_device_name';
  static const frequency = 'lora_frequency';
  static const bandwidth = 'lora_bandwidth';
  static const spreadingFactor = 'lora_sf';
  static const codingRate = 'lora_cr';
  static const txPower = 'lora_txpower';
  static const flowControl = 'lora_flow_control';
  static const regulations = 'lora_regulations_ack';
}

class LoraStore {
  LoraStore(this.repo);
  final Repo repo;

  Future<LoraSettings> load() async {
    const d = LoraSettings();
    Future<int> i(String k, int def) async =>
        int.tryParse(await repo.getSetting(k) ?? '') ?? def;
    final kind = await repo.getSetting(LoraKeys.kind);
    return LoraSettings(
      enabled: await repo.getSetting(LoraKeys.enabled) == '1',
      kind: kind == 'ble'
          ? LoraKind.ble
          : kind == 'usb'
          ? LoraKind.usb
          : null,
      deviceId: await repo.getSetting(LoraKeys.deviceId),
      deviceName: await repo.getSetting(LoraKeys.deviceName),
      frequency: await i(LoraKeys.frequency, d.frequency),
      bandwidth: await i(LoraKeys.bandwidth, d.bandwidth),
      spreadingFactor: await i(LoraKeys.spreadingFactor, d.spreadingFactor),
      codingRate: await i(LoraKeys.codingRate, d.codingRate),
      txPower: await i(LoraKeys.txPower, d.txPower),
      flowControl: await repo.getSetting(LoraKeys.flowControl) == '1',
      regulationsAcknowledged:
          await repo.getSetting(LoraKeys.regulations) == '1',
    );
  }

  Future<void> save(LoraSettings s) async {
    Future<void> w(String k, String v) => repo.setSetting(k, v);
    await w(LoraKeys.enabled, s.enabled ? '1' : '0');
    await w(LoraKeys.kind, s.kind?.name ?? '');
    await w(LoraKeys.deviceId, s.deviceId ?? '');
    await w(LoraKeys.deviceName, s.deviceName ?? '');
    await w(LoraKeys.frequency, '${s.frequency}');
    await w(LoraKeys.bandwidth, '${s.bandwidth}');
    await w(LoraKeys.spreadingFactor, '${s.spreadingFactor}');
    await w(LoraKeys.codingRate, '${s.codingRate}');
    await w(LoraKeys.txPower, '${s.txPower}');
    await w(LoraKeys.flowControl, s.flowControl ? '1' : '0');
    await w(LoraKeys.regulations, s.regulationsAcknowledged ? '1' : '0');
  }
}

/// A BLE or USB device found by a scan.
class LoraDevice {
  const LoraDevice(this.kind, this.id, this.name, {this.detail});
  final LoraKind kind;
  final String id;
  final String name;
  final String? detail;
}
