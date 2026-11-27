import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../framing/kiss.dart';
import 'interface.dart';
import 'rnode_link.dart';

/// Radio parameters of an RNode, with the validation of
/// `RNodeInterface.__init__` (RNS 1.6.1).
class RNodeConfig {
  const RNodeConfig({
    this.frequency = 867200000,
    this.bandwidth = 125000,
    this.txPower = 7,
    this.spreadingFactor = 8,
    this.codingRate = 5,
    this.flowControl = false,
    this.shortAirtimeLimit,
    this.longAirtimeLimit,
  });

  /// Hz (RNodeInterface.FREQ_MIN..FREQ_MAX = 137 MHz..3 GHz).
  final int frequency;

  /// Hz (7800..1625000).
  final int bandwidth;

  /// dBm (0..37).
  final int txPower;

  /// 5..12.
  final int spreadingFactor;

  /// 5..8 (the denominator of 4/x).
  final int codingRate;

  /// Wait for the firmware's READY frame between packets.
  final bool flowControl;

  /// Optional airtime limits in percent (0..100), sent to the firmware.
  final double? shortAirtimeLimit;
  final double? longAirtimeLimit;

  static const int freqMin = 137000000;
  static const int freqMax = 3000000000;

  /// Names of the invalid fields, empty when valid (same ranges as Python).
  List<String> validate() {
    final e = <String>[];
    if (frequency < freqMin || frequency > freqMax) e.add('frequency');
    if (txPower < 0 || txPower > 37) e.add('txPower');
    if (bandwidth < 7800 || bandwidth > 1625000) e.add('bandwidth');
    if (spreadingFactor < 5 || spreadingFactor > 12) e.add('spreadingFactor');
    if (codingRate < 5 || codingRate > 8) e.add('codingRate');
    final s = shortAirtimeLimit;
    if (s != null && (s < 0 || s > 100)) e.add('shortAirtimeLimit');
    final l = longAirtimeLimit;
    if (l != null && (l < 0 || l > 100)) e.add('longAirtimeLimit');
    return e;
  }

  bool get isValid => validate().isEmpty;

  RNodeConfig copyWith({
    int? frequency,
    int? bandwidth,
    int? txPower,
    int? spreadingFactor,
    int? codingRate,
    bool? flowControl,
  }) => RNodeConfig(
    frequency: frequency ?? this.frequency,
    bandwidth: bandwidth ?? this.bandwidth,
    txPower: txPower ?? this.txPower,
    spreadingFactor: spreadingFactor ?? this.spreadingFactor,
    codingRate: codingRate ?? this.codingRate,
    flowControl: flowControl ?? this.flowControl,
    shortAirtimeLimit: shortAirtimeLimit,
    longAirtimeLimit: longAirtimeLimit,
  );

  /// On-air bitrate in bit/s (RNodeInterface.updateBitrate).
  double get bitrate =>
      RNodeInterface.bitrateOf(spreadingFactor, codingRate, bandwidth);

  @override
  bool operator ==(Object other) =>
      other is RNodeConfig &&
      other.frequency == frequency &&
      other.bandwidth == bandwidth &&
      other.txPower == txPower &&
      other.spreadingFactor == spreadingFactor &&
      other.codingRate == codingRate &&
      other.flowControl == flowControl &&
      other.shortAirtimeLimit == shortAirtimeLimit &&
      other.longAirtimeLimit == longAirtimeLimit;

  @override
  int get hashCode => Object.hash(
    frequency,
    bandwidth,
    txPower,
    spreadingFactor,
    codingRate,
    flowControl,
    shortAirtimeLimit,
    longAirtimeLimit,
  );
}

