import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/lora/lora_model.dart';
import 'package:kestrel/lora/lora_providers.dart';
import 'package:kestrel/lora/lora_screen.dart';
import 'package:kestrel/lora/lora_service.dart';
import 'package:kestrel/lora/lora_transports.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixtures.dart';

class FakeLora implements LoraController {
  FakeLora({
    LoraSettings settings = const LoraSettings(),
    this.kinds = const {LoraKind.usb},
  }) : _view = LoraView(settings: settings);

  LoraView _view;
  final Set<LoraKind> kinds;
  final updates = <LoraSettings>[];
  final _c = StreamController<LoraView>.broadcast();
  List<LoraDevice> usb = const [LoraDevice(LoraKind.usb, 'COM7', 'COM7')];

  @override
  LoraView get view => _view;
  @override
  Stream<LoraView> get changes => _c.stream;
  @override
  Set<LoraKind> get supportedKinds => kinds;
  @override
  Stream<List<LoraDevice>> scanBle() => Stream.value(const [
    LoraDevice(LoraKind.ble, 'AA:BB', 'RNode 1234', detail: '-60 dBm'),
  ]);
  @override
  List<LoraDevice> listUsb() => usb;
  @override
  Future<void> update(LoraSettings next) async {
    updates.add(next);
    _view = LoraView(settings: next, status: _view.status);
    _c.add(_view);
  }

  void setStatus(RNodeStatus s) {
    _view = LoraView(settings: _view.settings, status: s);
    _c.add(_view);
  }
}

/// A firmware that answers like an RNode (detect, config echo).
class _Link implements RNodeLink {
  _Link(this.log);
  final List<Uint8List> log;
  final _rx = StreamController<Uint8List>();
  final _closed = Completer<void>();
  final _dec = KissDecoder();

  @override
  String get description => 'fake';
  @override
  Stream<Uint8List> get received => _rx.stream;
  @override
  Future<void> get closed => _closed.future;
  @override
  Future<void> write(Uint8List bytes) async {
    log.add(bytes);
    // detect is written as three frames sharing FENDs
    if (bytes.length == 13) {
      _rx.add(Kiss.frame([Kiss.detectResp], command: Kiss.cmdDetect));
      _rx.add(Kiss.frame([1, 82], command: Kiss.cmdFwVersion));
      return;
    }
    for (final f in _dec.feed(bytes)) {
      if (f.command == Kiss.cmdData) continue;
      if (f.command == Kiss.cmdRadioState) {
        _rx.add(Kiss.frame(f.data, command: f.command));
      } else if ([
        Kiss.cmdFrequency,
        Kiss.cmdBandwidth,
        Kiss.cmdTxPower,
        Kiss.cmdSf,
        Kiss.cmdCr,
      ].contains(f.command)) {
        _rx.add(Kiss.frame(f.data, command: f.command));
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }
}

class _Transports extends LoraTransports {
  final log = <Uint8List>[];
  int opens = 0;
  @override
  Set<LoraKind> get supported => {LoraKind.usb};
  @override
  Stream<List<LoraDevice>> scanBle() => const Stream.empty();
  @override
  List<LoraDevice> listUsb() => const [];
  @override
  Future<RNodeLink> open(LoraKind kind, String id, String name) async {
    opens++;
    return _Link(log);
  }

  @override
  RNodeTiming timing(LoraKind kind) => const RNodeTiming.instant();
}

class _Node extends FakeNode {
  final added = <RnsInterface>[];
  final removed = <RnsInterface>[];
  @override
  Future<void> addInterface(RnsInterface i) async {
    added.add(i);
    await i.start(); // what Transport.addInterface does
  }

  @override
  Future<void> removeInterface(RnsInterface i) async {
    removed.add(i);
    await i.stop();
  }
}

Future<void> _until(bool Function() c) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!c()) {
    if (DateTime.now().isAfter(end)) fail('timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('LoraSettings', () {
    test('defaults are the Reticulum manual example (EU 868)', () {
      const s = LoraSettings();
      expect(s.frequency, 867200000);
      expect(s.bandwidth, 125000);
      expect(s.spreadingFactor, 8);
      expect(s.codingRate, 5);
      expect(s.txPower, 7);
      expect(s.enabled, isFalse);
      expect(s.presetId, 'reticulum_eu');
      expect(s.validate(), isEmpty);
    });

    test('preset detection and custom', () {
      expect(
        const LoraSettings().withPreset(LoraPreset.faster).presetId,
        'faster',
      );
      expect(const LoraSettings(txPower: 14).presetId, LoraPreset.custom);
    });

    test('ranges are validated like RNodeInterface', () {
      expect(const LoraSettings(frequency: 100000000).validate(), [
        'frequency',
      ]);
      expect(const LoraSettings(spreadingFactor: 13).validate(), [
        'spreadingFactor',
      ]);
    });
  });

