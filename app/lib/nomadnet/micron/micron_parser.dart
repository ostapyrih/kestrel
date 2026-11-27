/// Micron markup parser: a faithful port of the line parser of NomadNet
/// (`nomadnet/ui/textui/MicronParser.py`, 1.5.x), producing a plain-Dart
/// document model that the Flutter renderer draws. Pure Dart (no Flutter).
///
/// Supported: sections (`>`, `<`), headings with fold markers (`` `+> ``,
/// `` `-> ``), dividers (`-`), literal blocks (`` `= ``), comments (`#`),
/// escapes (`\`), formatting (`` `! `` bold, `` `* `` italic, `` `_ ``
/// underline, `` `` `` reset), colours (`` `F ``/`` `B ``: 3-hex, `g`+2-digit
/// grayscale, `T`+6-hex; `` `f ``/`` `b `` reset), alignment (`` `c `` `` `l ``
/// `` `r `` `` `a ``), links, input fields, checkboxes and radio buttons,
/// anchors (`` `:name ``) and the page headers `#!c=`, `#!bg=`, `#!fg=`.
///
/// Known gaps (degrade gracefully): tables (`` `t ``) are shown as plain
/// monospace text, images (`` `( ``) as an `[image: alt]` placeholder and
/// partials (`` `{ ``) are dropped.
library;

/// NomadNet's default page cache time (`Browser.DEFAULT_CACHE_TIME`): 12 h.
const int micronDefaultCacheSeconds = 12 * 60 * 60;

enum MicronAlign { left, center, right }