/// Delays of the connect handshake. The defaults are those of the Python
/// reference for serial; [RNodeTiming.ble] gives its BLE values.
class RNodeTiming {
  const RNodeTiming({
    this.initDelay = const Duration(seconds: 2),
    this.detectTimeout = const Duration(seconds: 5),
    this.firmwareWait = const Duration(seconds: 1),
    this.postConfigDelay = Duration.zero,
    this.validateDelay = const Duration(milliseconds: 250),
    this.reconnectDelay = const Duration(seconds: 5),
    this.readTimeout = const Duration(milliseconds: 100),
    this.readyTimeout = const Duration(seconds: 60),
  });

  /// RNodeInterface BLE: 1.25 s read timeout, 2 s after config, 1 s validate.
  const RNodeTiming.ble()
    : initDelay = const Duration(seconds: 2),
      detectTimeout = const Duration(seconds: 5),
      firmwareWait = const Duration(seconds: 1),
      postConfigDelay = const Duration(seconds: 2),
      validateDelay = const Duration(seconds: 1),
      reconnectDelay = const Duration(seconds: 5),
      readTimeout = const Duration(milliseconds: 1250),
      readyTimeout = const Duration(seconds: 60);

  /// Almost no waiting (tests with an emulated device).
  const RNodeTiming.instant()
    : initDelay = Duration.zero,
      detectTimeout = const Duration(seconds: 2),
      firmwareWait = const Duration(milliseconds: 50),
      postConfigDelay = Duration.zero,
      validateDelay = const Duration(milliseconds: 10),
      reconnectDelay = const Duration(milliseconds: 50),
      readTimeout = const Duration(milliseconds: 100),
      readyTimeout = const Duration(seconds: 5);

  /// RNodeInterface.configure_device `sleep(2.0)` before detecting.
  final Duration initDelay;
  final Duration detectTimeout;
  final Duration firmwareWait;
  final Duration postConfigDelay;
  final Duration validateDelay;

  /// RNodeInterface.RECONNECT_WAIT.
  final Duration reconnectDelay;

  /// A partial frame older than this is dropped (readLoop `timeout`).
  final Duration readTimeout;

  /// Flow control safety: stop waiting for READY after this long.
  final Duration readyTimeout;
}

/// RSSI/SNR of a received packet.
class RNodePacketInfo {
  const RNodePacketInfo({
    required this.rssi,
    required this.snr,
    required this.bytes,
    required this.at,
  });

  /// dBm, null if the firmware did not report it.
  final int? rssi;

  /// dB.
  final double? snr;
  final int bytes;
  final DateTime at;
}

const Object _keep = Object();

/// Snapshot of everything the device reports, for the UI.
class RNodeStatus {
  const RNodeStatus({
    this.state = InterfaceState.offline,
    this.error,
    this.device,
    this.firmware,
    this.platform,
    this.mcu,
    this.reportedFrequency,
    this.reportedBandwidth,
    this.reportedTxPower,
    this.reportedSf,
    this.reportedCr,
    this.rssi,
    this.snr,
    this.quality,
    this.lastPacketAt,
    this.airtimeShort,
    this.airtimeLong,
    this.channelLoadShort,
    this.channelLoadLong,
    this.noiseFloor,
    this.batteryPercent,
    this.temperature,
    this.txBytes = 0,
    this.rxBytes = 0,
    this.bitrate = 0,
    this.hwErrors = const [],
  });

  final InterfaceState state;

  /// Why the last connect attempt failed (null while fine).
  final String? error;

  /// Link description (port or BLE name).
  final String? device;

  /// `major.minor`.
  final String? firmware;
  final String? platform;
  final String? mcu;
  final int? reportedFrequency;
  final int? reportedBandwidth;
  final int? reportedTxPower;
  final int? reportedSf;
  final int? reportedCr;

  /// Of the last received packet: dBm / dB / link quality 0..100 %.
  final int? rssi;
  final double? snr;
  final double? quality;
  final DateTime? lastPacketAt;