  group('LoraStore', () {
    test('round trips every field through the settings table', () async {
      final adb = await AppDatabase.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(adb.close);
      final store = LoraStore(Repo(adb));
      expect((await store.load()).presetId, 'reticulum_eu');
      const s = LoraSettings(
        enabled: true,
        kind: LoraKind.ble,
        deviceId: 'AA:BB:CC',
        deviceName: 'RNode 1234',
        frequency: 868300000,
        bandwidth: 250000,
        spreadingFactor: 9,
        codingRate: 6,
        txPower: 12,
        flowControl: true,
        regulationsAcknowledged: true,
      );
      await store.save(s);
      final l = await store.load();
      expect(l.enabled, isTrue);
      expect(l.kind, LoraKind.ble);
      expect(l.deviceId, 'AA:BB:CC');
      expect(l.deviceName, 'RNode 1234');
      expect(l.frequency, 868300000);
      expect(l.bandwidth, 250000);
      expect(l.spreadingFactor, 9);
      expect(l.codingRate, 6);
      expect(l.txPower, 12);
      expect(l.flowControl, isTrue);
      expect(l.regulationsAcknowledged, isTrue);
    });
  });

  group('LoraService', () {
    late Repo repo;
    late _Node node;
    late _Transports tr;
    late LoraService svc;

    setUp(() async {
      final adb = await AppDatabase.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(adb.close);
      repo = Repo(adb);
      node = _Node();
      tr = _Transports();
      svc = LoraService(store: LoraStore(repo), node: node, transports: tr);
    });

    const dev = LoraSettings(
      kind: LoraKind.usb,
      deviceId: 'COM7',
      deviceName: 'COM7',
    );

    test(
      'nothing connects while disabled or without the regs notice',
      () async {
        await svc.start();
        expect(node.added, isEmpty);
        await svc.update(dev.copyWith(enabled: true));
        expect(node.added, isEmpty, reason: 'regulations not acknowledged');
        expect(svc.settings.enabled, isTrue); // still stored
      },
    );

    test('enable connects, parameters reconfigure live, disable switches the radio off', () async {
      await svc.start();
      await svc.update(
        dev.copyWith(enabled: true, regulationsAcknowledged: true),
      );
      expect(node.added, hasLength(1));
      final i = svc.iface!;
      await _until(() => i.online);
      expect(svc.view.connected, isTrue);
      expect(i.config.frequency, 867200000);

      await svc.update(svc.settings.copyWith(spreadingFactor: 10, txPower: 5));
      expect(tr.opens, 1, reason: 'reconfigured in place, not reconnected');
      expect(i.config.spreadingFactor, 10);
      expect(i.config.txPower, 5);
      expect(node.added, hasLength(1));
      // persisted
      expect((await LoraStore(repo).load()).spreadingFactor, 10);

      await svc.update(svc.settings.copyWith(enabled: false));
      expect(node.removed, [i]);
      expect(i.state, InterfaceState.offline);
      // radio off + leave were the last writes
      expect(tr.log.last, [Kiss.fend, Kiss.cmdLeave, 0xFF, Kiss.fend]);
      expect(svc.iface, isNull);
    });

    test('a stored enabled setting reconnects on start', () async {
      await LoraStore(repo)
          .save(dev.copyWith(enabled: true, regulationsAcknowledged: true));
      await svc.start();
      expect(node.added, hasLength(1));
      await _until(() => svc.iface!.online);
      await svc.stop();
    });

    test('choosing another device reconnects', () async {
      await svc.update(
        dev.copyWith(enabled: true, regulationsAcknowledged: true),
      );
      final first = svc.iface!;
      await svc.update(
        svc.settings.copyWith(deviceId: 'COM9', deviceName: 'COM9'),
      );
      expect(node.removed, [first]);
      expect(node.added, hasLength(2));
      await svc.stop();
    });
  });