/// Text style at a point of the page. Colours are `0xRRGGBB`; null means
/// "the page/theme default".
class MicronStyle {
  const MicronStyle({
    this.fg,
    this.bg,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final int? fg;
  final int? bg;
  final bool bold;
  final bool italic;
  final bool underline;

  @override
  bool operator ==(Object other) =>
      other is MicronStyle &&
      other.fg == fg &&
      other.bg == bg &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline;

  @override
  int get hashCode => Object.hash(fg, bg, bold, italic, underline);

  @override
  String toString() =>
      'MicronStyle(fg: ${fg?.toRadixString(16)}, bg: ${bg?.toRadixString(16)}'
      '${bold ? ', bold' : ''}${italic ? ', italic' : ''}'
      '${underline ? ', underline' : ''})';
}

/// Inline element of a line.
sealed class MicronSpan {
  const MicronSpan(this.style);
  final MicronStyle style;
}

class MicronText extends MicronSpan {
  const MicronText(this.text, super.style);
  final String text;

  @override
  String toString() => 'Text(${text.length > 30 ? '${text.substring(0, 30)}…' : text})';
}

class MicronLinkSpan extends MicronSpan {
  const MicronLinkSpan(this.label, this.target, this.fields, super.style);
  final String label;

  /// Raw target (`hash:/page/x.mu`, `:/page/x.mu`, `lxmf@...`, `#anchor`).
  final String target;

  /// The link's field list (`name`, `k=v`, `*`), or null for a plain link.
  final List<String>? fields;

  @override
  String toString() => 'Link($label -> $target)';
}

/// A text input field.
class MicronFieldSpan extends MicronSpan {
  const MicronFieldSpan({
    required this.name,
    required this.width,
    required this.rows,
    required this.masked,
    required this.initial,
    required MicronStyle style,
  }) : super(style);
  final String name;
  final int width;
  final int rows;
  final bool masked;
  final String initial;
}

/// A checkbox or radio button.
class MicronChoiceSpan extends MicronSpan {
  const MicronChoiceSpan({
    required this.name,
    required this.value,
    required this.label,
    required this.checked,
    required this.radio,
    required MicronStyle style,
  }) : super(style);
  final String name;
  final String value;
  final String label;
  final bool checked;
  final bool radio;
}

enum MicronBlockKind { text, heading, divider, blank }

/// One rendered row group (a line of the page).
class MicronBlock {
  const MicronBlock({
    required this.kind,
    this.spans = const [],
    this.align = MicronAlign.left,
    this.depth = 0,
    this.headingLevel = 0,
    this.headingStyle,
    this.dividerChar = '─',
    this.collapsible = false,
    this.collapsedInitially = false,
    this.literal = false,
  });

  final MicronBlockKind kind;
  final List<MicronSpan> spans;
  final MicronAlign align;

  /// Section depth (indentation `(depth - 1) * 2` columns both sides).
  final int depth;

  /// 1..3 for headings (deeper levels use level 3's look).
  final int headingLevel;

  /// Style of the heading bar (colours from the theme's heading style).
  final MicronStyle? headingStyle;
  final String dividerChar;
  final bool collapsible;
  final bool collapsedInitially;
  final bool literal;

  bool get hasInputs =>
      spans.any((s) => s is MicronFieldSpan || s is MicronChoiceSpan);

  /// Plain text of the block (for tests and search).
  String get plainText => spans
      .map((s) => switch (s) {
            MicronText t => t.text,
            MicronLinkSpan l => l.label,
            MicronChoiceSpan c => c.label,
            MicronFieldSpan f => f.initial,
          })
      .join();
}

/// A parsed page.
class MicronDocument {
  const MicronDocument({
    required this.blocks,
    required this.anchors,
    required this.cacheSeconds,
    this.background,
    this.foreground,
  });

  final List<MicronBlock> blocks;

  /// Anchor name -> index into [blocks].
  final Map<String, int> anchors;

  /// `#!c=` seconds (0 = do not cache); default 12 h.
  final int cacheSeconds;

  /// `#!bg=` / `#!fg=` page colours (`0xRRGGBB`).
  final int? background;
  final int? foreground;
}

/// Parses a colour as written after `` `F `` / `` `B ``: `rgb` (3 hex),
/// `gNN` (grayscale percent) or 6 hex (`T` prefix already removed). Null for
/// anything else (NomadNet then falls back to its default colour).
int? parseMicronColor(String c) {
  if (c.length == 6) {
    final v = int.tryParse(c, radix: 16);
    return (v == null || c.contains(RegExp(r'[^0-9a-fA-F]'))) ? null : v;
  }
  if (c.length == 3) {
    if (c[0] == 'g') {
      final p = int.tryParse(c.substring(1));
      if (p == null || c.substring(1).contains(RegExp(r'\D'))) return null;
      final g = (p.clamp(0, 100) * 255 / 100).round();
      return (g << 16) | (g << 8) | g;
    }
    if (c.contains(RegExp(r'[^0-9a-fA-F]'))) return null;
    final r = int.parse(c[0], radix: 16) * 17;
    final g = int.parse(c[1], radix: 16) * 17;
    final b = int.parse(c[2], radix: 16) * 17;
    return (r << 16) | (g << 8) | b;
  }
  return null;
}

/// Removes control, bidi and zero-width characters like NomadNet's
/// `STRIP_CONTROL_RE` (tab, LF and CR survive).
String stripMicronControl(String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    final strip = (c <= 0x08) ||
        c == 0x0B ||
        c == 0x0C ||
        (c >= 0x0E && c <= 0x1F) ||
        (c >= 0x7F && c <= 0x9F) ||
        (c >= 0x200B && c <= 0x200F) ||
        (c >= 0x202A && c <= 0x202E) ||
        (c >= 0x2060 && c <= 0x206F) ||
        c == 0xFEFF ||
        (c >= 0xFFF0 && c <= 0xFFF8);
    if (!strip) out.writeCharCode(c);
  }
  return out.toString();
}

/// Heading colours (`STYLES_DARK` / `STYLES_LIGHT`).
const _headingDark = [
  MicronStyle(fg: 0x222222, bg: 0xBBBBBB),
  MicronStyle(fg: 0x111111, bg: 0x999999),
  MicronStyle(fg: 0x000000, bg: 0x777777),
];
const _headingLight = [
  MicronStyle(fg: 0x000000, bg: 0x777777),
  MicronStyle(fg: 0x111111, bg: 0xAAAAAA),
  MicronStyle(fg: 0x222222, bg: 0xCCCCCC),
];

/// Reads `#!c=` (first line only, like NomadNet).
int micronCacheSeconds(String markup) {
  if (markup.startsWith('#!c=')) {
    var end = markup.indexOf('\n');
    if (end == -1) end = markup.length;
    final v = int.tryParse(markup.substring(4, end).trim());
    if (v != null) return v;
  }
  return micronDefaultCacheSeconds;
}

int? _headerColor(String markup, String key) {
  final p = markup.indexOf(key);
  if (p < 0) return null;
  var end = markup.indexOf('\n', p);
  if (end == -1) end = markup.length;
  final v = markup.substring(p + key.length, end).replaceAll('\r', '');
  if (v.length != 3 && v.length != 6) return null;
  return parseMicronColor(v);
}

/// Parses [markup]. [dark] selects the heading colours.
MicronDocument parseMicron(String markup, {bool dark = true}) {
  final cache = micronCacheSeconds(markup);
  final bg = _headerColor(markup, '#!bg=');
  final fg = _headerColor(markup, '#!fg=');
  final p = _Parser(dark ? _headingDark : _headingLight, bg, fg);
  final text = stripMicronControl(markup).replaceAll('\r\n', '\n');
  for (final line in text.split('\n')) {
    p.line(line);
  }
  return MicronDocument(
    blocks: p.blocks,
    anchors: p.anchors,
    cacheSeconds: cache,
    background: bg,
    foreground: fg,
  );
}

class _Parser {
  _Parser(this.headings, int? bg, int? fg)
      : defaultBg = bg,
        defaultFg = fg,
        fgColor = fg,
        bgColor = bg;