  /// Percent of airtime used (short window ~15 s / long window 1 h).
  final double? airtimeShort;
  final double? airtimeLong;
  final double? channelLoadShort;
  final double? channelLoadLong;
  final int? noiseFloor;
  final int? batteryPercent;
  final int? temperature;
  final int txBytes;
  final int rxBytes;

  /// On-air bitrate, bit/s (0 if unknown).
  final double bitrate;
  final List<String> hwErrors;

  RNodeStatus copyWith({
    InterfaceState? state,
    Object? error = _keep,
    Object? device = _keep,
    Object? firmware = _keep,
    Object? platform = _keep,
    Object? mcu = _keep,
    Object? reportedFrequency = _keep,
    Object? reportedBandwidth = _keep,
    Object? reportedTxPower = _keep,
    Object? reportedSf = _keep,
    Object? reportedCr = _keep,
    Object? rssi = _keep,
    Object? snr = _keep,
    Object? quality = _keep,
    Object? lastPacketAt = _keep,
    Object? airtimeShort = _keep,
    Object? airtimeLong = _keep,
    Object? channelLoadShort = _keep,
    Object? channelLoadLong = _keep,
    Object? noiseFloor = _keep,
    Object? batteryPercent = _keep,
    Object? temperature = _keep,
    int? txBytes,
    int? rxBytes,
    double? bitrate,
    List<String>? hwErrors,
  }) {
    T? pick<T>(Object? v, T? old) => identical(v, _keep) ? old : v as T?;
    return RNodeStatus(
      state: state ?? this.state,
      error: pick<String>(error, this.error),
      device: pick<String>(device, this.device),
      firmware: pick<String>(firmware, this.firmware),
      platform: pick<String>(platform, this.platform),
      mcu: pick<String>(mcu, this.mcu),
      reportedFrequency: pick<int>(reportedFrequency, this.reportedFrequency),
      reportedBandwidth: pick<int>(reportedBandwidth, this.reportedBandwidth),
      reportedTxPower: pick<int>(reportedTxPower, this.reportedTxPower),
      reportedSf: pick<int>(reportedSf, this.reportedSf),
      reportedCr: pick<int>(reportedCr, this.reportedCr),
      rssi: pick<int>(rssi, this.rssi),
      snr: pick<double>(snr, this.snr),
      quality: pick<double>(quality, this.quality),
      lastPacketAt: pick<DateTime>(lastPacketAt, this.lastPacketAt),
      airtimeShort: pick<double>(airtimeShort, this.airtimeShort),
      airtimeLong: pick<double>(airtimeLong, this.airtimeLong),
      channelLoadShort: pick<double>(channelLoadShort, this.channelLoadShort),
      channelLoadLong: pick<double>(channelLoadLong, this.channelLoadLong),
      noiseFloor: pick<int>(noiseFloor, this.noiseFloor),
      batteryPercent: pick<int>(batteryPercent, this.batteryPercent),
      temperature: pick<int>(temperature, this.temperature),
      txBytes: txBytes ?? this.txBytes,
      rxBytes: rxBytes ?? this.rxBytes,
      bitrate: bitrate ?? this.bitrate,
      hwErrors: hwErrors ?? this.hwErrors,
    );
  }
}

/// Reticulum `RNodeInterface` (RNS/Interfaces/RNodeInterface.py, RNS 1.6.1):
/// KISS over an abstract byte [RNodeLink] (USB serial, BLE UART, ...).
///
/// Mirrors the reference: detect (+ firmware, platform, MCU), firmware >= 1.52
/// check, radio configuration (frequency, bandwidth, TX power, SF, CR, airtime
/// limits, radio on), validation of the reported values (frequency within
/// 100 Hz, bandwidth, TX power, SF, radio state), optional READY flow
/// control, RSSI/SNR reporting, reconnect every [RNodeTiming.reconnectDelay],
/// and on shutdown radio off + "leave". Does not implement the callsign
/// beacon (`id_interval` / `id_callsign`) and the display framebuffer.
class RNodeInterface implements RnsInterface {
  RNodeInterface({
    required this.label,
    required RNodeLinkOpener opener,
    RNodeConfig config = const RNodeConfig(),
    this.timing = const RNodeTiming(),
  }) : _opener = opener,
       _config = config;

