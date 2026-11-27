import 'dart:convert';
import 'dart:typed_data';

import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

const h = '0123456789abcdef0123456789abcdef';

void main() {
  group('NomadUrl.parse (Browser.retrieve_url)', () {
    test('hash alone -> default path', () {
      final u = NomadUrl.parse(h);
      expect(u.hashHex, h);
      expect(u.path, '/page/index.mu');
    });

    test('hash:path and hash: (empty path -> default)', () {
      expect(NomadUrl.parse('$h:/page/a.mu').path, '/page/a.mu');
      expect(NomadUrl.parse('$h:').path, '/page/index.mu');
    });

    test('relative :path needs the current node', () {
      final cur = fromHex(h);
      final u = NomadUrl.parse(':/page/x.mu', current: cur);
      expect(u.hashHex, h);
      expect(u.path, '/page/x.mu');
      expect(() => NomadUrl.parse(':/page/x.mu'), throwsFormatException);
    });

    test('variables after the backtick become var_* request data', () {
      final u = NomadUrl.parse('$h:/page/a.mu`a=1|b=two|bad|c=x=y');
      expect(u.vars, {'a': '1', 'b': 'two'});
      expect(u.requestData, {'var_a': '1', 'var_b': 'two'});
      expect(u.text, '$h:/page/a.mu`a=1|b=two');
      expect(NomadUrl.parse('$h:/p`').requestData, isNull);
    });

    test('malformed input', () {
      for (final bad in [
        '',
        'zz',
        '$h:a:b',
        '${h}00',
        '${h.substring(1)}x',
        '$h:/p`a`b',
        'nothex-nothex-nothex-nothex-nothex',
      ]) {
        expect(() => NomadUrl.parse(bad), throwsFormatException,
            reason: bad);
        expect(NomadUrl.tryParse(bad), isNull);
      }
    });

    test('upper-case hex is accepted, file paths detected', () {
      final u = NomadUrl.parse('${h.toUpperCase()}:/file/a.bin');
      expect(u.hashHex, h);
      expect(u.isFile, isTrue);
      expect(NomadUrl.parse(h).isFile, isFalse);
    });

    test('equality is by canonical text', () {
      expect(NomadUrl.parse('$h:/p'), NomadUrl.parse('$h:/p'));
      expect(NomadUrl.parse('$h:/p`a=1'), isNot(NomadUrl.parse('$h:/p')));
    });
  });

  group('NomadLink.parse (Browser.handle_link)', () {
    test('anchors', () {
      final l = NomadLink.parse('#top');
      expect(l.kind, NomadLinkKind.anchor);
      expect(l.anchor, 'top');
    });

    test('node links: plain, nnn@ and nomadnetwork.node@', () {
      for (final t in ['$h:/page/a.mu', 'nnn@$h:/page/a.mu',
        'nomadnetwork.node@$h:/page/a.mu']) {
        final l = NomadLink.parse(t);
        expect(l.kind, NomadLinkKind.node, reason: t);
        expect(l.url, '$h:/page/a.mu');
      }
      expect(NomadLink.parse(':/page/a.mu').kind, NomadLinkKind.node);
    });

    test('lxmf links open a chat', () {
      final l = NomadLink.parse('lxmf@${h.toUpperCase()}');
      expect(l.kind, NomadLinkKind.lxmf);
      expect(l.lxmfHash, h);
      expect(NomadLink.parse('lxmf.delivery@$h').kind, NomadLinkKind.lxmf);
      expect(NomadLink.parse('lxmf@short').kind, NomadLinkKind.unknown);
    });

    test('rrc, partials and unknown kinds', () {
      expect(NomadLink.parse('rrc://$h/room').kind, NomadLinkKind.rrc);
      expect(NomadLink.parse('rrc@$h').kind, NomadLinkKind.rrc);
      expect(NomadLink.parse('p:abc').kind, NomadLinkKind.partial);
      expect(NomadLink.parse('foo@bar').kind, NomadLinkKind.unknown);
      expect(NomadLink.parse('a@b@c').kind, NomadLinkKind.unknown);
    });
  });

  group('buildNomadRequestData', () {
    test('null link fields -> no data (plain link)', () {
      expect(buildNomadRequestData(null, {'a': 'b'}), isNull);
    });

    test('empty list -> empty map', () {
      expect(buildNomadRequestData([], {'a': 'b'}), isEmpty);
    });

    test('named fields only, vars with prefix', () {
      final d = buildNomadRequestData(
        ['user', 'mode=edit'],
        {'user': 'bob', 'pass': 'secret'},
      );
      expect(d, {'var_mode': 'edit', 'field_user': 'bob'});
    });

    test('* sends every field', () {
      final d = buildNomadRequestData(
        ['*'],
        {'a': '1', 'b': '2'},
      );
      expect(d, {'field_a': '1', 'field_b': '2'});
    });

    test('var entries that are not exactly k=v are dropped', () {
      expect(buildNomadRequestData(['a=b=c', 'x='], {}), {'var_x': ''});
    });

    test('request data survives a msgpack roundtrip with str keys', () {
      final d = buildNomadRequestData(['*', 'v=1'], {'a': 'ж'})!;
      final back = unpackb(packb(d))! as Map<Object?, Object?>;
      expect(back, {'var_v': '1', 'field_a': 'ж'});
    });
  });

  group('decodeNodeName', () {
    Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

    test('plain, unicode and trimmed', () {
      expect(decodeNodeName(b('  Мій вузол  ')), 'Мій вузол');
    });

    test('control and bidi characters are stripped', () {
      expect(decodeNodeName(b('A\u0000B\u202eC\u200bD\x1b[31m')), 'ABCD[31m');
    });

    test('whitespace collapsed', () {
      expect(decodeNodeName(b('a \n\t b')), 'a b');
    });

    test('invalid utf-8 does not throw', () {
      expect(decodeNodeName(Uint8List.fromList([0x61, 0xff, 0x62])),
          'a\uFFFDb');
    });

    test('empty / null', () {
      expect(decodeNodeName(null), '');
      expect(decodeNodeName(Uint8List(0)), '');
    });
  });
}