  final List<MicronStyle> headings;
  final int? defaultFg;
  final int? defaultBg;

  final blocks = <MicronBlock>[];
  final anchors = <String, int>{};
  final pendingAnchors = <String>[];

  bool literal = false;
  bool tableMode = false;
  final tableBuffer = <String>[];
  int depth = 0;
  int? fgColor;
  int? bgColor;
  bool bold = false;
  bool underline = false;
  bool italic = false;
  MicronAlign align = MicronAlign.left;

  MicronStyle style() => MicronStyle(
        fg: fgColor,
        bg: bgColor,
        bold: bold,
        italic: italic,
        underline: underline,
      );

  void emit(MicronBlock b) {
    final idx = blocks.length;
    for (final a in pendingAnchors) {
      if (a.isNotEmpty) anchors.putIfAbsent(a, () => idx);
    }
    pendingAnchors.clear();
    blocks.add(b);
  }

  void line(String line) {
    if (line.isEmpty) {
      emit(MicronBlock(kind: MicronBlockKind.blank, depth: depth, align: align));
      return;
    }
    _parseLine(line);
  }

  /// Parses one non-empty line, emitting zero or more blocks.
  Object? _parseLine(String line) {
    var preEscape = false;
    var first = line[0];

    if (line == '`=') {
      literal = !literal;
      return null;
    }

    if (!literal) {
      var collapsible = false;
      var collapsed = false;
      if ((line.startsWith('`+') || line.startsWith('`-')) &&
          line.length > 2 &&
          line[2] == '>') {
        collapsible = true;
        collapsed = line[1] == '-';
        line = line.substring(2);
        first = line[0];
      }

      if (first == '>' && line.contains('`<')) {
        line = line.replaceFirst(RegExp(r'^>+'), '');
        if (line.isEmpty) return null;
        first = line[0];
      }

      if (first == r'\') {
        line = line.substring(1);
        preEscape = true;
        if (line.isEmpty) {
          return null;
        }
      } else if (first == '#') {
        return null;
      } else {
        if (line.startsWith('`t')) {
          if (tableMode) {
            _flushTable();
            tableMode = false;
          } else {
            tableMode = true;
            tableBuffer.clear();
          }
          return null;
        }
        if (tableMode) {
          tableBuffer.add(line);
          return null;
        }
        if (line.startsWith('`{')) return null; // partial (unsupported)
        if (line.startsWith('`(')) {
          _image(line.substring(2));
          return null;
        }
        if (first == '<') {
          depth = 0;
          final rest = line.substring(1);
          if (rest.isEmpty) return null;
          return _parseLine(rest);
        }
        if (first == '>') {
          var i = 0;
          while (i < line.length && line[i] == '>') {
            i++;
          }
          depth = i;
          line = line.substring(depth);
          if (line.isEmpty) return null;
          final hs = headings[(i - 1).clamp(0, 2)];
          final latched = (fgColor, bgColor, bold, underline, italic);
          fgColor = hs.fg;
          bgColor = hs.bg;
          bold = false;
          underline = false;
          italic = false;
          final spans = _makeOutput(line, false);
          fgColor = latched.$1;
          bgColor = latched.$2;
          bold = latched.$3;
          underline = latched.$4;
          italic = latched.$5;
          final slug = _slug(line);
          if (slug.isNotEmpty) pendingAnchors.add(slug);
          if (spans.isEmpty) return null;
          emit(MicronBlock(
            kind: MicronBlockKind.heading,
            spans: spans,
            align: align,
            depth: depth,
            headingLevel: i.clamp(1, 3),
            headingStyle: hs,
            collapsible: collapsible,
            collapsedInitially: collapsed,
          ));
          return null;
        }
        if (first == '-') {
          var ch = '─';
          if (line.length == 2) {
            final c = line.runes.toList()[1];
            if (c >= 32) ch = String.fromCharCode(c);
          }
          emit(MicronBlock(
            kind: MicronBlockKind.divider,
            dividerChar: ch,
            depth: depth,
          ));
          return null;
        }
      }
    }

    final spans = _makeOutput(line, preEscape);
    if (spans.isEmpty) return null;
    emit(MicronBlock(
      kind: MicronBlockKind.text,
      spans: spans,
      align: align,
      depth: depth,
      literal: literal,
    ));
    return null;
  }

