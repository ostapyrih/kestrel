import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/update/installer.dart';
import 'package:kestrel/update/release_key.dart';
import 'package:kestrel/update/releases.dart';
import 'package:kestrel/update/update_service.dart';
import 'package:kestrel/update/verify.dart';
import 'package:kestrel/update/version.dart';

const _base = 'https://github.com/ostapyrih/kestrel/releases/download';

Map<String, Object?> _rel(
  String tag, {
  bool draft = false,
  bool pre = false,
  String body = '',
  List<String> assets = const [],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': pre,
  'body': body,
  'html_url': 'https://github.com/ostapyrih/kestrel/releases/tag/$tag',
  'assets': [
    for (final a in assets)
      {'name': a, 'browser_download_url': '$_base/$tag/$a', 'size': 10},
  ],
};

AppVersion _v(String s) => AppVersion.tryParse(s)!;

void main() {
  group('version comparison', () {
    test('parses tags, build suffixes and prereleases', () {
      expect(_v('app-v0.5.0').toString(), '0.5.0');
      expect(_v('0.5.0+5').toString(), '0.5.0');
      expect(_v('v1.2.3-rc.1').toString(), '1.2.3-rc.1');
      expect(AppVersion.tryParse('bridge-v0.4.1'), isNull);
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
    });

    test('orders numerically, not lexically', () {
      expect(_v('0.10.0') > _v('0.9.9'), isTrue);
      expect(_v('1.0.0') > _v('0.99.99'), isTrue);
      expect(_v('0.5.1') > _v('0.5.0'), isTrue);
      expect(_v('0.5.0') > _v('0.5.0'), isFalse);
      expect(_v('0.5.0+9') == _v('0.5.0+1'), isTrue);
    });

    test('a release is newer than its prerelease', () {
      expect(_v('1.0.0') > _v('1.0.0-rc.1'), isTrue);
      expect(_v('1.0.0-rc.2') > _v('1.0.0-rc.1'), isTrue);
      expect(_v('1.0.0-rc.10') > _v('1.0.0-rc.2'), isTrue);
      expect(_v('1.0.0-beta') > _v('1.0.0-alpha'), isTrue);
    });
  });

  group('release filtering', () {
    final json = [
      _rel('bridge-v9.9.9'),
      _rel('app-v0.9.0', draft: true),
      _rel('app-v0.8.0', pre: true),
      _rel('app-v0.6.0'),
      _rel('app-v0.7.0'),
      _rel('app-v0.4.0'),
      _rel('app-vgarbage'),
      _rel('v1.0.0'),
    ];

    test('keeps only published app-v* releases', () {
      final tags = parseAppReleases(json).map((r) => r.tag).toList();
      expect(tags, ['app-v0.6.0', 'app-v0.7.0', 'app-v0.4.0']);
    });

    test('picks the newest above the current version', () {
      final rs = parseAppReleases(json);
      expect(newestUpdate(rs, _v('0.5.0'))!.tag, 'app-v0.7.0');
      expect(newestUpdate(rs, _v('0.7.0')), isNull);
      expect(newestUpdate(rs, _v('1.0.0')), isNull);
    });

    test('tolerates malformed payloads', () {
      expect(parseAppReleases(null), isEmpty);
      expect(parseAppReleases({'message': 'rate limited'}), isEmpty);
      expect(parseAppReleases([1, 'x', null]), isEmpty);
    });

    test('drops assets outside the repository release downloads', () {
      final r = parseAppReleases([
        {
          ..._rel('app-v1.0.0'),
          'assets': [
            {'name': 'a', 'browser_download_url': 'https://evil.example/a'},
            {
              'name': 'b',
              'browser_download_url':
                  'http://github.com/ostapyrih/kestrel/releases/download/x/b',
            },
            {'name': 'c', 'browser_download_url': '$_base/app-v1.0.0/c'},
          ],
        },
      ]).single;
      expect(r.assets.map((a) => a.name), ['c']);
    });
  });

  group('asset selection', () {
    final release = parseAppReleases([
      _rel(
        'app-v0.6.0',
        assets: [
          'kestrel-0.6.0-arm64-v8a.apk',
          'kestrel-0.6.0-unsigned.ipa',
          'kestrel-0.6.0-windows-x64.zip',
          'kestrel-0.6.0-windows-x64-setup.exe',
          'kestrel-0.6.0-macos.dmg',
          'kestrel-0.6.0-linux-x64.tar.gz',
          'kestrel-0.6.0-linux-x86_64.AppImage',
          'SHA256SUMS.txt',
          'SHA256SUMS.txt.sig',
        ],
      ),
    ]).single;

    test('per platform', () {
      String? pick(UpdatePlatform p, {bool appImage = false}) =>
          selectAsset(release, p, linuxAppImage: appImage)?.name;
      expect(
        pick(UpdatePlatform.windows),
        'kestrel-0.6.0-windows-x64-setup.exe',
      );
      expect(pick(UpdatePlatform.macos), 'kestrel-0.6.0-macos.dmg');
      expect(
        pick(UpdatePlatform.linux, appImage: true),
        'kestrel-0.6.0-linux-x86_64.AppImage',
      );
      expect(pick(UpdatePlatform.linux), isNull);
      expect(pick(UpdatePlatform.android), isNull);
      expect(pick(UpdatePlatform.ios), isNull);
    });

    test('missing installer asset gives null', () {
      final r = parseAppReleases([
        _rel('app-v0.6.0', assets: ['kestrel-0.6.0-windows-x64.zip']),
      ]).single;
      expect(selectAsset(r, UpdatePlatform.windows), isNull);
    });
  });

  group('changelog text', () {
    test('strips markdown and the install boilerplate', () {
      const body =
          '## [0.6.0](https://x/y) (2026-01-01)\n\n### Features\n\n* **app:** a [thing](https://z)\n\n### Desktop install\n\n- junk';
      final t = plainChangelog(body);
      expect(t, contains('0.6.0'));
      expect(t, contains('- app: a thing'));
      expect(t, isNot(contains('junk')));
      expect(t, isNot(contains('**')));
      expect(t, isNot(contains('https://')));
    });
  });

  group('verification', () {
    late cg.SimpleKeyPair key;
    late String pubB64;
    final sumsText =
        '${crypto.sha256.convert(utf8.encode('payload'))}  kestrel-1.0.0-setup.exe\n';
    final sums = utf8.encode(sumsText);

    Future<String> sign(List<int> data, cg.SimpleKeyPair k) async =>
        base64.encode((await cg.Ed25519().sign(data, keyPair: k)).bytes);

    setUp(() async {
      key = await cg.Ed25519().newKeyPair();
      pubB64 = base64.encode((await key.extractPublicKey()).bytes);
    });

    test('embedded public key is a valid raw Ed25519 key', () {
      expect(base64.decode(releasePublicKeyB64), hasLength(32));
    });

    test('good signature passes', () async {
      await verifySumsSignature(
        sums,
        await sign(sums, key),
        publicKeyB64: pubB64,
      );
    });

    Future<VerifyFailure?> failure(Future<void> f) async {
      try {
        await f;
        return null;
      } on UpdateVerifyException catch (e) {
        return e.failure;
      }
    }

    test(
      'tampered sums, wrong key, malformed signature are rejected',
      () async {
        final sig = await sign(sums, key);
        expect(
          await failure(
            verifySumsSignature(
              utf8.encode('${sumsText}x'),
              sig,
              publicKeyB64: pubB64,
            ),
          ),
          VerifyFailure.badSignature,
        );
        final other = await cg.Ed25519().newKeyPair();
        expect(
          await failure(
            verifySumsSignature(
              sums,
              await sign(sums, other),
              publicKeyB64: pubB64,
            ),
          ),
          VerifyFailure.badSignature,
        );
        for (final bad in [
          '',
          'not base64!!',
          base64.encode([1, 2, 3]),
        ]) {
          expect(
            await failure(verifySumsSignature(sums, bad, publicKeyB64: pubB64)),
            VerifyFailure.badSignature,
          );
        }
      },
    );

    test('digest check: match, mismatch, unlisted', () {
      final map = parseSums(sumsText);
      final good = crypto.sha256.convert(utf8.encode('payload')).toString();
      verifyAssetDigest(map, 'kestrel-1.0.0-setup.exe', good);
      verifyAssetDigest(map, 'kestrel-1.0.0-setup.exe', good.toUpperCase());
      expect(
        () => verifyAssetDigest(map, 'kestrel-1.0.0-setup.exe', '0' * 64),
        throwsA(
          isA<UpdateVerifyException>().having(
            (e) => e.failure,
            'failure',
            VerifyFailure.checksumMismatch,
          ),
        ),
      );
      expect(
        () => verifyAssetDigest(map, 'other.exe', good),
        throwsA(
          isA<UpdateVerifyException>().having(
            (e) => e.failure,
            'failure',
            VerifyFailure.notListed,
          ),
        ),
      );
    });
  });

  group('UpdateService', () {
    late Directory tmp;
    late cg.SimpleKeyPair key;
    late String pubB64;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kestrel-update-test');
      key = await cg.Ed25519().newKeyPair();
      pubB64 = base64.encode((await key.extractPublicKey()).bytes);
    });
    tearDown(() => tmp.delete(recursive: true));

    const asset = 'kestrel-0.6.0-windows-x64-setup.exe';

    /// A fake GitHub: the releases listing plus the three downloadable files.
    Future<({UpdateService service, List<File> installed})> make({
      String fileContent = 'payload',
      bool tamperSums = false,
      bool omitSig = false,
    }) async {
      final installed = <File>[];
      final sumsText =
          '${crypto.sha256.convert(utf8.encode('payload'))}  $asset\n';
      final sig = await cg.Ed25519().sign(utf8.encode(sumsText), keyPair: key);
      final served = tamperSums ? '${sumsText}tampered\n' : sumsText;
      final listing = jsonEncode([
        _rel(
          'app-v0.6.0',
          body: '### Features\n* new thing',
          assets: [asset, 'SHA256SUMS.txt', if (!omitSig) 'SHA256SUMS.txt.sig'],
        ),
        _rel('bridge-v7.0.0'),
      ]);
      final service = UpdateService(
        currentVersion: _v('0.5.0'),
        platform: UpdatePlatform.windows,
        tempDir: tmp,
        publicKeyB64: pubB64,
        installer: _FakeInstaller(installed),
        exitApp: () {},
        fetch: (url, {int maxBytes = 0}) async {
          final u = url.toString();
          if (u.contains('api.github.com')) return utf8.encode(listing);
          if (u.endsWith('SHA256SUMS.txt')) return utf8.encode(served);
          if (u.endsWith('.sig')) return utf8.encode(base64.encode(sig.bytes));
          throw StateError('unexpected $u');
        },
        download: (url, dest, onProgress) async {
          await dest.writeAsString(fileContent);
          onProgress(7, 7);
        },
      );
      return (service: service, installed: installed);
    }

    test('check finds the newest app release', () async {
      final t = await make();
      await t.service.checkNow();
      expect(t.service.state.status, UpdateStatus.available);
      expect(t.service.state.release!.tag, 'app-v0.6.0');
      expect(t.service.state.manualOnly, isFalse);
    });

    test('up to date when nothing newer', () async {
      final t = await make();
      final s = UpdateService(
        currentVersion: _v('0.6.0'),
        platform: UpdatePlatform.windows,
        tempDir: tmp,
        fetch: (url, {int maxBytes = 0}) async => utf8.encode(
          jsonEncode([_rel('app-v0.6.0'), _rel('bridge-v7.0.0')]),
        ),
      );
      await s.checkNow();
      expect(s.state.status, UpdateStatus.upToDate);
      expect(t.installed, isEmpty);
    });

    test('network failure is reported, not thrown', () async {
      final s = UpdateService(
        currentVersion: _v('0.5.0'),
        platform: UpdatePlatform.windows,
        tempDir: tmp,
        fetch: (url, {int maxBytes = 0}) async =>
            throw const SocketException('down'),
      );
      await s.checkNow();
      expect(s.state.status, UpdateStatus.error);
      expect(s.state.error, UpdateError.network);
    });

    test('verified update is installed', () async {
      final t = await make();
      await t.service.checkNow();
      await t.service.install();
      expect(t.installed.single.path, endsWith(asset));
      expect(t.service.state.status, UpdateStatus.installing);
    });

    test('tampered download is refused', () async {
      final t = await make(fileContent: 'evil');
      await t.service.checkNow();
      await t.service.install();
      expect(t.installed, isEmpty);
      expect(t.service.state.status, UpdateStatus.error);
      expect(t.service.state.error, UpdateError.checksumMismatch);
    });

    test('tampered checksums fail the signature check', () async {
      final t = await make(tamperSums: true);
      await t.service.checkNow();
      await t.service.install();
      expect(t.installed, isEmpty);
      expect(t.service.state.error, UpdateError.badSignature);
    });

    test('a release without a signature is refused', () async {
      final t = await make(omitSig: true);
      await t.service.checkNow();
      await t.service.install();
      expect(t.installed, isEmpty);
      expect(t.service.state.error, UpdateError.assetMissing);
    });

    test('Linux without AppImage is manual only', () async {
      final s = UpdateService(
        currentVersion: _v('0.5.0'),
        platform: UpdatePlatform.linux,
        tempDir: tmp,
        fetch: (url, {int maxBytes = 0}) async => utf8.encode(
          jsonEncode([
            _rel('app-v0.6.0', assets: ['kestrel-0.6.0-linux-x64.tar.gz']),
          ]),
        ),
      );
      await s.checkNow();
      expect(s.state.status, UpdateStatus.available);
      expect(s.state.manualOnly, isTrue);
    });
  });

  test('macOS bundle path from the executable', () {
    expect(
      macBundlePath('/Applications/Kestrel.app/Contents/MacOS/kestrel'),
      '/Applications/Kestrel.app',
    );
  });
}

class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller(this.installed);

  final List<File> installed;

  @override
  Future<void> install(
    File verified, {
    required void Function() exitApp,
  }) async {
    installed.add(verified);
  }
}
