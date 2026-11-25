import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

import 'support/vectors.dart';

void main() {
  final hv = loadVectors('hdlc.json');
  final kv = loadVectors('kiss.json');

  group('hdlc', () {
    test('constants', () {
      expect(Hdlc.flag, hv['flag']);
      expect(Hdlc.esc, hv['esc']);
      expect(Hdlc.escMask, hv['esc_mask']);
      expect(Hdlc.headerMinSize, hv['header_minsize']);
      expect(Hdlc.defaultHwMtu, hv['default_hw_mtu']);
    });
    for (final f in maps(hv['frames'])) {
      test('frame ${(f['payload']! as String).length ~/ 2}B', () {
        final p = unhex(f['payload'] as String?);
        expect(hex(Hdlc.escape(p)), f['escaped']);
        expect(hex(Hdlc.frame(p)), f['frame']);
        expect(Hdlc.unescape(unhex(f['escaped'] as String?)), p);
      });
    }
    for (final s in maps(hv['streams'])) {
      test('stream ${s['name']}', () {
        final d = HdlcDecoder(hwMtu: s['hw_mtu']! as int);
        final got = <String>[];
        for (final c in (s['chunks']! as List<Object?>).cast<String>()) {
          got.addAll(d.feed(unhex(c)).map(hex));
        }
        expect(got, (s['frames']! as List<Object?>).cast<String>());
      });
    }
  });

  group('kiss', () {
    test('constants', () {
      expect(Kiss.fend, kv['fend']);
      expect(Kiss.fesc, kv['fesc']);
      expect(Kiss.tfend, kv['tfend']);
      expect(Kiss.tfesc, kv['tfesc']);
      expect(Kiss.rnodeHwMtu, kv['default_hw_mtu']);
    });
    for (final f in maps(kv['frames'])) {
      test('frame ${(f['payload']! as String).length ~/ 2}B', () {
        final p = unhex(f['payload'] as String?);
        expect(hex(Kiss.escape(p)), f['escaped']);
        expect(hex(Kiss.frame(p)), f['frame']);
      });
    }
    for (final c in maps(kv['commands'])) {
      test('command ${c['name']}', () {
        final payload = unhex(c['payload'] as String?);
        expect(hex(Kiss.frame(payload, command: c['command']! as int)),
            c['frame']);
        final frames = KissDecoder().feed(unhex(c['frame'] as String?));
        expect(frames, hasLength(1));
        expect(frames.single.command, c['command']);
        expect(frames.single.data, payload);
      });
    }
    for (final s in maps(kv['streams'])) {
      test('stream ${s['name']}', () {
        final d = KissDecoder(hwMtu: s['hw_mtu']! as int);
        final got = <(int, String)>[];
        for (final c in (s['chunks']! as List<Object?>).cast<String>()) {
          got.addAll(d.feed(unhex(c)).map((f) => (f.command, hex(f.data))));
        }
        final want = maps(s['frames'])
            .map((f) => (f['command']! as int, f['data']! as String))
            .toList();
        expect(got, want);
      });
    }
  });
}
