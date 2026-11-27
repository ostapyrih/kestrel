import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/nomadnet/micron/micron_parser.dart';

MicronDocument p(String s, {bool dark = true}) => parseMicron(s, dark: dark);

List<String> texts(MicronBlock b) =>
    b.spans.whereType<MicronText>().map((t) => t.text).toList();

void main() {
  group('headers', () {
    test('cache time: default 12 h, #!c= seconds, 0 = never', () {
      expect(p('hello').cacheSeconds, 12 * 3600);
      expect(p('#!c=60\nhello').cacheSeconds, 60);
      expect(p('#!c=0\nhello').cacheSeconds, 0);
      expect(p('#!c=abc\nhello').cacheSeconds, 12 * 3600);
      // only the very first line counts
      expect(p('x\n#!c=5\n').cacheSeconds, 12 * 3600);
      expect(p('#!c=30').cacheSeconds, 30);
    });

    test('#!bg= and #!fg= take 3 or 6 hex', () {
      final d = p('#!bg=f00\n#!fg=00ff00\nhi');
      expect(d.background, 0xFF0000);
      expect(d.foreground, 0x00FF00);
      expect(p('#!bg=ff\nx').background, isNull);
      expect(p('#!bg=zzz\nx').background, isNull);
    });

    test('header lines are comments and produce no rows', () {
      final d = p('#!c=0\n#!bg=000\n# comment\nreal');
      expect(d.blocks.length, 1);
      expect(d.blocks.single.plainText, 'real');
    });
  });

  group('text and formatting', () {
    test('plain text, blank lines, unicode', () {
      final d = p('Привіт, світе 🌍\n\nдруга');
      expect(d.blocks.map((b) => b.kind), [
        MicronBlockKind.text,
        MicronBlockKind.blank,
        MicronBlockKind.text,
      ]);
      expect(d.blocks.first.plainText, 'Привіт, світе 🌍');
    });

    test('bold, italic, underline toggle and persist across lines', () {
      final d = p('a`!b`!c `*i`* `_u`_\n`!still bold');
      final s = d.blocks.first.spans.cast<MicronText>();
      expect(s.map((t) => t.text), ['a', 'b', 'c ', 'i', ' ', 'u']);
      expect(s[0].style.bold, isFalse);
      expect(s[1].style.bold, isTrue);
      expect(s[2].style.bold, isFalse);
      expect(s[3].style.italic, isTrue);
      expect(s[5].style.underline, isTrue);
      // formatting state survives the end of the line
      expect((d.blocks[1].spans.first as MicronText).style.bold, isTrue);
    });

    test('reset `` clears formatting, colours and alignment', () {
      final d = p('`!`c`Ff00x``y');
      final s = d.blocks.first.spans.cast<MicronText>();
      expect(s[0].style.bold, isTrue);
      expect(s[0].style.fg, 0xFF0000);
      expect(s[1].style.bold, isFalse);
      expect(s[1].style.fg, isNull);
      expect(d.blocks.first.align, MicronAlign.left);
    });

    test('nested formatting', () {
      final d = p('`!`*`_all`_ no-u`* no-i`! plain');
      final s = d.blocks.first.spans.cast<MicronText>();
      expect(
        s[0].style.bold && s[0].style.italic && s[0].style.underline,
        isTrue,
      );
      expect(s[1].style.underline, isFalse);
      expect(s[1].style.italic, isTrue);
      expect(s[2].style.italic, isFalse);
      expect(s[2].style.bold, isTrue);
      expect(s[3].style.bold, isFalse);
    });

    test('unknown formatting characters are swallowed', () {
      final d = p('a`qb');
      expect(texts(d.blocks.first), ['a', 'b']);
    });

    test('trailing lone backtick does not crash', () {
      expect(p('abc`').blocks.first.plainText, 'abc');
      expect(p('`').blocks, isEmpty);
    });

    test('escapes: \\` and \\\\ and a leading backslash', () {
      expect(p(r'a\`!b').blocks.first.plainText, 'a`!b');
      expect(p(r'a\\b').blocks.first.plainText, r'a\b');
      expect(p(r'\>not a heading').blocks.first.plainText, '>not a heading');
      expect(p(r'\#not a comment').blocks.first.plainText, '#not a comment');
    });

    test('control and zero-width characters are stripped', () {
      final dirty = String.fromCharCodes([
        0x61,
        0,
        0x62,
        0x200b,
        0x63,
        0x202e,
        0x64,
        0x1b,
      ]);
      expect(p(dirty).blocks.first.plainText, 'abcd');
    });

    test('CRLF line endings', () {
      final d = p('a\r\nb\r\n');
      expect(d.blocks.where((b) => b.kind == MicronBlockKind.text).length, 2);
      expect(d.blocks.first.plainText, 'a');
    });

    test('a very long line stays one block', () {
      final long = 'x' * 100000;
      final d = p(long);
      expect(d.blocks.length, 1);
      expect(d.blocks.first.plainText.length, 100000);
    });
  });

  group('colours', () {
    test('parseMicronColor forms', () {
      expect(parseMicronColor('f00'), 0xFF0000);
      expect(parseMicronColor('0f8'), 0x00FF88);
      expect(parseMicronColor('abcdef'), 0xABCDEF);
      expect(parseMicronColor('g00'), 0x000000);
      expect(parseMicronColor('g99'), 0xFCFCFC);
      expect(parseMicronColor('g50'), 0x808080);
      expect(parseMicronColor('xyz'), isNull);
      expect(parseMicronColor('ff'), isNull);
      expect(parseMicronColor('gzz'), isNull);
    });

    test('`F rgb, `FT truecolor, `B background, `f/`b resets', () {
      final d = p('`Ff00a`FT00ff00b`Bg50c`fd`be');
      final s = d.blocks.first.spans.cast<MicronText>();
      expect(s[0].style.fg, 0xFF0000);
      expect(s[1].style.fg, 0x00FF00);
      expect(s[2].style.bg, 0x808080);
      expect(s[3].style.fg, isNull);
      expect(s[3].style.bg, 0x808080);
      expect(s[4].style.bg, isNull);
    });

    test('page default colours are what resets return to', () {
      final d = p('#!fg=eee\n#!bg=111\n`Ff00a`fb');
      final s = d.blocks.first.spans.cast<MicronText>();
      expect(s[0].style.fg, 0xFF0000);
      expect(s[0].style.bg, 0x111111);
      expect(s[1].style.fg, 0xEEEEEE);
    });

    test('malformed colour tags degrade to the default colour', () {
      final d = p('`Fzzzx and `F1');
      expect((d.blocks.first.spans.first as MicronText).style.fg, isNull);
      // too short for a colour: nothing is consumed
      expect(d.blocks.first.plainText, contains('1'));
    });
  });

  group('alignment', () {
    test('the alignment in force at the end of the line applies', () {
      final d = p('`cx`a');
      expect(d.blocks.single.align, MicronAlign.left);
    });

    test('`c `l `r `a and persistence', () {
      final d = p('`ccentered\nstill\n`rright\n`lleft\n`rr\n`aback');
      expect(d.blocks.map((b) => b.align), [
        MicronAlign.center,
        MicronAlign.center,
        MicronAlign.right,
        MicronAlign.left,
        MicronAlign.right,
        MicronAlign.left,
      ]);
    });
  });

  group('sections and headings', () {
    test('> levels set depth and heading level', () {
      final d = p('>One\n>>Two\n>>>Three\n>>>>Four\ntext');
      expect(d.blocks.map((b) => b.headingLevel), [1, 2, 3, 3, 0]);
      expect(d.blocks.map((b) => b.depth), [1, 2, 3, 4, 4]);
      expect(d.blocks.first.plainText, 'One');
    });

    test('< resets the depth', () {
      final d = p('>>A\ntext\n<back');
      expect(d.blocks[1].depth, 2);
      expect(d.blocks[2].depth, 0);
      expect(d.blocks[2].plainText, 'back');
    });

    test('heading colours depend on the theme', () {
      expect(p('>H', dark: true).blocks.first.headingStyle!.bg, 0xBBBBBB);
      expect(p('>H', dark: false).blocks.first.headingStyle!.bg, 0x777777);
    });

    test('empty heading yields no row but sets the depth', () {
      final d = p('>>\ntext');
      expect(d.blocks.length, 1);
      expect(d.blocks.first.depth, 2);
    });

    test('a heading line containing a field is not a heading', () {
      final d = p('>Name: `<user`>');
      expect(d.blocks.first.kind, MicronBlockKind.text);
      expect(d.blocks.first.spans.whereType<MicronFieldSpan>(), hasLength(1));
    });

    test('formatting inside a heading does not leak out', () {
      final d = p('>Head `!bold\nafter');
      expect(d.blocks.last.spans.cast<MicronText>().first.style.bold, isFalse);
    });

    test('collapsible headings', () {
      final d = p('`+>Open\n`->Closed');
      expect(d.blocks[0].collapsible, isTrue);
      expect(d.blocks[0].collapsedInitially, isFalse);
      expect(d.blocks[1].collapsedInitially, isTrue);
    });

    test('heading slugs and explicit anchors resolve to block indexes', () {
      final d = p('>First Heading!\ntext\n`:mark\n>>Second `!one\nend');
      expect(d.anchors['first-heading'], 0);
      expect(d.anchors['mark'], 2);
      expect(d.anchors['second-one'], 2);
    });
  });

  group('dividers, literals, comments', () {
    test('divider default, custom char, and the "-text" quirk', () {
      final d = p('-\n-=\n- item');
      expect(
        d.blocks.map((b) => b.kind),
        everyElement(MicronBlockKind.divider),
      );
      expect(d.blocks[0].dividerChar, '─');
      expect(d.blocks[1].dividerChar, '=');
      // NomadNet treats any line starting with '-' as a divider
      expect(d.blocks[2].dividerChar, '─');
    });

    test('literal block shows markup verbatim', () {
      final d = p('`=\n>not heading `!x\n# not comment\n`=\nafter');
      expect(d.blocks[0].plainText, '>not heading `!x');
      expect(d.blocks[0].literal, isTrue);
      expect(d.blocks[1].plainText, '# not comment');
      expect(d.blocks.last.plainText, 'after');
      expect(d.blocks.last.literal, isFalse);
    });

    test('an escaped literal terminator inside a literal block', () {
      final d = p('`=\n\\`=\n`=');
      expect(d.blocks.single.plainText, '`=');
    });

    test('comments are dropped', () {
      expect(p('# a\n#b\n  # not a comment').blocks.length, 1);
    });
  });

  group('links', () {
    test('label + url, url only, with fields', () {
      final d = p(
        '`[Home`abcd:/page/index.mu] and `[:/page/x.mu] `[Go`:/p`a|b=1]',
      );
      final l = d.blocks.first.spans.whereType<MicronLinkSpan>().toList();
      expect(l[0].label, 'Home');
      expect(l[0].target, 'abcd:/page/index.mu');
      expect(l[0].fields, isNull);
      expect(l[1].label, ':/page/x.mu');
      expect(l[1].target, ':/page/x.mu');
      expect(l[2].fields, ['a', 'b=1']);
    });

    test('lxmf and anchor link targets are preserved', () {
      final l = p('`[Write`lxmf@0123456789abcdef0123456789abcdef] `[Up`#top]')
          .blocks
          .first
          .spans
          .whereType<MicronLinkSpan>()
          .toList();
      expect(l[0].target, 'lxmf@0123456789abcdef0123456789abcdef');
      expect(l[1].target, '#top');
    });

    test('links inherit the current style', () {
      final l = p('`!`Ff00`[x`:/p]').blocks.first.spans
          .whereType<MicronLinkSpan>()
          .single;
      expect(l.style.bold, isTrue);
      expect(l.style.fg, 0xFF0000);
    });

    test('malformed: unclosed bracket, empty target, too many parts', () {
      expect(p('`[oops').blocks.first.plainText, 'oops');
      expect(p('`[label`]').blocks.where((b) => b.spans.isNotEmpty), isEmpty);
      final d = p('a`[x`y`z`w]b');
      expect(d.blocks.first.spans.whereType<MicronLinkSpan>(), isEmpty);
      expect(texts(d.blocks.first), ['a', 'b']);
    });

    test('link text with unicode and spaces', () {
      final l =
          p('`[Мій вузол 🌍`ab:/x]').blocks.first.spans.single
              as MicronLinkSpan;
      expect(l.label, 'Мій вузол 🌍');
    });
  });

  group('form elements', () {
    test('text field defaults and flags', () {
      final f = p('`<user`hello>').blocks.first.spans.single as MicronFieldSpan;
      expect(f.name, 'user');
      expect(f.width, 24);
      expect(f.rows, 1);
      expect(f.masked, isFalse);
      expect(f.initial, 'hello');

      final g = p('`<!12|pw`>').blocks.first.spans.single as MicronFieldSpan;
      expect(g.masked, isTrue);
      expect(g.width, 12);
      expect(g.name, 'pw');

      final h =
          p('`<30x4|notes`text>').blocks.first.spans.single as MicronFieldSpan;
      expect(h.width, 30);
      expect(h.rows, 4);
    });

    test('width is capped at 256 and bad widths are ignored', () {
      expect(
        (p('`<999|a`>').blocks.first.spans.single as MicronFieldSpan).width,
        256,
      );
      expect(
        (p('`<zz|a`>').blocks.first.spans.single as MicronFieldSpan).width,
        24,
      );
    });

    test('checkbox and radio with value and prechecked', () {
      final d = p('`<?|opt|yes|*`Enable>  `<^|size|big`Large>');
      final c = d.blocks.first.spans.whereType<MicronChoiceSpan>().toList();
      expect(c[0].radio, isFalse);
      expect(c[0].name, 'opt');
      expect(c[0].value, 'yes');
      expect(c[0].checked, isTrue);
      expect(c[0].label, 'Enable');
      expect(c[1].radio, isTrue);
      expect(c[1].value, 'big');
      expect(c[1].checked, isFalse);
    });

    test('value defaults to the label', () {
      final c = p('`<?|x`Label>').blocks.first.spans.single as MicronChoiceSpan;
      expect(c.value, 'Label');
    });

    test('malformed fields: no backtick, no closing >', () {
      // the stray '<' is dropped, the rest stays text (as in NomadNet)
      expect(p('a`<name').blocks.first.plainText, 'aname');
      expect(
        p('`<name`value').blocks.first.spans.whereType<MicronFieldSpan>(),
        isEmpty,
      );
    });

    test('field + label + link on one line', () {
      final d = p('Name: `<n`>  `[Send`:/p`*]');
      final kinds = d.blocks.first.spans.map((s) => s.runtimeType).toList();
      expect(kinds, [MicronText, MicronFieldSpan, MicronText, MicronLinkSpan]);
    });
  });

  group('degraded features', () {
    test('tables become literal monospace rows', () {
      final d = p('`t\na | b\n1 | 2\n`t\nafter');
      expect(d.blocks.map((b) => b.plainText), ['a | b', '1 | 2', 'after']);
      expect(d.blocks.first.literal, isTrue);
    });

    test('images show a placeholder, partials vanish', () {
      final d = p('`(logo`:/img.webp)\n`{:/part.mu}\ntext');
      expect(d.blocks.first.plainText, '[image: logo]');
      expect(d.blocks.length, 2);
    });
  });

  group('real-world style page', () {
    const page = '''#!c=3600
>Mesh Notes

`c`!Welcome`! to my node
`a

Contact: `[me`lxmf@0123456789abcdef0123456789abcdef]
-
>>Links
`F0af`[Index`:/page/index.mu]`f | `[Files`:/page/files.mu`dir=pub]
`=
raw `! markup `[x`y]
`=
>>>Search
Query: `<q`> `[Go`:/page/search.mu`q]
`<?|all|1`Include all>
`<^|mode|fast|*`Fast` `<^|mode|slow`Slow>
''';

    test('parses to the expected structure', () {
      final d = p(page);
      expect(d.cacheSeconds, 3600);
      final kinds = d.blocks.map((b) => b.kind).toList();
      expect(kinds.first, MicronBlockKind.heading);
      expect(
        d.blocks.where((b) => b.kind == MicronBlockKind.divider),
        hasLength(1),
      );
      final links = [
        for (final b in d.blocks) ...b.spans.whereType<MicronLinkSpan>(),
      ];
      expect(links.map((l) => l.label), ['me', 'Index', 'Files', 'Go']);
      final lit = d.blocks.firstWhere((b) => b.literal);
      expect(lit.plainText, 'raw `! markup `[x`y]');
      expect(d.blocks[1].kind, MicronBlockKind.blank);
      expect(d.blocks[2].align, MicronAlign.center);
    });
  });
}
