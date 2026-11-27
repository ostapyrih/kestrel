import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/bridge/bridge_connection.dart';
import 'package:kestrel/update/installer.dart';
import 'package:kestrel/update/update_outcome.dart';
import 'package:kestrel/update/update_service.dart';
import 'package:kestrel/update/windows_launch.dart';
import 'package:kestrel/update/releases.dart';
import 'package:kestrel/update/version.dart';

AppVersion _v(String s) => AppVersion.tryParse(s)!;

PendingUpdate _pending({String target = '0.8.1', DateTime? at}) =>
    PendingUpdate(
      from: '0.8.0',
      target: target,
      installerPath: 'C:/t/kestrel-setup.exe',
      logPath: 'C:/t/kestrel-update.log',
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
        log: const InstallerLogInfo(exists: true, exitCode: 5),
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
      expect(p.logPath, endsWith('kestrel-update.log'));
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

    test(
      'a failed install shows up once, with the installer exit code',
      () async {
        final log = File('${dir.path}/kestrel-update.log')
          ..writeAsStringSync(
            '2026-01-01 00:00:01.000   Starting\n'
            '2026-01-01 00:00:02.000   Setup exit code: 1603\n',
          );
        await writePendingUpdate(
          dir,
          PendingUpdate(
            from: '0.8.0',
            target: '0.8.1',
            installerPath: 'x',
            logPath: log.path,
            startedAt: DateTime.now(),
          ),
        );
        final s = service('0.8.0');
        final o = await s.checkPreviousInstall();
        expect(o.failed, isTrue);
        expect(o.exitCode, 1603);
        expect(s.state.failure, isNotNull);
        // the marker is consumed: the next start reports nothing
        expect(
          (await service('0.8.0').checkPreviousInstall()).kind,
          UpdateOutcomeKind.none,
        );
        s.dismissFailure();
        expect(s.state.failure, isNull);
      },
    );

    test('a successful install only clears the marker', () async {
      await writePendingUpdate(dir, _pending(at: DateTime.now()));
      final s = service('0.8.1');
      expect(
        (await s.checkPreviousInstall()).kind,
        UpdateOutcomeKind.succeeded,
      );
      expect(s.state.failure, isNull);
      expect(pendingUpdateFile(dir).existsSync(), isFalse);
    });
  });

  group('windows installer launch', () {
    const dir = r'C:\Users\Jane Doe\AppData\Local\Temp\kestrel-update1';

    test('command line is quoted and has every silent flag', () {
      final c = windowsInstallerCommandLine(
        '$dir\\setup.exe',
        '$dir\\kestrel-update.log',
      );
      expect(c, startsWith('"$dir\\setup.exe" '));
      for (final f in [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/FORCECLOSEAPPLICATIONS',
      ]) {
        expect(c, contains(' $f'));
      }
      expect(c, endsWith('/LOG="$dir\\kestrel-update.log"'));
    });

    test('launches the installer directly, then exits', () async {
      String? launched;
      var exited = false;
      final i = WindowsInstaller(
        launch: (c) => launched = c,
        exitDelay: Duration.zero,
      );
      await i.install(File(r'C:\t x\setup.exe'), exitApp: () => exited = true);
      expect(launched, startsWith(r'"C:\t x\setup.exe" /VERYSILENT'));
      expect(launched, isNot(contains('powershell')));
      expect(exited, isTrue);
    });

    test('a launch failure is an InstallException and the app stays', () async {
      var exited = false;
      final i = WindowsInstaller(
        launch: (_) => throw LaunchException('denied'),
        exitDelay: Duration.zero,
      );
      await expectLater(
        i.install(File('setup.exe'), exitApp: () => exited = true),
        throwsA(isA<InstallException>()),
      );
      expect(exited, isFalse);
    });
  });

  group('inno log parsing', () {
    test('takes the exit code and the last error line', () {
      final i = parseInstallerLog(
        '2026-01-01 10:00:00.123   Starting\r\n'
        '2026-01-01 10:00:01.000   Failed to replace kestrel.exe: access denied\r\n'
        '2026-01-01 10:00:02.000   Setup exit code: 5\r\n',
      );
      expect(i.exists, isTrue);
      expect(i.exitCode, 5);
      expect(i.reason, 'Failed to replace kestrel.exe: access denied');
    });

    test('no code and no error: nothing is invented', () {
      final i = parseInstallerLog('2026-01-01 10:00:00.123   Log opened.\n');
      expect(i.exitCode, isNull);
      expect(i.reason, isNull);
    });

    test('a missing log means the installer never started', () async {
      final d = Directory.systemTemp.createTempSync('klog');
      addTearDown(() => d.deleteSync(recursive: true));
      final u = _pending();
      final info = await readInstallerLog(
        PendingUpdate(
          from: u.from,
          target: u.target,
          installerPath: u.installerPath,
          logPath: '${d.path}/none.log',
          startedAt: u.startedAt,
        ),
      );
      expect(info.exists, isFalse);
      expect(info.exitCode, isNull);
    });

    test('success removes the per-update temp directory only', () async {
      final d = Directory.systemTemp.createTempSync('kestrel-update');
      File('${d.path}/setup.exe').writeAsStringSync('x');
      await deleteUpdateDir(
        PendingUpdate(
          from: '0.8.0',
          target: '0.8.1',
          installerPath: '${d.path}/setup.exe',
          logPath: '${d.path}/kestrel-update.log',
          startedAt: DateTime.now(),
        ),
      );
      expect(d.existsSync(), isFalse);
      final other = Directory.systemTemp.createTempSync('unrelated');
      addTearDown(() => other.deleteSync(recursive: true));
      await deleteUpdateDir(
        PendingUpdate(
          from: '',
          target: '0.8.1',
          installerPath: '${other.path}/setup.exe',
          logPath: '',
          startedAt: DateTime.now(),
        ),
      );
      expect(other.existsSync(), isTrue);
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
