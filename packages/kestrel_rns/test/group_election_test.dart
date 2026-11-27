import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:test/test.dart';

SiblingInfo _s(String id,
        {bool net = true, int offset = 0, bool announcing = false}) =>
    SiblingInfo(
      id: id,
      heardAt: 100,
      wall: 1000 + offset,
      heardWall: 1000,
      internet: net,
      announcing: announcing,
    );

void main() {
  group('electAnnouncer', () {
    test('alone: this device', () {
      expect(electAnnouncer(self: 'b', selfInternet: false, alive: {}), 'b');
    });

    test('lowest device id among equals', () {
      expect(
          electAnnouncer(
              self: 'c',
              selfInternet: true,
              alive: {'b': _s('b'), 'd': _s('d')}),
          'b');
    });

    test('internet beats LoRa-only, then lowest id', () {
      expect(
          electAnnouncer(
              self: 'a',
              selfInternet: false,
              alive: {'b': _s('b', net: false), 'c': _s('c')}),
          'c');
      expect(
          electAnnouncer(
              self: 'a',
              selfInternet: false,
              alive: {'b': _s('b', net: false)}),
          'a');
    });

    test('a candidate whose clock is far ahead is excluded', () {
      final alive = {
        'a': _s('a', offset: 3600), // clock an hour ahead, lowest id
        'c': _s('c'),
        'd': _s('d', offset: 2),
      };
      expect(electAnnouncer(self: 'b', selfInternet: true, alive: alive), 'b');
      // a clock far BEHIND does not matter (the monotonic timebase copes)
      expect(
          electAnnouncer(
              self: 'b',
              selfInternet: true,
              alive: {'a': _s('a', offset: -3600), 'c': _s('c')}),
          'a');
    });

    test('this device is excluded when its own clock is the ahead one', () {
      // siblings see us 1 h behind => from our side they are 1 h behind,
      // and we are the one ahead of the median
      expect(
          electAnnouncer(self: 'a', selfInternet: true, alive: {
            'b': _s('b', offset: -3600),
            'c': _s('c', offset: -3600),
          }),
          'b');
    });
  });
}