  static const int requiredFirmwareMajor = 1;
  static const int requiredFirmwareMinor = 52;
  static const int rssiOffset = 157;
  static const int _maxQueue = 64;

  /// `RNodeInterface.updateBitrate`, bit/s.
  static double bitrateOf(int sf, int cr, int bwHz) =>
      sf * ((4.0 / cr) / (pow(2, sf) / (bwHz / 1000))) * 1000;

  /// LoRa time on air of a [bytes] byte packet (Semtech formula: explicit
  /// header, CRC on, low-data-rate optimisation above 16 ms symbols), in
  /// seconds. An estimate: the real preamble is firmware dependent.
  static double airtimeOf(int bytes, RNodeConfig c, {int preamble = 18}) {
    final sf = c.spreadingFactor;
    final tSym = pow(2, sf) / c.bandwidth;
    final de = tSym > 0.016 ? 1 : 0;
    final n = ((8 * bytes - 4 * sf + 28 + 16) / (4 * (sf - 2 * de))).ceil();
    final payloadSyms = 8 + max(n * c.codingRate, 0);
    return (preamble + 4.25 + payloadSyms) * tSym;
  }

  final String label;
  final RNodeTiming timing;
  final RNodeLinkOpener _opener;
  RNodeConfig _config;

  RNodeConfig get config => _config;

  @override
  String get name => 'RNodeInterface[$label]';
  @override
  int get hwMtu => Kiss.rnodeHwMtu;
  @override
  bool get autoconfigureMtu => false;

  /// On-air bitrate; falls back to the configured values until the device
  /// reports its own. Used by Transport for timeouts.
  @override
  int get bitrate =>
      _status.bitrate > 0 ? _status.bitrate.round() : _config.bitrate.round();

  final _state = StreamController<InterfaceState>.broadcast();
  final _statusC = StreamController<RNodeStatus>.broadcast();
  final _rx = StreamController<Uint8List>.broadcast();
  final _packets = StreamController<RNodePacketInfo>.broadcast();
  InterfaceState _current = InterfaceState.offline;
  RNodeStatus _status = const RNodeStatus();
  RNodeLink? _link;
  KissDecoder _decoder = KissDecoder();
  Timer? _readTimer;
  bool _stopped = false;
  bool _started = false;

  // device-reported values (r_* in the reference)
  bool _detected = false;
  Completer<void>? _detectC;
  Completer<void>? _fwC;
  int? _platformId;
  int? _rFreq, _rBw, _rTx, _rSf, _rCr, _rState;
  int? _lastRssi;
  double? _lastSnr;
  double? _lastQuality;
  int? _preambleSymbols;

  // output
  bool _ready = false;
  bool _configuring = false;
  final List<Uint8List> _queue = [];
  Timer? _readyTimer;
  Future<void> _cfgTail = Future.value();
  bool _fatal = false;
  Completer<void> _failC = Completer<void>();

  @override
  InterfaceState get state => _current;
  @override
  bool get online => _current == InterfaceState.online;
  @override
  Stream<InterfaceState> get stateChanges => _state.stream;
  @override
  Stream<Uint8List> get received => _rx.stream;

  RNodeStatus get status => _status;
  Stream<RNodeStatus> get statusChanges => _statusC.stream;

  /// One event per received packet, with its RSSI and SNR.
  Stream<RNodePacketInfo> get packets => _packets.stream;

  void _setStatus(RNodeStatus s) {
    _status = s;
    if (!_statusC.isClosed) _statusC.add(s);
  }