  void _flushTable() {
    for (final l in tableBuffer) {
      emit(MicronBlock(
        kind: MicronBlockKind.text,
        spans: [MicronText(l, style())],
        depth: depth,
        literal: true,
      ));
    }
    tableBuffer.clear();
  }

  void _image(String rest) {
    final end = rest.lastIndexOf(')');
    if (end <= 0) return;
    final fields = rest.substring(0, end).split('`');
    if (fields.length < 2) return;
    final alt = fields.first.trim();
    final url = fields.last.trim();
    emit(MicronBlock(
      kind: MicronBlockKind.text,
      spans: [MicronText('[image: ${alt.isEmpty ? url : alt}]', style())],
      depth: depth,
      align: align,
    ));
  }

  static String _slug(String text) {
    final stripped = text.replaceAll(
      RegExp(r'`[FB]T[0-9a-fA-F]{6}|`[FB][0-9a-fA-F]{3}|`:[A-Za-z0-9_\-]*|`[!*_=fbacrl`<>{]'),
      '',
    );
    return stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
  }

  /// Port of `make_output`: walks [line] as a text/formatting state machine.
  List<MicronSpan> _makeOutput(String line, bool preEscape) {
    final out = <MicronSpan>[];
    if (literal) {
      out.add(MicronText(line == r'\`=' ? '`=' : line, style()));
      return out;
    }
    final sb = StringBuffer();
    var formatting = false;
    var escape = preEscape;
    var skip = 0;

    void flush() {
      if (sb.isNotEmpty) {
        out.add(MicronText(sb.toString(), style()));
        sb.clear();
      }
    }

    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (skip > 0) {
        skip--;
        continue;
      }
      if (formatting) {
        switch (c) {
          case '_':
            underline = !underline;
          case '!':
            bold = !bold;
          case '*':
            italic = !italic;
          case 'F':
          case 'B':
            // NomadNet indexes by code point, Dart strings by UTF-16 unit:
            // take the colour from the code points after the tag.
            final rest = line.substring(i + 1).runes.toList();
            if (rest.length >= 3) {
              String color;
              if (rest[0] == 0x54 /* T */ && rest.length >= 7) {
                color = String.fromCharCodes(rest.sublist(1, 7));
                skip = color.length + 1; // UTF-16 units consumed
              } else {
                color = String.fromCharCodes(rest.sublist(0, 3));
                skip = color.length;
              }
              final v = parseMicronColor(color);
              if (c == 'F') {
                fgColor = v;
              } else {
                bgColor = v;
              }
            }
          case 'f':
            fgColor = defaultFg;
          case 'b':
            bgColor = defaultBg;
          case '`':
            bold = false;
            underline = false;
            italic = false;
            fgColor = defaultFg;
            bgColor = defaultBg;
            align = MicronAlign.left;
          case 'c':
            align = MicronAlign.center;
          case 'l':
            align = MicronAlign.left;
          case 'r':
            align = MicronAlign.right;
          case 'a':
            align = MicronAlign.left;
          case ':':
            var e = i + 1;
            while (e < line.length && RegExp(r'[A-Za-z0-9_\-]').hasMatch(line[e])) {
              e++;
            }
            final name = line.substring(i + 1, e);
            if (name.isNotEmpty) pendingAnchors.add(name);
            skip = (e - i) - 1;
            if (skip < 0) skip = 0;
          case '<':
            flush();
            final consumed = _field(line, i, out);
            if (consumed > 0) skip = consumed;
          case '[':
            final rel = line.substring(i).indexOf(']');
            if (rel != -1) {
              final data = line.substring(i + 1, i + rel);
              skip = rel;
              final comps = data.split('`');
              String label = '';
              String url = '';
              String fields = '';
              if (comps.length == 1) {
                url = data;
              } else if (comps.length == 2) {
                label = comps[0];
                url = comps[1];
              } else if (comps.length == 3) {
                label = comps[0];
                url = comps[1];
                fields = comps[2];
              }
              if (url.isNotEmpty) {
                if (label.isEmpty) label = url;
                flush();
                out.add(MicronLinkSpan(
                  label,
                  url,
                  fields.isEmpty ? null : fields.split('|'),
                  style(),
                ));
              }
            }
        }
        formatting = false;
      } else {
        if (c == r'\') {
          if (escape) {
            sb.write(c);
            escape = false;
          } else {
            escape = true;
          }
        } else if (c == '`') {
          if (escape) {
            sb.write(c);
            escape = false;
          } else {
            formatting = true;
            flush();
          }
        } else {
          sb.write(c);
          escape = false;
        }
      }
    }
    flush();
    return out;
  }

