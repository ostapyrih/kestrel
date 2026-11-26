import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/bridge/bridge_service.dart';
import 'package:kestrel/bridge/codec.dart';
import 'package:kestrel/l10n/strings.dart';
import 'package:kestrel/screens/bridge_widgets.dart';
import 'package:kestrel/storage/database.dart';
import 'package:kestrel/storage/repo.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_bridge_api.dart';

HelloResult hello(Map<String, Object?> compat) {
  final m = {
    'protocol_version': 2,
    'min_protocol_version': 2,
    'max_protocol_version': 2,
    'server': 'x',
    'time': 1.0,
    'state_id': 's',
    'cursor': 0,
    'device': deviceMap('0a' * 16),
    'capabilities': <String>[],
    'compat': compat,
    'vault': {'key_epoch': 1, 'in_use': false},
    'limits': {},
  };
  return HelloResult.fromMap(m);
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('compat.checked: unchecked is "starting", not incompatible', () {
    final starting = hello({
      'ok': false,
      'checked': false,
      'error': 'MeshChatX not reachable',
      'meshchatx_version': null,
    });
    expect(starting.compatChecked, isFalse);
    expect(starting.upstreamIncompatible, isFalse);
    expect(starting.compatError, 'MeshChatX not reachable');
    final bad = hello({
      'ok': false,
      'checked': true,
      'meshchatx_version': '5.0',
    });
    expect(bad.upstreamIncompatible, isTrue);
    final good = hello({'ok': true, 'checked': true});
    expect(good.upstreamIncompatible, isFalse);
  });

  test('older bridges without the new fields keep working', () {
    final oldOk = hello({'ok': true, 'meshchatx_version': '4.12.0'});
    expect((oldOk.compatChecked, oldOk.upstreamIncompatible), (true, false));
    final oldBad = hello({'ok': false});
    expect(oldBad.upstreamIncompatible, isTrue);
    expect(hello({}).upstreamIncompatible, isFalse);
  });

  test('UI texts for the reject reasons', () {
    final s = Strings('en');
    const waiting = BridgeStatus(
      BridgeState.awaitingApproval,
      detail: 'unauthorized',
    );
    expect(bridgeStateText(s, waiting), 'Bridge: waiting for approval');
    expect(bridgeStateHelp(s, waiting), contains('not approved yet'));
    const rejected = BridgeStatus(BridgeState.rejected, detail: 'unauthorized');
    expect(bridgeStateText(s, rejected), 'Bridge: device not accepted');
    expect(
      bridgeStateText(s, const BridgeStatus(BridgeState.revoked)),
      isNot(bridgeStateText(s, rejected)),
    );
  });

  test('UI help distinguishes starting from incompatible', () {
    final s = Strings('en');
    final starting = BridgeStatus(
      BridgeState.connected,
      hello: hello({'ok': false, 'checked': false}),
    );
    expect(bridgeStateHelp(s, starting), contains('starting'));
    final bad = BridgeStatus(
      BridgeState.connected,
      hello: hello({'ok': false, 'checked': true, 'meshchatx_version': '5.0'}),
    );
    expect(bridgeStateHelp(s, bad), contains('5.0'));
    final fine = BridgeStatus(
      BridgeState.connected,
      hello: hello({'ok': true, 'checked': true}),
    );
    expect(bridgeStateHelp(s, fine), isNull);
  });

  test(
    'upstream_unavailable shows the state and is retried after retry_after',
    () async {
      final adb = await AppDatabase.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final repo = Repo(adb);
      final api = FakeBridgeApi();
      final id = await Identity.generate();
      final svc = BridgeService(
        repo: repo,
        ownDeviceId: () => '0a' * 16,
        identity: () => id,
        apiFactory: (_, _) => api,
        sendAsB: (_, _) async => 0,
      );
      var syncs = 0;
      api.handlers['/sync_chats'] = (a) {
        if (++syncs == 1) {
          throw BridgeError('upstream_unavailable', 'starting', {
            'retry_after': 0.05,
          });
        }
        return {
          'state_id': 's',
          'cursor': 1,
          'reset': false,
          'more': false,
          'lxmf': [],
          'rrc': [],
        };
      };
      api.handlers['/devices/list'] = (a) => {'devices': []};
      api.handlers['/list_rooms'] = (a) => {'hubs': []};
      await svc.configure('ab' * 64);
      api.connect(helloFor('0a' * 16));
      await svc.flushEvents();
      expect(svc.status.detail, 'upstream_unavailable');
      expect(svc.status.state, BridgeState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await svc.flushEvents();
      expect(syncs, 2);
      expect(svc.status.detail, isNull);
      expect(await svc.store.cursor(), 1);
      await svc.stop();
      await adb.close();
    },
  );
}