  void _set(InterfaceState s) {
    if (_current != s) {
      _current = s;
      if (!_state.isClosed) _state.add(s);
    }
    if (_status.state != s) _setStatus(_status.copyWith(state: s));
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stopped = false;
    final bad = _config.validate();
    if (bad.isNotEmpty) {
      _setStatus(
        _status.copyWith(error: 'invalid configuration: ${bad.join(', ')}'),
      );
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    while (!_stopped) {
      try {
        await _session();
      } on Object catch (e) {
        if (!_stopped) _setStatus(_status.copyWith(error: '$e'));
      }
      _teardownSession();
      if (_stopped) return;
      _set(InterfaceState.offline);
      await Future<void>.delayed(timing.reconnectDelay);
    }
  }

  void _resetRadioState() {
    _rFreq = _rBw = _rTx = _rSf = _rCr = _rState = null;
    _detected = false;
    _fatal = false;
    _platformId = null;
    _ready = false;
    _queue.clear();
  }

  Future<void> _session() async {
    _set(InterfaceState.connecting);
    final link = await _opener();
    if (_stopped) {
      await link.close();
      return;
    }
    _link = link;
    _decoder = KissDecoder();
    _resetRadioState();
    _setStatus(_status.copyWith(device: link.description));
    final sub = link.received.listen(_onBytes, onError: (Object _) {});
    try {
      await Future<void>.delayed(timing.initDelay);
      if (_stopped) return;
      _detectC = Completer<void>();
      _fwC = Completer<void>();
      await _w([
        Kiss.fend, Kiss.cmdDetect, Kiss.detectReq, Kiss.fend,
        Kiss.cmdFwVersion, 0x00, Kiss.fend,
        Kiss.cmdPlatform, 0x00, Kiss.fend,
        Kiss.cmdMcu, 0x00, Kiss.fend, //
      ]);
      await _detectC!.future.timeout(timing.detectTimeout, onTimeout: () {});
      if (_fatal) throw StateError(_status.error ?? 'device error');
      if (!_detected) throw StateError('could not detect an RNode');
      await _fwC!.future.timeout(timing.firmwareWait, onTimeout: () {});
      if (_fatal) throw StateError(_status.error ?? 'device error');
      await _configure();
      if (_fatal) throw StateError(_status.error ?? 'device error');
      _setStatus(_status.copyWith(error: null));
      _set(InterfaceState.online);
      _ready = true;
      _processQueue();
      await Future.any<void>([link.closed, _failC.future]);
      if (!_stopped && _status.error == null) {
        _setStatus(_status.copyWith(error: 'connection lost'));
      }
    } finally {
      await sub.cancel();
    }
  }

  void _fail(String why) {
    _fatal = true;
    _setStatus(_status.copyWith(error: why));
    if (!_failC.isCompleted) _failC.complete();
    // unblock a handshake that is waiting
    if (!(_detectC?.isCompleted ?? true)) _detectC!.complete();
    if (!(_fwC?.isCompleted ?? true)) _fwC!.complete();
  }

  void _teardownSession() {
    _readTimer?.cancel();
    _readyTimer?.cancel();
    _ready = false;
    _configuring = false;
    _queue.clear();
    final l = _link;
    _link = null;
    if (l != null) unawaited(l.close().catchError((Object _) {}));
    _failC = Completer<void>();
  }

  // ------------------------------------------------------------ commands

  /// The exact byte sequences the reference writes to configure [c]
  /// (initRadio: frequency, bandwidth, TX power, SF, CR, airtime limits,
  /// radio on).
  static List<Uint8List> configFrames(RNodeConfig c) {
    Uint8List cmd(int command, List<int> payload) => Uint8List.fromList([
      Kiss.fend,
      command,
      ...Kiss.escape(payload),
      Kiss.fend,
    ]);
    List<int> u32(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];
    List<int> u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
    return [
      cmd(Kiss.cmdFrequency, u32(c.frequency)),
      cmd(Kiss.cmdBandwidth, u32(c.bandwidth)),
      cmd(Kiss.cmdTxPower, [c.txPower]),
      cmd(Kiss.cmdSf, [c.spreadingFactor]),
      cmd(Kiss.cmdCr, [c.codingRate]),
      if (c.shortAirtimeLimit != null)
        cmd(Kiss.cmdStAlock, u16((c.shortAirtimeLimit! * 100).toInt())),
      if (c.longAirtimeLimit != null)
        cmd(Kiss.cmdLtAlock, u16((c.longAirtimeLimit! * 100).toInt())),
      cmd(Kiss.cmdRadioState, [Kiss.radioStateOn]),
    ];
  }

  Future<void> _w(List<int> bytes) async {
    final l = _link;
    if (l == null) throw StateError('not connected');
    await l.write(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  /// Writes the radio configuration and validates what the device reports
  /// (initRadio + validateRadioState). Throws on a mismatch.
  Future<void> _configure() async {
    _rFreq = _rBw = _rTx = _rSf = _rCr = _rState = null;
    for (final f in configFrames(_config)) {
      await _w(f);
    }
    await Future<void>.delayed(timing.postConfigDelay);
    await Future<void>.delayed(timing.validateDelay);
    final c = _config;
    final bad = <String>[];
    if (_rFreq != null && (c.frequency - _rFreq!).abs() > 100) {
      bad.add('frequency');
    }
    if (c.bandwidth != _rBw) bad.add('bandwidth');
    if (c.txPower != _rTx) bad.add('TX power');
    if (c.spreadingFactor != _rSf) bad.add('spreading factor');
    if (_rState != Kiss.radioStateOn) bad.add('radio state');
    if (bad.isNotEmpty) {
      throw StateError(
        'the radio did not accept the configuration '
        '(${bad.join(', ')} mismatch)',
      );
    }
  }

  /// Applies new radio parameters to the running device (and to every later
  /// reconnect). Throws [ArgumentError] for invalid values. If the device
  /// rejects them the interface goes offline with an error and retries.
  Future<void> reconfigure(RNodeConfig c) {
    final bad = c.validate();
    if (bad.isNotEmpty) {
      throw ArgumentError('invalid RNode configuration: ${bad.join(', ')}');
    }
    _config = c;
    final link = _link;
    if (!online || link == null) return Future.value();
    return _cfgTail = _cfgTail.then((_) async {
      if (_link != link || !online) return;
      _configuring = true;
      try {
        await _configure();
        _setStatus(_status.copyWith(error: null));
      } on Object catch (e) {
        _fail('$e');
        return;
      } finally {
        _configuring = false;
      }
      _processQueue();
    });
  }

  // ------------------------------------------------------------ sending

  @override
  Future<bool> send(Uint8List raw) async {
    if (!online || _link == null) return false;
    if (_ready && !_configuring) {
      await _transmit(raw);
    } else {
      if (_queue.length >= _maxQueue) _queue.removeAt(0);
      _queue.add(raw);
    }
    return true;
  }

  Future<void> _transmit(Uint8List raw) async {
    if (_config.flowControl) {
      _ready = false;
      _readyTimer?.cancel();
      _readyTimer = Timer(timing.readyTimeout, () {
        _ready = true;
        _processQueue();
      });
    }
    try {
      await _w(Kiss.frame(raw));
      _setStatus(_status.copyWith(txBytes: _status.txBytes + raw.length));
    } on Object {
      _fail('write failed');
    }
  }

  /// RNodeInterface.process_queue: the firmware is ready for one more packet.
  void _processQueue() {
    if (_configuring) return;
    if (_queue.isNotEmpty) {
      final d = _queue.removeAt(0);
      _ready = true;
      unawaited(_transmit(d));
    } else {
      _ready = true;
    }
  }

  // ------------------------------------------------------------ receiving

  /// Feeds device bytes without a session (tests of the frame parser).
  void debugFeed(List<int> bytes) => _onBytes(Uint8List.fromList(bytes));

  void _onBytes(Uint8List chunk) {
    _readTimer?.cancel();
    for (final f in _decoder.feed(chunk)) {
      _onFrame(f);
    }
    if (_decoder.hasPartialData) {
      _readTimer = Timer(timing.readTimeout, _decoder.reset);
    }
  }

  void _onFrame(KissFrame f) {
    final d = f.data;
    int u32(int o) =>
        (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
    int u16(int o) => (d[o] << 8) | d[o + 1];
    switch (f.command) {
      case Kiss.cmdData:
        if (d.isEmpty) return;
        final now = DateTime.now();
        _setStatus(
          _status.copyWith(
            rxBytes: _status.rxBytes + d.length,
            rssi: _lastRssi,
            snr: _lastSnr,
            quality: _lastQuality,
            lastPacketAt: now,
          ),
        );
        if (!_packets.isClosed) {
          _packets.add(
            RNodePacketInfo(
              rssi: _lastRssi,
              snr: _lastSnr,
              bytes: d.length,
              at: now,
            ),
          );
        }
        if (!_rx.isClosed) _rx.add(d);
      case Kiss.cmdFrequency when d.length >= 4:
        _rFreq = u32(0);
        _setStatus(
          _status.copyWith(
            reportedFrequency: _rFreq,
            bitrate: _reportedBitrate(),
          ),
        );
      case Kiss.cmdBandwidth when d.length >= 4:
        _rBw = u32(0);
        _setStatus(
          _status.copyWith(
            reportedBandwidth: _rBw,
            bitrate: _reportedBitrate(),
          ),
        );
      case Kiss.cmdTxPower when d.isNotEmpty:
        _rTx = d[0];
        _setStatus(_status.copyWith(reportedTxPower: _rTx));
      case Kiss.cmdSf when d.isNotEmpty:
        _rSf = d[0];
        _setStatus(
          _status.copyWith(reportedSf: _rSf, bitrate: _reportedBitrate()),
        );
      case Kiss.cmdCr when d.isNotEmpty:
        _rCr = d[0];
        _setStatus(
          _status.copyWith(reportedCr: _rCr, bitrate: _reportedBitrate()),
        );
      case Kiss.cmdRadioState when d.isNotEmpty:
        _rState = d[0];
      case Kiss.cmdFwVersion when d.length >= 2:
        _onFirmware(d[0], d[1]);
      case Kiss.cmdStatRssi when d.isNotEmpty:
        _lastRssi = d[0] - rssiOffset;
      case Kiss.cmdStatSnr when d.isNotEmpty:
        final s = d[0] >= 128 ? d[0] - 256 : d[0];
        _lastSnr = s * 0.25;
        final sf = _rSf;
        if (sf != null) {
          final qMin = -9 - (sf - 7) * 2;
          final q = ((_lastSnr! - qMin) / (6 - qMin)) * 100;
          _lastQuality = (q.clamp(0.0, 100.0) * 10).round() / 10;
        }
      case Kiss.cmdStatChtm when d.length >= 11:
        _setStatus(
          _status.copyWith(
            airtimeShort: u16(0) / 100,
            airtimeLong: u16(2) / 100,
            channelLoadShort: u16(4) / 100,
            channelLoadLong: u16(6) / 100,
            noiseFloor: d[9] - rssiOffset,
          ),
        );
      case Kiss.cmdStatPhyprm when d.length >= 12:
        _preambleSymbols = u16(4);
      case Kiss.cmdStatBat when d.length >= 2:
        _setStatus(_status.copyWith(batteryPercent: d[1].clamp(0, 100)));
      case Kiss.cmdStatTemp when d.isNotEmpty:
        final t = d[0] - 120;
        _setStatus(
          _status.copyWith(temperature: (t >= -30 && t <= 90) ? t : null),
        );
      case Kiss.cmdPlatform when d.isNotEmpty:
        _platformId = d[0];
        _setStatus(_status.copyWith(platform: _platformName(d[0])));
      case Kiss.cmdMcu when d.isNotEmpty:
        _setStatus(
          _status.copyWith(mcu: '0x${d[0].toRadixString(16).padLeft(2, '0')}'),
        );
      case Kiss.cmdDetect when d.isNotEmpty:
        _detected = d[0] == Kiss.detectResp;
        if (!(_detectC?.isCompleted ?? true)) _detectC!.complete();
      case Kiss.cmdReady:
        _readyTimer?.cancel();
        _processQueue();
      case Kiss.cmdReset when d.isNotEmpty:
        if (d[0] == 0xF8 && _platformId == Kiss.platformEsp32 && online) {
          _fail('device reset');
        }
      case Kiss.cmdError when d.isNotEmpty:
        _onError(d[0]);
    }
  }

  void _onFirmware(int maj, int min) {
    final ok =
        maj > requiredFirmwareMajor ||
        (maj >= requiredFirmwareMajor && min >= requiredFirmwareMinor);
    _setStatus(_status.copyWith(firmware: '$maj.$min'));
    if (!ok) {
      _fail(
        'RNode firmware $maj.$min is too old '
        '(need $requiredFirmwareMajor.$requiredFirmwareMinor)',
      );
    }
    if (!(_fwC?.isCompleted ?? true)) _fwC!.complete();
  }

  void _onError(int code) {
    switch (code) {
      case Kiss.errorInitRadio:
        _fail('radio initialisation failure');
      case Kiss.errorTxFailed:
        _fail('hardware transmit failure');
      case Kiss.errorMemoryLow:
        _setStatus(
          _status.copyWith(hwErrors: [..._status.hwErrors, 'memory exhausted']),
        );
      case Kiss.errorModemTimeout:
        _setStatus(
          _status.copyWith(hwErrors: [..._status.hwErrors, 'modem timeout']),
        );
      default:
        _fail('unknown hardware failure (0x${code.toRadixString(16)})');
    }
  }

  double _reportedBitrate() {
    final sf = _rSf, cr = _rCr, bw = _rBw;
    if (sf != null && cr != null && bw != null && cr > 0 && bw > 0) {
      return bitrateOf(sf, cr, bw);
    }
    return 0;
  }

  static String _platformName(int p) => switch (p) {
    Kiss.platformAvr => 'AVR',
    Kiss.platformEsp32 => 'ESP32',
    Kiss.platformNrf52 => 'nRF52',
    _ => '0x${p.toRadixString(16)}',
  };

  /// Estimated time on air of a [bytes] byte packet with the active
  /// parameters, seconds.
  double airtime(int bytes) =>
      airtimeOf(bytes, _config, preamble: _preambleSymbols ?? 18);

  // ------------------------------------------------------------ shutdown

  /// Radio off, "host left", close the link (RNodeInterface.detach), then
  /// close the streams. The interface is not reusable afterwards.
  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final l = _link;
    if (l != null) {
      try {
        if (_platformId == Kiss.platformEsp32 ||
            _platformId == Kiss.platformNrf52) {
          // external framebuffer off (CMD_FB_EXT 0x41)
          await l.write(Uint8List.fromList([Kiss.fend, 0x41, 0x00, Kiss.fend]));
        }
        await l.write(
          Uint8List.fromList([
            Kiss.fend,
            Kiss.cmdRadioState,
            Kiss.radioStateOff,
            Kiss.fend,
          ]),
        );
        await l.write(
          Uint8List.fromList([Kiss.fend, Kiss.cmdLeave, 0xFF, Kiss.fend]),
        );
      } on Object {
        // already gone
      }
    }
    _teardownSession();
    _set(InterfaceState.offline);
    await _state.close();
    await _statusC.close();
    await _rx.close();
    await _packets.close();
  }
}