  /// Parses a field/checkbox/radio at `line[i] == '<'`. Returns the number
  /// of characters to skip after `<` (0 if the field is malformed).
  int _field(String line, int i, List<MicronSpan> out) {
    final bt = line.indexOf('`', i + 1);
    if (bt == -1) return 0;
    final content = line.substring(i + 1, bt);
    var masked = false;
    var width = 24;
    var rows = 1;
    var type = 'field';
    var name = content;
    var value = '';
    var pre = false;
    if (content.contains('|')) {
      final comps = content.split('|');
      var flags = comps[0];
      name = comps[1];
      if (flags.contains('^')) {
        type = 'radio';
        flags = flags.replaceAll('^', '');
      } else if (flags.contains('?')) {
        type = 'checkbox';
        flags = flags.replaceAll('?', '');
      } else if (flags.contains('!')) {
        flags = flags.replaceAll('!', '');
        masked = true;
      }
      if (flags.isNotEmpty) {
        final xi = flags.indexOf('x');
        final wf = xi < 0 ? flags : flags.substring(0, xi);
        final rf = xi < 0 ? '' : flags.substring(xi + 1);
        final w = int.tryParse(wf.trim());
        if (w != null) width = w > 256 ? 256 : w;
        if (rf.isNotEmpty) {
          final r = int.tryParse(rf.trim());
          if (r != null) rows = r.clamp(1, 256);
        }
      }
      if (comps.length > 2) value = comps[2];
      if (comps.length > 3 && comps[3] == '*') pre = true;
    }
    final end = line.indexOf('>', bt);
    if (end == -1) return 0;
    final data = line.substring(bt + 1, end);
    if (type == 'checkbox' || type == 'radio') {
      out.add(MicronChoiceSpan(
        name: name,
        value: value.isNotEmpty ? value : data,
        label: data,
        checked: pre,
        radio: type == 'radio',
        style: style(),
      ));
    } else {
      out.add(MicronFieldSpan(
        name: name,
        width: width < 1 ? 1 : width,
        rows: rows,
        masked: masked,
        initial: data,
        style: style(),
      ));
    }
    return end - i;
  }
}
