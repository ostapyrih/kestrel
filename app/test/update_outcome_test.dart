import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/update/installer.dart';
import 'package:kestrel/update/update_outcome.dart';
import 'package:kestrel/update/update_service.dart';
import 'package:kestrel/update/releases.dart';
import 'package:kestrel/update/version.dart';

AppVersion _v(String s) => AppVersion.tryParse(s)!;

PendingUpdate _pending({String target = '0.8.1', DateTime? at}) => PendingUpdate(
  from: '0.8.0',
  target: target,
  installerPath: 'C:/t/kestrel-setup.exe',
  logPath: 'C:/t/kestrel-update.log',
  resultPath: 'C:/t/kestrel-update-result.txt',
  startedAt: at ?? DateTime(2026, 1, 1),
);

void main() {
  final now = DateTime(2026, 1, 1, 0, 5);

  group('update outcome decision', () {
    test('no marker: nothing to report', () {
      final o = evaluateUpdateOutcome(
        pending: null,
        running: _v('0.8.0'),
        now: now,
      );
      expect(o.kind, UpdateOutcomeKind.none);
    });

    test('the target version runs: success', () {
      final o = evaluateUpdateOutcome(
        pending: _pending(),
        running: _v('0.8.1'),
        now: now,
      );
      expect(o.kind, UpdateOutcomeKind.succeeded);
    });

    test('the old version came back: failed, with the exit code', () {
      final o = evaluateUpdateOutcome(
        pending: _pending(),
        running: _v('0.8.0'),
        now: now,
        exitCode: 5,
      );
      expect(o.failed, isTrue);
      expect(o.exitCode, 5);
      expect(o.pending!.logPath, endsWith('kestrel-update.log'));
    });

    test('an old marker or a garbage target is ignored', () {
      expect(
        evaluateUpdateOutcome(
          pending: _pending(at: DateTime(2025, 1, 1)),
          running: _v('0.8.0'),
          now: now,
        ).kind,
        UpdateOutcomeKind.none,
      );
      expect(
        evaluateUpdateOutcome(
          pending: _pending(target: 'junk'),
          running: _v('0.8.0'),
          now: now,
        ).kind,
        UpdateOutcomeKind.none,
      );
    });

    test('marker round trip', () {
      final p = PendingUpdate.fromJson(_pending().toJson());
      expect(p.target, '0.8.1');
      expect(p.resultPath, endsWith('kestrel-update-result.txt'));
    });
  });

  group('update service after a restart', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('kupd'));
    tearDown(() => dir.deleteSync(recursive: true));

    UpdateService service(String version) => UpdateService(
      currentVersion: _v(version),
      platform: UpdatePlatform.windows,
      tempDir: dir,
    );

    test('a failed install shows up once, with the installer exit code',
        () async {
      final result = File('${dir.path}/res.txt')..writeAsStringSync('1603\n');
      await writePendingUpdate(
        dir,
        PendingUpdate(
          from: '0.8.0',
          target: '0.8.1',
          installerPath: 'x',
          logPath: '${dir.path}/kestrel-update.log',
          resultPath: result.path,
          startedAt: DateTime.now(),
        ),
      );
      final s = service('0.8.0');
      final o = await s.checkPreviousInstall();
      expect(o.failed, isTrue);
      expect(o.exitCode, 1603);
      expect(s.state.failure, isNotNull);
      // the marker is consumed: the next start reports nothing
      expect((await service('0.8.0').checkPreviousInstall()).kind,
          UpdateOutcomeKind.none);
      s.dismissFailure();
      expect(s.state.failure, isNull);
    });

    test('a successful install only clears the marker', () async {
      await writePendingUpdate(dir, _pending(at: DateTime.now()));
      final s = service('0.8.1');
      expect((await s.checkPreviousInstall()).kind,
          UpdateOutcomeKind.succeeded);
      expect(s.state.failure, isNull);
      expect(pendingUpdateFile(dir).existsSync(), isFalse);
    });
  });

  group('windows update script', () {
    test('waits long, stops a stuck app, closes apps, logs, records the exit '
        'code', () {
      const s = WindowsInstaller.script;
      expect(s, contains('Wait-Process -Id \$AppPid -Timeout 180'));
      expect(s, contains('Stop-Process -Id \$AppPid -Force'));
      expect(s, contains('/CLOSEAPPLICATIONS'));
      expect(s, contains('/FORCECLOSEAPPLICATIONS'));
      expect(s, contains('/LOG='));
      expect(s, contains('Set-Content -Path \$Result'));
      expect(s, contains('ExitCode'));
    });
  });

  group('bridge connection', () {
    test('subscribes to the vault topic; delete never goes over LXMF', () {
      expect(bridgeSubscribeTopics, containsAll(['lxmf', 'rrc', 'vault']));
      expect(BridgeConnection.lxmfAllowed('/delete_chat'), isFalse);
      expect(BridgeConnection.lxmfAllowed('/send_lxmf'), isTrue);
    });
  });
}
