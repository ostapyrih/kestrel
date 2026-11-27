import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';

// Reference rows come from NomadNet's own MicronParser.py
// (`tools/micron_reference.py`, regenerate with `tools/gen_micron_reference.sh`).

/// `RRGGBB` int of a raw Micron colour as NomadNet keeps it, null for the
/// theme default / anything NomadNet maps to "default".
int? _refColor(String c) {
  if (c == 'default' || c == 'ddd') return null; // dark theme page default
  if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(c)) {
    return int.parse(c.split('').map((x) => x + x).join(), radix: 16);
  }
  if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(c)) return int.parse(c, radix: 16);
  final g = RegExp(r'^g(\d\d)$').firstMatch(c);
  if (g != null) {
    final v = (int.parse(g[1]!) * 255 / 100).round();
    return (v << 16) | (v << 8) | v;
  }
  return null;
}

typedef _Cell = (String, int?, int?);

List<List<_Cell>> _reference(String name) {
  final rows = jsonDecode(
    File('test/fixtures/micron/$name.ref.json').readAsStringSync(),
  ) as List;
  return [
    for (final r in rows)
      [
        for (final p in (r as List))
          if ((p['text'] as String).isNotEmpty)
            (
              p['text'] as String,
              _refColor((p['style'] as String).split('|')[0]),
              _refColor((p['style'] as String).split('|')[1]),
            ),
      ],
  ];
}

List<List<_Cell>> _kestrel(String name) {
  final doc = parseMicron(
    File('test/fixtures/micron/$name.mu').readAsStringSync(),
  );
  return [
    for (final b in doc.blocks)
      [
        for (final s in b.spans)
          (
            switch (s) {
              MicronText t => t.text,
              MicronLinkSpan l => l.label,
              _ => '?',
            },
            s.style.fg,
            s.style.bg,
          ),
      ],
  ];
}

/// urwid merges neighbouring runs of the same attribute; do the same.
List<_Cell> _merge(List<_Cell> row) {
  final out = <_Cell>[];
  for (final c in row) {
    if (out.isNotEmpty && out.last.$2 == c.$2 && out.last.$3 == c.$3) {
      out[out.length - 1] = (out.last.$1 + c.$1, c.$2, c.$3);
    } else {
      out.add(c);
    }
  }
  return out;
}

int _columns(List<_Cell> row) => row.fold(0, (n, c) => n + c.$1.runes.length);

void main() {
  for (final name in ['alert_map', 'edge_cases']) {
    test('$name: rows, columns and cell colours match NomadNet', () {
      final ref = _reference(name);
      final got = _kestrel(name);
      expect(got.length, ref.length, reason: 'row count');
      for (var i = 0; i < ref.length; i++) {
        expect(_columns(got[i]), _columns(ref[i]), reason: 'columns, row $i');
        expect(_merge(got[i]), _merge(ref[i]), reason: 'spans, row $i');
      }
    });
  }
}