  test('transport badge: RNode traffic is lora, the rest tcp', () {
    final r = RNodeInterface(label: 'x', opener: () => throw StateError('x'));
    expect(NodeService.transportOf(r), 'lora');
    expect(NodeService.transportOf(null), 'tcp');
  });

  group('LoraScreen', () {
    Future<FakeLora> show(
      WidgetTester tester, {
      LoraSettings settings = const LoraSettings(),
      Set<LoraKind> kinds = const {LoraKind.usb},
      Locale locale = const Locale('uk'),
    }) async {
      tester.platformDispatcher.localeTestValue = locale;
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(840, 3000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      final fake = FakeLora(settings: settings, kinds: kinds);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [loraControllerProvider.overrideWithValue(fake)],
          child: const KestrelApp(home: LoraScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      return fake;
    }

    testWidgets(
      'shows the EU defaults, the source and the regulations warning',
      (tester) async {
        await show(tester);
        expect(find.text('LoRa радіо'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('lora-frequency')))
              .controller!
              .text,
          '867.2',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('lora-bandwidth')))
              .controller!
              .text,
          '125',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('lora-txpower')))
              .controller!
              .text,
          '7',
        );
        expect(find.text('SF8'), findsOneWidget);
        expect(find.text('4/5'), findsOneWidget);
        expect(find.byKey(const ValueKey('lora-warning')), findsOneWidget);
        expect(find.textContaining('Reticulum'), findsWidgets);
      },
    );

    testWidgets('invalid values are rejected and nothing is applied', (
      tester,
    ) async {
      final fake = await show(tester);
      await tester.enterText(
        find.byKey(const ValueKey('lora-frequency')),
        '50',
      );
      await tester.enterText(find.byKey(const ValueKey('lora-txpower')), '99');
      await tester.enterText(
        find.byKey(const ValueKey('lora-bandwidth')),
        'abc',
      );
      await tester.tap(find.byKey(const ValueKey('lora-apply')));
      await tester.pump();
      expect(find.text('Частота має бути від 137 до 3000 МГц'), findsOneWidget);
      expect(find.text('Потужність має бути від 0 до 37 дБм'), findsOneWidget);
      expect(find.text('Введіть число'), findsOneWidget);
      expect(fake.updates, isEmpty);
    });

    testWidgets('valid custom values are applied in Hz', (tester) async {
      final fake = await show(tester);
      await tester.enterText(
        find.byKey(const ValueKey('lora-frequency')),
        '868,3',
      );
      await tester.enterText(
        find.byKey(const ValueKey('lora-bandwidth')),
        '62.5',
      );
      await tester.enterText(find.byKey(const ValueKey('lora-txpower')), '14');
      await tester.tap(find.byKey(const ValueKey('lora-apply')));
      await tester.pump();
      final s = fake.updates.single;
      expect(s.frequency, 868300000);
      expect(s.bandwidth, 62500);
      expect(s.txPower, 14);
      expect(s.presetId, LoraPreset.custom);
    });

    testWidgets('choosing a preset fills the fields; editing makes it custom', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('lora-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Далі (SF10').last);
      await tester.pumpAndSettle();
      expect(find.text('SF10'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('lora-txpower')), '3');
      await tester.pump();
      expect(find.text('Свої значення'), findsOneWidget);
    });

    testWidgets('enabling asks for the regulations once, then stores it', (
      tester,
    ) async {
      final fake = await show(
        tester,
        settings: const LoraSettings(
          kind: LoraKind.usb,
          deviceId: 'COM7',
          deviceName: 'COM7',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('lora-enable')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lora-regs-dialog')), findsOneWidget);
      expect(fake.updates, isEmpty);
      await tester.tap(find.byKey(const ValueKey('lora-regs-accept')));
      await tester.pumpAndSettle();
      expect(fake.updates.single.enabled, isTrue);
      expect(fake.updates.single.regulationsAcknowledged, isTrue);
    });

    testWidgets('declining the regulations leaves the radio off', (
      tester,
    ) async {
      final fake = await show(
        tester,
        settings: const LoraSettings(
          kind: LoraKind.usb,
          deviceId: 'COM7',
          deviceName: 'COM7',
        ),
        locale: const Locale('en'),
      );
      await tester.tap(find.byKey(const ValueKey('lora-enable')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fake.updates, isEmpty);
    });

    testWidgets(
      'enabling without a device opens the picker and remembers the pick',
      (tester) async {
        final fake = await show(tester);
        await tester.tap(find.byKey(const ValueKey('lora-enable')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('lora-device-COM7')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('lora-device-COM7')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('lora-regs-accept')));
        await tester.pumpAndSettle();
        final s = fake.updates.single;
        expect(s.kind, LoraKind.usb);
        expect(s.deviceId, 'COM7');
        expect(s.enabled, isTrue);
      },
    );

    testWidgets('BLE picker lists scanned RNodes', (tester) async {
      final fake = await show(tester, kinds: const {LoraKind.ble});
      await tester.tap(find.text('Обрати RNode (Bluetooth)').first);
      await tester.pumpAndSettle();
      expect(find.text('RNode 1234'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lora-device-AA:BB')));
      await tester.pumpAndSettle();
      expect(fake.updates.single.kind, LoraKind.ble);
    });

    testWidgets(
      'status: connected device, firmware, RSSI/SNR, bitrate, airtime',
      (tester) async {
        final fake = await show(
          tester,
          settings: const LoraSettings(
            enabled: true,
            kind: LoraKind.usb,
            deviceId: 'COM7',
            deviceName: 'COM7',
            regulationsAcknowledged: true,
          ),
        );
        fake.setStatus(
          const RNodeStatus(
            state: InterfaceState.online,
            firmware: '1.82',
            platform: 'ESP32',
            rssi: -91,
            snr: -3.25,
            bitrate: 3125,
            airtimeShort: 1.5,
            airtimeLong: 0.2,
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('COM7 · Підключено'), findsOneWidget);
        expect(find.text('1.82'), findsOneWidget);
        expect(find.text('ESP32'), findsOneWidget);
        expect(find.text('RSSI -91 dBm · SNR -3.25 dB'), findsOneWidget);
        expect(find.text('3125 біт/с'), findsOneWidget);
        expect(find.textContaining('≈'), findsOneWidget);
      },
    );

    testWidgets('status: shows the error while not connected', (tester) async {
      final fake = await show(
        tester,
        settings: const LoraSettings(
          enabled: true,
          kind: LoraKind.usb,
          deviceId: 'COM7',
          deviceName: 'COM7',
          regulationsAcknowledged: true,
        ),
      );
      fake.setStatus(const RNodeStatus(error: 'could not detect an RNode'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('could not detect an RNode'), findsOneWidget);
      expect(find.text('COM7 · Не підключено'), findsOneWidget);
    });
  });

  testWidgets('Settings has its own LoRa entry', (tester) async {
    tester.view.physicalSize = const Size(840, 5000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fixtureOverrides(conn: NodeConnection.online, node: FakeNode()),
          loraControllerProvider.overrideWithValue(FakeLora()),
        ],
        child: const KestrelApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('lora-settings')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('lora-settings')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lora-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lora-apply')), findsOneWidget);
  });
}
