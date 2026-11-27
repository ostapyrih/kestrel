import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/bridge/vault_service.dart';
import 'package:kestrel/node/node_service.dart';
import 'package:kestrel/main.dart';
import 'package:kestrel/screens/add_device_screen.dart';
import 'package:kestrel/screens/chat_screen.dart';
import 'package:kestrel/screens/chats_screen.dart';
import 'package:kestrel/screens/devices_screen.dart';
import 'package:kestrel/screens/rooms_screen.dart';
import 'package:kestrel/screens/settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fixtures.dart';

void main() {
  late FakeBridge bridge;

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    BridgeStatus status = const BridgeStatus(BridgeState.connected),
    bool configured = true,
    bool? enabled,
    Stream<bool>? enabledStream,
    Size size = const Size(420, 1800),
  }) async {
    const locale = Locale('uk');
    tester.platformDispatcher.localeTestValue = locale;
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixtureOverrides(
          conn: NodeConnection.online,
          bridge: bridge,
          bridgeStatus: status,
          bridgeConfigured: configured,
          bridgeEnabled: enabled,
          bridgeEnabledStream: enabledStream,
        ),
        child: KestrelApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Text meta(WidgetTester t, int id) =>
      t.widget<Text>(find.byKey(ValueKey('meta-$id')));

  setUp(() => bridge = FakeBridge());

  group('A chat', () {
    testWidgets('message lines name the origin device and the route', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: 2));
      expect(find.byKey(const ValueKey('badge-A')), findsOneWidget);
      expect(find.text('Від: MeshChatX (через міст)'), findsOneWidget);
      // from this account via a known device: "A · from iPhone · direct"
      expect(meta(tester, 12).data, 'MeshChatX · від iPhone · direct · TCP');
      // typed in the MeshChatX web UI (origin_device null)
      expect(meta(tester, 13).data, 'MeshChatX · з MeshChatX · direct · TCP');
      // incoming messages carry no origin
      expect(meta(tester, 11).data, 'MeshChatX · direct · TCP');
      // not accepted by the bridge yet: via bridge
      expect(meta(tester, 14).data, contains('через міст'));
    });

    testWidgets('details show the sending device', (tester) async {
      await show(tester, const ChatScreen(chatId: 2));
      await tester.tap(find.text('З айфона'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('detail-origin')))
            .data,
        'iPhone',
      );
    });

    testWidgets('English strings', (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('en')];
      tester.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(840, 1720);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixtureOverrides(
            conn: NodeConnection.online,
            bridge: bridge,
            bridgeConfigured: true,
          ),
          child: const KestrelApp(home: ChatScreen(chatId: 2)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('From: MeshChatX (via bridge)'), findsOneWidget);
      expect(meta(tester, 12).data, 'MeshChatX · from iPhone · direct · TCP');
    });

    testWidgets(
      'queued while the bridge is unreachable: wait / cancel / send from B',
      (tester) async {
        await show(
          tester,
          const ChatScreen(chatId: 2),
          status: const BridgeStatus(BridgeState.unreachable),
        );
        expect(
          find.byKey(const ValueKey('bridge-unreachable-14')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('cancel-14')));
        await tester.tap(find.byKey(const ValueKey('send-b-14')));
        await tester.pump();
        expect(bridge.cancelled, [14]);
        expect(bridge.sentFromB, [14]); // an explicit tap, never automatic
        // "wait" just dismisses the prompt
        await tester.tap(find.byKey(const ValueKey('wait-14')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('bridge-unreachable-14')),
          findsNothing,
        );
      },
    );

    testWidgets('no prompt while the bridge is connected', (tester) async {
      await show(tester, const ChatScreen(chatId: 2));
      expect(find.byKey(const ValueKey('bridge-unreachable-14')), findsNothing);
    });

    testWidgets('B chats show no origin label', (tester) async {
      await show(tester, const ChatScreen(chatId: 1));
      expect(meta(tester, 2).data, 'direct · TCP');
    });
  });

  group('chat list', () {
    testWidgets('A chip enabled with a key, indicator shows the state', (
      tester,
    ) async {
      await show(tester, const ChatsScreen());
      final a = tester.widget<ChoiceChip>(find.byKey(const ValueKey('chip-A')));
      expect(a.onSelected, isNotNull);
      expect(find.text('Міст: онлайн'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-rooms')), findsOneWidget);
    });

    testWidgets('revoked: says so and keeps the chats', (tester) async {
      await show(
        tester,
        const ChatsScreen(),
        status: const BridgeStatus(BridgeState.revoked),
      );
      expect(find.text('Міст: пристрій відкликано'), findsOneWidget);
      expect(find.byKey(const ValueKey('bridge-help')), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('protocol mismatch is shown clearly', (tester) async {
      await show(
        tester,
        const ChatsScreen(),
        status: const BridgeStatus(
          BridgeState.mismatch,
          mismatch: {
            'server_version': 3,
            'min_version': 3,
            'max_version': 4,
            'client_version': 2,
          },
        ),
      );
      expect(find.text('Міст: несумісна версія'), findsOneWidget);
      expect(find.textContaining('сервер 3'), findsOneWidget);
    });

    testWidgets('two-pane layout still works with the bridge on', (
      tester,
    ) async {
      await show(tester, const ChatsScreen(), size: const Size(1200, 800));
      await tester.tap(find.text('Marichka'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatsScreen), findsOneWidget);
      expect(find.text('З айфона'), findsOneWidget);
    });
  });

  group('devices screen', () {
    testWidgets('lists name, platform, online, roles and revoked', (
      tester,
    ) async {
      await show(tester, const DevicesScreen());
      expect(find.text('iPhone'), findsOneWidget);
      expect(find.text('Old laptop'), findsOneWidget);
      expect(find.byKey(ValueKey('online-${'d1' * 16}')), findsOneWidget);
      expect(find.byKey(ValueKey('revoked-${'d2' * 16}')), findsOneWidget);
      expect(find.text('польовий'), findsOneWidget); // field role of the laptop
      expect(find.text('ios'), findsOneWidget);
      // a revoked device has no actions
      expect(find.byKey(ValueKey('menu-${'d2' * 16}')), findsNothing);
    });

    testWidgets('revoke asks for confirmation first', (tester) async {
      await show(tester, const DevicesScreen());
      await tester.tap(find.byKey(ValueKey('menu-${'d1' * 16}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Відкликати'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('revoke-dialog')), findsOneWidget);
      expect(find.textContaining('«iPhone»'), findsOneWidget);
      await tester.tap(find.text('Скасувати'));
      await tester.pumpAndSettle();
      expect(bridge.revoked, isEmpty);
      // again, confirmed
      await tester.tap(find.byKey(ValueKey('menu-${'d1' * 16}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Відкликати'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('revoke-confirm')));
      await tester.pumpAndSettle();
      expect(bridge.revoked, ['d1' * 16]);
    });

    testWidgets('rename and the field role toggle', (tester) async {
      await show(tester, const DevicesScreen());
      await tester.tap(find.byKey(ValueKey('menu-${'d1' * 16}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Перейменувати'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('rename-input')), 'Pad');
      await tester.tap(find.byKey(const ValueKey('rename-ok')));
      await tester.pumpAndSettle();
      expect(bridge.renamed, ['${'d1' * 16}=Pad']);
      await tester.tap(find.byKey(ValueKey('menu-${'d1' * 16}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Польовий пристрій (LXMF-пуш)'));
      await tester.pumpAndSettle();
      expect(bridge.roles, [('d1' * 16, true)]);
    });
  });

  group('bridge off: a plain single-identity messenger', () {
    testWidgets('no account chips, badges, labels or bridge screens', (
      tester,
    ) async {
      await show(tester, const ChatsScreen(), enabled: false);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Marichka'), findsNothing); // account A is hidden
      for (final k in ['chip-A', 'chip-B', 'chip-all', 'open-rooms']) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
      expect(find.byKey(const ValueKey('badge-A')), findsNothing);
      expect(find.byKey(const ValueKey('badge-B')), findsNothing);
      expect(find.textContaining('MeshChatX'), findsNothing);
      expect(find.textContaining('B ·'), findsNothing);
    });

    testWidgets('chat: no badge, no From line, the line is route · transport', (
      tester,
    ) async {
      await show(tester, const ChatScreen(chatId: 1), enabled: false);
      expect(find.byKey(const ValueKey('badge-B')), findsNothing);
      expect(find.byKey(const ValueKey('composer-from')), findsNothing);
      expect(meta(tester, 1).data, 'opportunistic · TCP');
      expect(meta(tester, 2).data, 'direct · TCP');
      // the details sheet has no sender-account row either
      await tester.tap(find.text('Вітаю, як справи?'));
      await tester.pumpAndSettle();
      expect(find.text('Деталі повідомлення'), findsOneWidget);
      expect(find.text('Відправник'), findsNothing);
    });

    testWidgets('settings: your address / your public key, no devices', (
      tester,
    ) async {
      await show(tester, const SettingsScreen(), enabled: false);
      await tester.pump();
      expect(find.text('Ваша адреса'), findsOneWidget);
      expect(find.text('Ваш публічний ключ'), findsOneWidget);
      expect(find.textContaining('Ідентичність B'), findsNothing);
      expect(find.textContaining('(цей пристрій)'), findsNothing);
      expect(find.byKey(const ValueKey('bridge-switch')), findsOneWidget);
      expect(find.byKey(const ValueKey('bridge-setup')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-devices')), findsNothing);
      expect(find.byKey(const ValueKey('add-device-tile')), findsNothing);
      expect(find.byKey(const ValueKey('fallback-switch')), findsNothing);
    });

    testWidgets('the dual-identity UI and account A come back when it is on', (
      tester,
    ) async {
      final mode = StreamController<bool>();
      addTearDown(mode.close);
      await show(tester, const ChatsScreen(), enabledStream: mode.stream);
      mode.add(false);
      await tester.pump();
      await tester.pump();
      expect(find.text('Marichka'), findsNothing);
      expect(find.byKey(const ValueKey('chip-A')), findsNothing);
      mode.add(true);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Marichka'), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('chip-B')), findsOneWidget);
      expect(find.byKey(const ValueKey('badge-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-rooms')), findsOneWidget);
    });

    testWidgets('bridge on keeps the labels', (tester) async {
      await show(tester, const ChatScreen(chatId: 1), enabled: true);
      expect(find.byKey(const ValueKey('composer-from')), findsOneWidget);
      expect(meta(tester, 1).data, 'opportunistic · TCP');
    });
  });

  group('turning the bridge off asks first', () {
    Future<void> open(WidgetTester tester, {required int queued}) async {
      bridge.queuedUnsent = queued;
      await show(tester, const SettingsScreen(), enabled: true);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bridge-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bridge-off-dialog')), findsOneWidget);
      expect(
        find.textContaining('прибере чати облікового запису A'),
        findsOneWidget,
      );
    }

    testWidgets('no queued messages: Cancel or Turn off', (tester) async {
      await open(tester, queued: 0);
      expect(find.byKey(const ValueKey('bridge-off-queued')), findsNothing);
      expect(find.byKey(const ValueKey('bridge-off-send-b')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bridge-off-cancel')));
      await tester.pumpAndSettle();
      expect(bridge.turnedOff, isEmpty);
      await tester.tap(find.byKey(const ValueKey('bridge-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bridge-off-confirm')));
      await tester.pumpAndSettle();
      expect(bridge.turnedOff, ['discard']);
    });

    testWidgets('queued messages: warned, Cancel keeps everything', (
      tester,
    ) async {
      await open(tester, queued: 2);
      expect(
        find.textContaining('Повідомлень, які треба надіслати як A, ще не'),
        findsOneWidget,
      );
      // Cancel has the focus
      final cancel = tester.widget<TextButton>(
        find.byKey(const ValueKey('bridge-off-cancel')),
      );
      expect(cancel.autofocus, isTrue);
      await tester.tap(find.byKey(const ValueKey('bridge-off-cancel')));
      await tester.pumpAndSettle();
      expect(bridge.turnedOff, isEmpty);
      expect(find.byKey(const ValueKey('bridge-off-dialog')), findsNothing);
    });

    testWidgets('queued messages: send them from this device (B) instead', (
      tester,
    ) async {
      await open(tester, queued: 3);
      await tester.tap(find.byKey(const ValueKey('bridge-off-send-b')));
      await tester.pumpAndSettle();
      expect(bridge.turnedOff, ['send-from-b']);
    });

    testWidgets('queued messages: discard and turn off', (tester) async {
      await open(tester, queued: 1);
      await tester.tap(find.byKey(const ValueKey('bridge-off-confirm')));
      await tester.pumpAndSettle();
      expect(bridge.turnedOff, ['discard']);
    });
  });

  group('invite pairing', () {
    testWidgets(
      'a trusted device shows the invite QR first, with a countdown',
      (tester) async {
        await show(tester, const AddDeviceScreen());
        await tester.pump();
        expect(find.byKey(const ValueKey('invite-qr')), findsOneWidget);
        expect(
          tester
              .widget<SelectableText>(find.byKey(const ValueKey('invite-text')))
              .data,
          startsWith('kestrel-invite:v1:'),
        );
        expect(find.byKey(const ValueKey('invite-countdown')), findsOneWidget);
        expect(
          find.textContaining(RegExp(r'Дійсний ще \d+:\d\d')),
          findsOneWidget,
        );
        // the older flows are behind "Other options"
        expect(find.byKey(const ValueKey('pair-input')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('other-options')));
        await tester.pump();
        expect(find.byKey(const ValueKey('pair-input')), findsOneWidget);
      },
    );

    testWidgets('an expired invite is replaced on demand', (tester) async {
      bridge.inviteTtl = const Duration(seconds: 1);
      await show(tester, const AddDeviceScreen());
      await tester.pump();
      expect(bridge.invitesCreated, 1);
      expect(find.byKey(const ValueKey('invite-qr')), findsOneWidget);
      // real time passes (the countdown reads the wall clock)
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1300)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('invite-expired')), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-qr')), findsNothing);
      bridge.inviteTtl = const Duration(minutes: 10);
      await tester.tap(find.byKey(const ValueKey('invite-new')));
      await tester.pump();
      await tester.pump();
      expect(bridge.invitesCreated, 2);
      expect(find.byKey(const ValueKey('invite-qr')), findsOneWidget);
    });

    testWidgets('vault in use: message and the other options open', (
      tester,
    ) async {
      bridge.inviteError = BridgeError('vault_in_use');
      await show(tester, const AddDeviceScreen());
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Запрошення недоступні'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-input')), findsOneWidget);
    });
  });

  group('add a device', () {
    PairingPayload payload() => PairingPayload(
      pubkey: Uint8List.fromList(List.filled(64, 5)),
      name: 'Tablet',
      platform: 'android',
      nonce: Uint8List.fromList(List.filled(16, 1)),
      ts: 1700000000,
    );

    testWidgets(
      'trusted device: paste, confirm name/platform/fingerprint, approve',
      (tester) async {
        await show(tester, const AddDeviceScreen());
        await tester.tap(find.byKey(const ValueKey('other-options')));
        await tester.pump();
        final p = payload();
        await tester.enterText(
          find.byKey(const ValueKey('pair-input')),
          encodePairingQr(p),
        );
        await tester.tap(find.byKey(const ValueKey('pair-next')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pair-confirm')), findsOneWidget);
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('confirm-name')),
              )
              .data,
          'Tablet',
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('confirm-platform')),
              )
              .data,
          'android',
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('confirm-fingerprint')),
              )
              .data,
          p.fingerprint,
        );
        await tester.tap(find.byKey(const ValueKey('confirm-field')));
        await tester.tap(find.byKey(const ValueKey('confirm-approve')));
        await tester.pumpAndSettle();
        expect(bridge.approved, ['Tablet:true']);
      },
    );

    testWidgets('garbage and expired codes show clear errors', (tester) async {
      await show(tester, const AddDeviceScreen());
      await tester.tap(find.byKey(const ValueKey('other-options')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('pair-input')), 'hello');
      await tester.tap(find.byKey(const ValueKey('pair-next')));
      await tester.pump();
      expect(find.text('Це не код пристрою Kestrel'), findsOneWidget);

      bridge.approveError = BridgeError('pairing_expired');
      await tester.enterText(
        find.byKey(const ValueKey('pair-input')),
        encodePairingQr(payload()),
      );
      await tester.tap(find.byKey(const ValueKey('pair-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-approve')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Код застарів'), findsOneWidget);
    });

    testWidgets('vault in use: a clear message instead of the action', (
      tester,
    ) async {
      await show(tester, const AddDeviceScreen());
      await tester.tap(find.byKey(const ValueKey('other-options')));
      await tester.pump();
      bridge.approveError = VaultKeyMissing();
      await tester.enterText(
        find.byKey(const ValueKey('pair-input')),
        encodePairingQr(payload()),
      );
      await tester.tap(find.byKey(const ValueKey('pair-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-approve')));
      await tester.pumpAndSettle();
      expect(find.textContaining('не має ключа сховища'), findsOneWidget);
    });

    testWidgets('new device: QR and copyable text, waiting for approval', (
      tester,
    ) async {
      await show(
        tester,
        const AddDeviceScreen(),
        status: const BridgeStatus(BridgeState.awaitingApproval),
      );
      await tester.tap(find.byKey(const ValueKey('other-options')));
      await tester.pump();
      await tester.tap(find.text('Це новий пристрій'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pair-qr')), findsOneWidget);
      final text = tester
          .widget<SelectableText>(find.byKey(const ValueKey('pair-text')))
          .data!;
      expect(text, startsWith('kestrel-pair:v1:'));
      expect(decodePairingQr(text).payload.name, 'New phone');
      expect(find.byKey(const ValueKey('pair-waiting')), findsOneWidget);
    });

    testWidgets('new device: shows done once connected', (tester) async {
      await show(tester, const AddDeviceScreen());
      await tester.tap(find.byKey(const ValueKey('other-options')));
      await tester.pump();
      await tester.tap(find.text('Це новий пристрій'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-done')), findsOneWidget);
    });
  });

  group('RRC', () {
    testWidgets('rooms list and the room view under account A', (tester) async {
      await show(tester, const RoomsScreen());
      expect(find.text('general'), findsOneWidget);
      expect(find.text('ops'), findsOneWidget);
      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('badge-A')), findsOneWidget);
      expect(find.textContaining('hello room'), findsOneWidget);
    });

    testWidgets('a message starting with / is blocked with an explanation', (
      tester,
    ) async {
      await show(tester, const RoomScreen(hub: 'ee', room: 'general'));
      await tester.enterText(
        find.byKey(const ValueKey('room-input')),
        '/join #x',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('room-blocked')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('room-send')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('room-input')),
        'hi all',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-send')));
      await tester.pump();
      expect(bridge.rrcSent, ['hi all']);
    });
  });
}
