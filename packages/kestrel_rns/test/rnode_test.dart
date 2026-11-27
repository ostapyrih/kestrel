import 'dart:async';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/rnode_emulator.dart';
import 'support/vectors.dart';

RNodeInterface _iface(
  EmulatedRNode emu, {
  RNodeConfig config = const RNodeConfig(),
}) => RNodeInterface(
  label: 'test',
  opener: emu.open,
  config: config,
  timing: const RNodeTiming.instant(),
);

Future<void> _until(bool Function() cond, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not reached in ${ms}ms');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final v = loadVectors('rnode.json');

  group('golden vectors (bytes written by Python RNodeInterface)', () {
    test('detect request and shutdown', () {
      // detect is written by the session; compare with the emulator's view
      expect(v['detect'], 'c00873c05000c04800c04900c0');
      expect(v['shutdown'], ['c00600c0', 'c00affc0']);
    });

    for (final c in maps(v['configs'])) {
      test('config ${c['name']}', () {
        final cfg = RNodeConfig(
          frequency: c['freq']! as int,
          bandwidth: c['bw']! as int,
          txPower: c['txp']! as int,
          spreadingFactor: c['sf']! as int,
          codingRate: c['cr']! as int,
          shortAirtimeLimit: (c['st'] as num?)?.toDouble(),
          longAirtimeLimit: (c['lt'] as num?)?.toDouble(),
        );
        expect(
          RNodeInterface.configFrames(cfg).map(hex).toList(),
          (c['frames']! as List<Object?>).cast<String>(),
        );
        expect(cfg.bitrate, closeTo((c['bitrate']! as num).toDouble(), 1e-6));
      });
    }

    test('data frames and flow control bookkeeping', () {
      for (final d in maps(v['data_out'])) {
        expect(hex(Kiss.frame(unhex(d['payload'] as String?))), d['frame']);
        expect(d['ready_after'], isFalse);
      }
    });

    for (final s in maps(v['scripts'])) {
      test('parse ${s['name']}', () async {
        final i = RNodeInterface(
          label: 'v',
          opener: () => throw StateError('unused'),
          config: RNodeConfig(spreadingFactor: s['name'] == 'rx_snr_positive_sf12' ? 8 : 8),
        );
        final got = <String>[];
        i.packets.listen((p) => got.add('${p.rssi}/${p.snr}'));
        final data = <String>[];
        i.received.listen((d) => data.add(hex(d)));
        i.debugFeed(unhex(s['stream'] as String?));
        await Future<void>.delayed(Duration.zero);
        final st = i.status;
        final fw = (s['fw']! as List<Object?>).cast<int>();
        if (fw[0] != 0) expect(st.firmware, '${fw[0]}.${fw[1]}');
        if (s['platform'] != null) {
          expect(st.platform, 'ESP32'); // 0x80
          expect(
            st.mcu,
            '0x${(s['mcu']! as int).toRadixString(16).padLeft(2, '0')}',
          );
        }
        expect(st.reportedFrequency, s['r_frequency']);
        expect(st.reportedBandwidth, s['r_bandwidth']);
        expect(st.reportedTxPower, s['r_txpower']);
        expect(st.reportedSf, s['r_sf']);
        expect(st.reportedCr, s['r_cr']);
        expect(st.bitrate, closeTo((s['bitrate']! as num).toDouble(), 1e-6));
        expect(data, (s['data']! as List<Object?>).cast<String>());
        if (s['data'].toString() != '[]') {
          expect(st.rssi, s['rssi']);
          expect(st.snr, s['snr']);
          expect(st.quality, s['quality']);
        }
        final at = (s['airtime']! as List<Object?>);
        if (at[4] != null) {
          expect(st.airtimeShort, at[0]);
          expect(st.airtimeLong, at[1]);
          expect(st.channelLoadShort, at[2]);
          expect(st.channelLoadLong, at[3]);
          expect(st.noiseFloor, at[5]);
          expect(st.batteryPercent, (s['battery']! as List<Object?>)[1]);
          expect(st.temperature, s['temp']);
        }
      });
    }

    test('constants', () {
      expect(v['required_fw'], [
        RNodeInterface.requiredFirmwareMajor,
        RNodeInterface.requiredFirmwareMinor,
      ]);
      expect(v['rssi_offset'], RNodeInterface.rssiOffset);
    });
  });

  group('RNodeConfig', () {
    test('defaults are the Reticulum manual example', () {
      const c = RNodeConfig();
      expect(c.frequency, 867200000);
      expect(c.bandwidth, 125000);
      expect(c.txPower, 7);
      expect(c.spreadingFactor, 8);
      expect(c.codingRate, 5);
      expect(c.isValid, isTrue);
      expect(c.bitrate, closeTo(3125, 1e-9));
    });

    test('validation ranges match RNodeInterface', () {
      expect(const RNodeConfig(frequency: 136999999).validate(), ['frequency']);
      expect(const RNodeConfig(frequency: 3000000001).validate(), [
        'frequency',
      ]);
      expect(const RNodeConfig(txPower: 38).validate(), ['txPower']);
      expect(const RNodeConfig(txPower: -1).validate(), ['txPower']);
      expect(const RNodeConfig(bandwidth: 7799).validate(), ['bandwidth']);
      expect(const RNodeConfig(bandwidth: 1625001).validate(), ['bandwidth']);
      expect(const RNodeConfig(spreadingFactor: 4).validate(), [
        'spreadingFactor',
      ]);
      expect(const RNodeConfig(spreadingFactor: 13).validate(), [
        'spreadingFactor',
      ]);
      expect(const RNodeConfig(codingRate: 4).validate(), ['codingRate']);
      expect(const RNodeConfig(codingRate: 9).validate(), ['codingRate']);
      expect(const RNodeConfig(shortAirtimeLimit: 101).isValid, isFalse);
      expect(
        const RNodeConfig(
          frequency: 137000000,
          txPower: 0,
          bandwidth: 7800,
          spreadingFactor: 5,
          codingRate: 8,
        ).isValid,
        isTrue,
      );
    });

    test('airtime estimate is plausible', () {
      // SF8/BW125: a 500 byte packet takes about 1.5 s on air
      final t = RNodeInterface.airtimeOf(500, const RNodeConfig());
      expect(t, inInclusiveRange(1.2, 2.2));
      final slow = RNodeInterface.airtimeOf(
        500,
        const RNodeConfig(spreadingFactor: 12),
      );
      expect(slow, greaterThan(t * 8));
    });
  });

  group('RNodeInterface with an emulated device', () {
    late EmulatedRNode emu;
    late RNodeInterface i;
    tearDown(() async {
      await i.stop();
    });

    test('handshake: detect, configure, validate, online', () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      expect(emu.radioOn, isTrue);
      expect(emu.frequency, 867200000);
      expect(emu.bandwidth, 125000);
      expect(emu.txPower, 7);
      expect(emu.sf, 8);
      expect(emu.cr, 5);
      // exact bytes: detect first, then the configuration frames
      expect(hex(emu.rawWrites.first), v['detect']);
      expect(
        emu.rawWrites.skip(1).map(hex).toList(),
        RNodeInterface.configFrames(const RNodeConfig()).map(hex).toList(),
      );
      expect(i.status.firmware, '1.82');
      expect(i.status.platform, 'ESP32');
      expect(i.status.device, 'Emulated RNode');
      expect(i.bitrate, 3125);
      expect(i.hwMtu, 508);
      expect(i.autoconfigureMtu, isFalse);
    });

    test('data both ways with RSSI and SNR, byte-escaped, chunked by 1', () async {
      emu = EmulatedRNode(chunkSize: 1);
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      final pkt = Uint8List.fromList([0xC0, 0xDB, 0xDC, 0xDD, 1, 2, 3]);
      final rx = i.received.first;
      final info = i.packets.first;
      emu.receiveFromAir(pkt, rssi: -91, snr: -3.25);
      expect(await rx, pkt);
      final p = await info;
      expect(p.rssi, -91);
      expect(p.snr, -3.25);
      expect(i.status.rssi, -91);
      expect(i.status.snr, -3.25);
      expect(i.status.quality, isNotNull);
      expect(await i.send(pkt), isTrue);
      await _until(() => emu.transmitted.isNotEmpty);
      expect(emu.transmitted.single, pkt);
    });

    test('flow control holds packets until READY', () async {
      emu = EmulatedRNode()..autoReady = false;
      i = _iface(emu, config: const RNodeConfig(flowControl: true));
      await i.start();
      await _until(() => i.online);
      for (final s in ['one', 'two', 'three']) {
        await i.send(Uint8List.fromList(s.codeUnits));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emu.transmitted.map(String.fromCharCodes), ['one']);
      emu.sendReady();
      await _until(() => emu.transmitted.length == 2);
      emu.sendReady();
      await _until(() => emu.transmitted.length == 3);
      expect(emu.transmitted.map(String.fromCharCodes), [
        'one',
        'two',
        'three',
      ]);
    });

    test('without flow control packets go out immediately', () async {
      emu = EmulatedRNode()..autoReady = false;
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      for (final s in ['a', 'b']) {
        await i.send(Uint8List.fromList(s.codeUnits));
      }
      expect(emu.transmitted, hasLength(2));
    });

    test('send while offline returns false', () async {
      emu = EmulatedRNode()..answerDetect = false;
      i = _iface(emu);
      await i.start();
      expect(await i.send(Uint8List(3)), isFalse);
    });

    test('a device that reports another spreading factor is rejected', () async {
      emu = EmulatedRNode()..refuseSf = true;
      i = _iface(emu);
      await i.start();
      await _until(() => i.status.error != null);
      expect(i.status.error, contains('spreading factor'));
      expect(i.online, isFalse);
      await _until(() => emu.opens >= 2); // keeps retrying
    });

    test('bandwidth mismatch is reported', () async {
      emu = EmulatedRNode()..refuseBandwidth = true;
      i = _iface(emu);
      await i.start();
      await _until(() => i.status.error != null);
      expect(i.status.error, contains('bandwidth'));
    });

    test('firmware older than 1.52 is rejected', () async {
      emu = EmulatedRNode(fwMinor: 51);
      i = _iface(emu);
      await i.start();
      await _until(() => i.status.error != null);
      expect(i.status.error, contains('too old'));
      expect(i.status.firmware, '1.51');
      expect(i.online, isFalse);
      expect(emu.radioOn, isFalse);
    });

    test('firmware 1.52 and 2.0 are accepted', () async {
      for (final (ma, mi) in [(1, 52), (2, 0)]) {
        emu = EmulatedRNode(fwMajor: ma, fwMinor: mi);
        i = _iface(emu);
        await i.start();
        await _until(() => i.online);
        await i.stop();
      }
      i = _iface(emu); // for tearDown
    });

    test('no answer to detect: offline with an error', () async {
      emu = EmulatedRNode()..answerDetect = false;
      i = RNodeInterface(
        label: 't',
        opener: emu.open,
        timing: const RNodeTiming(
          initDelay: Duration.zero,
          detectTimeout: Duration(milliseconds: 100),
          reconnectDelay: Duration(milliseconds: 50),
        ),
      );
      await i.start();
      await _until(() => i.status.error != null);
      expect(i.status.error, contains('detect'));
      expect(i.online, isFalse);
    });

    test('hardware errors: init failure reconnects, memory low is recorded',
        () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      emu.emit(Kiss.cmdError, [Kiss.errorMemoryLow]);
      await _until(() => i.status.hwErrors.isNotEmpty);
      expect(i.online, isTrue);
      emu.emit(Kiss.cmdError, [Kiss.errorInitRadio]);
      await _until(() => !i.online);
      expect(i.status.error, contains('initialisation'));
      await _until(() => i.online); // reconnected
      expect(emu.opens, 2);
    });

    test('reconnects after the device is unplugged', () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      final states = <InterfaceState>[];
      i.stateChanges.listen(states.add);
      await i.start();
      await _until(() => i.online);
      emu.unplug();
      await _until(() => !i.online);
      await _until(() => i.online);
      expect(emu.opens, 2);
      expect(states, contains(InterfaceState.offline));
      expect(emu.radioOn, isTrue);
    });

    test('live reconfigure re-sends the parameters without reconnecting',
        () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      const next = RNodeConfig(
        frequency: 868300000,
        bandwidth: 250000,
        txPower: 10,
        spreadingFactor: 7,
        codingRate: 6,
      );
      await i.reconfigure(next);
      expect(i.online, isTrue);
      expect(emu.opens, 1);
      expect(emu.frequency, 868300000);
      expect(emu.bandwidth, 250000);
      expect(emu.sf, 7);
      expect(emu.cr, 6);
      expect(emu.txPower, 10);
      expect(i.config, next);
      expect(i.bitrate, RNodeInterface.bitrateOf(7, 6, 250000).round());
    });

    test('reconfigure rejects invalid values and survives a refused one',
        () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      expect(
        () => i.reconfigure(const RNodeConfig(spreadingFactor: 3)),
        throwsArgumentError,
      );
      emu.refuseSf = true;
      await i.reconfigure(const RNodeConfig(spreadingFactor: 9));
      await _until(() => !i.online);
      expect(i.status.error, contains('spreading factor'));
    });

    test('stop switches the radio off and says goodbye', () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      await i.stop();
      expect(emu.radioOn, isFalse);
      expect(emu.leaveReceived, isTrue);
      expect(emu.framebufferOff, isTrue); // ESP32 has a display
      // the last writes are exactly radio-off, leave
      final tail = emu.rawWrites.reversed.take(2).toList().reversed.map(hex);
      expect(tail.toList(), (v['shutdown']! as List<Object?>).cast<String>());
      expect(i.state, InterfaceState.offline);
    });

    test('a partial frame is dropped after the read timeout', () async {
      emu = EmulatedRNode();
      i = _iface(emu);
      await i.start();
      await _until(() => i.online);
      final got = <Uint8List>[];
      i.received.listen(got.add);
      // half a data frame, then silence, then a complete one
      emu.emitRaw([Kiss.fend, Kiss.cmdData, 1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      emu.receiveFromAir(Uint8List.fromList([9, 9]), rssi: -70, snr: 1);
      await _until(() => got.isNotEmpty);
      expect(got.single, [9, 9]);
    });
  });
}
