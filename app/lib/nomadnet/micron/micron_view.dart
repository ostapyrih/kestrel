import 'package:flutter/gestures.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';

import 'micron_parser.dart';

/// Called when a link is activated: the raw [target] and the request data
/// NomadNet would send (`var_*` / `field_*`), null for a plain link.
typedef MicronLinkTap = void Function(
  String target,
  Map<String, String>? requestData,
);

const _monoFamily = 'monospace';
const _monoFallback = ['Consolas', 'Menlo', 'Roboto Mono', 'Courier New'];

/// Renders a [MicronDocument]: monospace, selectable, theme aware, with
/// working links, input fields, checkboxes, radio buttons and foldable
/// headings. Nothing is loaded from anywhere: links only call [onLink].
class MicronView extends StatefulWidget {
  const MicronView({
    super.key,
    required this.document,
    required this.onLink,
    this.scrollToAnchor,
    this.controller,
    this.fontSize = 14,
    this.padding = const EdgeInsets.all(12),
  });

  final MicronDocument document;
  final MicronLinkTap onLink;

  /// Scrolls to this anchor once after build (`var_anchor`).
  final String? scrollToAnchor;
  final ScrollController? controller;
  final double fontSize;
  final EdgeInsets padding;

  @override
  State<MicronView> createState() => MicronViewState();
}

class MicronViewState extends State<MicronView> {
  late ScrollController _scroll;
  bool _ownsScroll = false;
  final _keys = <int, GlobalKey>{};
  final _fields = <(int, int), TextEditingController>{};
  final _checks = <(int, int), bool>{};
  final _radios = <String, (int, int)>{};
  final _collapsed = <int>{};
  final _recognizers = <(int, int), TapGestureRecognizer>{};

  @override
  void initState() {
    super.initState();
    _scroll = widget.controller ?? ScrollController();
    _ownsScroll = widget.controller == null;
    _init();
    _scheduleAnchor();
  }

  @override
  void didUpdateWidget(MicronView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _disposeState();
      _init();
      _scheduleAnchor();
    }
  }

  void _init() {
    final blocks = widget.document.blocks;
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b.collapsible && b.collapsedInitially) _collapsed.add(i);
      for (var j = 0; j < b.spans.length; j++) {
        final s = b.spans[j];
        if (s is MicronFieldSpan) {
          _fields[(i, j)] = TextEditingController(text: s.initial);
        } else if (s is MicronChoiceSpan) {
          if (s.radio) {
            if (s.checked) _radios[s.name] = (i, j);
          } else {
            _checks[(i, j)] = s.checked;
          }
        }
      }
    }
  }

  void _disposeState() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final r in _recognizers.values) {
      r.dispose();
    }
    _fields.clear();
    _checks.clear();
    _radios.clear();
    _collapsed.clear();
    _recognizers.clear();
    _keys.clear();
  }

  @override
  void dispose() {
    _disposeState();
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  void _scheduleAnchor() {
    final a = widget.scrollToAnchor;
    if (a == null || a.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => scrollToAnchor(a));
  }

  /// Scrolls to the anchor [name] (a `` `:name `` marker or a heading slug).
  void scrollToAnchor(String name) {
    final idx = widget.document.anchors[name];
    if (idx == null || !mounted) return;
    _revealIndex(idx);
    void ensure() {
      final ctx = _keys[idx]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200));
      }
    }

    if (_keys[idx]?.currentContext != null) {
      ensure();
    } else if (_scroll.hasClients) {
      // not built yet (lazy list): jump near it first, then align exactly
      _scroll.jumpTo(
        (idx * widget.fontSize * 1.5).clamp(0, _scroll.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => ensure());
    }
  }

  void _revealIndex(int idx) {
    // expand folded headings that hide [idx]
    final blocks = widget.document.blocks;
    var changed = false;
    for (var i = idx - 1; i >= 0; i--) {
      final b = blocks[i];
      if (b.kind == MicronBlockKind.heading &&
          b.collapsible &&
          _collapsed.contains(i) &&
          b.depth < blocks[idx].depth) {
        _collapsed.remove(i);
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  /// Current values of all form fields, as NomadNet collects them: text
  /// fields always, a radio group when one is selected, checkboxes joined
  /// with `,` when any is checked.
  Map<String, String> collectFields() {
    final out = <String, String>{};
    final blocks = widget.document.blocks;
    for (final e in _fields.entries) {
      final s = blocks[e.key.$1].spans[e.key.$2] as MicronFieldSpan;
      out[s.name] = e.value.text;
    }
    for (final e in _radios.entries) {
      final s = blocks[e.value.$1].spans[e.value.$2] as MicronChoiceSpan;
      out[e.key] = s.value;
    }
    final checked = <String, List<String>>{};
    for (final e in _checks.entries) {
      if (!e.value) continue;
      final s = blocks[e.key.$1].spans[e.key.$2] as MicronChoiceSpan;
      checked.putIfAbsent(s.name, () => []).add(s.value);
    }
    checked.forEach((k, v) => out[k] = v.join(','));
    return out;
  }

  void _tapLink(MicronLinkSpan l) {
    if (l.target.startsWith('#')) {
      scrollToAnchor(l.target.substring(1));
      return;
    }
    widget.onLink(
      l.target,
      buildNomadRequestData(l.fields, collectFields()),
    );
  }

  double get _charW => widget.fontSize * 0.6;

  List<int> _visible() {
    final blocks = widget.document.blocks;
    final out = <int>[];
    int? hide;
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (hide != null) {
        if (b.depth > hide) continue;
        hide = null;
      }
      out.add(i);
      if (b.kind == MicronBlockKind.heading &&
          b.collapsible &&
          _collapsed.contains(i)) {
        hide = b.depth;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final bg = doc.background != null ? Color(0xFF000000 | doc.background!) : null;
    final visible = _visible();
    final list = ListView.builder(
      controller: _scroll,
      padding: widget.padding,
      itemCount: visible.length,
      itemBuilder: (context, n) {
        final i = visible[n];
        return KeyedSubtree(
          key: _keys.putIfAbsent(i, GlobalKey.new),
          child: _block(context, i, doc.blocks[i]),
        );
      },
    );
    final child = SelectionArea(child: list);
    return bg == null ? child : ColoredBox(color: bg, child: child);
  }

  Color _defaultFg(BuildContext context) {
    final doc = widget.document;
    if (doc.foreground != null) return Color(0xFF000000 | doc.foreground!);
    if (doc.background != null) {
      final c = Color(0xFF000000 | doc.background!);
      return c.computeLuminance() > 0.5
          ? const Color(0xFF222222)
          : const Color(0xFFDDDDDD);
    }
    return Theme.of(context).colorScheme.onSurface;
  }

  TextStyle _textStyle(BuildContext context, MicronStyle s, {bool link = false}) {
    final doc = widget.document;
    final cs = Theme.of(context).colorScheme;
    Color? bg;
    if (s.bg != null && s.bg != doc.background) bg = Color(0xFF000000 | s.bg!);
    Color fg;
    if (s.fg != null) {
      fg = Color(0xFF000000 | s.fg!);
    } else if (link) {
      fg = cs.primary;
    } else {
      fg = _defaultFg(context);
    }
    return TextStyle(
      fontFamily: _monoFamily,
      fontFamilyFallback: _monoFallback,
      fontSize: widget.fontSize,
      height: 1.25,
      color: fg,
      backgroundColor: bg,
      fontWeight: s.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
      decoration: (s.underline || link)
          ? TextDecoration.underline
          : TextDecoration.none,
      decorationColor: fg,
    );
  }

  TextAlign _align(MicronAlign a) => switch (a) {
        MicronAlign.left => TextAlign.left,
        MicronAlign.center => TextAlign.center,
        MicronAlign.right => TextAlign.right,
      };

  InlineSpan _span(BuildContext context, int bi, int si, MicronSpan s) {
    switch (s) {
      case MicronText t:
        return TextSpan(text: t.text, style: _textStyle(context, t.style));
      case MicronLinkSpan l:
        final rec = _recognizers.putIfAbsent(
          (bi, si),
          () => TapGestureRecognizer(),
        )..onTap = () => _tapLink(l);
        return TextSpan(
          text: l.label,
          style: _textStyle(context, l.style, link: true),
          recognizer: rec,
          mouseCursor: SystemMouseCursors.click,
        );
      case MicronFieldSpan f:
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _fieldWidget(context, bi, si, f),
        );
      case MicronChoiceSpan c:
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _choiceWidget(context, bi, si, c),
        );
    }
  }

  Widget _fieldWidget(BuildContext context, int bi, int si, MicronFieldSpan f) {
    final style = _textStyle(context, f.style);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: (f.width + 2) * _charW + 16),
      child: SizedBox(
        width: (f.width + 2) * _charW + 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: TextField(
            key: ValueKey('micron-field-${f.name}-$bi-$si'),
            controller: _fields[(bi, si)],
            obscureText: f.masked,
            minLines: f.rows,
            maxLines: f.rows == 1 ? 1 : f.rows,
            style: style.copyWith(backgroundColor: null),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceWidget(BuildContext context, int bi, int si, MicronChoiceSpan c) {
    final style = _textStyle(context, c.style);
    final key = (bi, si);
    final selected = c.radio ? _radios[c.name] == key : (_checks[key] ?? false);
    void toggle() => setState(() {
          if (c.radio) {
            _radios[c.name] = key;
          } else {
            _checks[key] = !(_checks[key] ?? false);
          }
        });
    return InkWell(
      key: ValueKey('micron-${c.radio ? 'radio' : 'check'}-${c.name}-$bi-$si'),
      onTap: toggle,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            c.radio
                ? (selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked)
                : (selected ? Icons.check_box : Icons.check_box_outline_blank),
            size: widget.fontSize + 6,
            color: style.color,
          ),
          const SizedBox(width: 4),
          Text(c.label, style: style.copyWith(backgroundColor: null)),
        ],
      ),
    );
  }

  Widget _indent(MicronBlock b, Widget child) {
    if (b.depth <= 1) return child;
    final pad = (b.depth - 1) * 2 * _charW;
    return Padding(
      padding: EdgeInsets.only(left: pad, right: pad),
      child: child,
    );
  }

  Widget _block(BuildContext context, int i, MicronBlock b) {
    switch (b.kind) {
      case MicronBlockKind.blank:
        return SizedBox(height: widget.fontSize * 1.25);
      case MicronBlockKind.divider:
        return _indent(
          b,
          LayoutBuilder(
            builder: (context, c) {
              final n = (c.maxWidth / _charW).floor().clamp(1, 1000);
              return Text(
                b.dividerChar * n,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: _textStyle(context, const MicronStyle()),
              );
            },
          ),
        );
      case MicronBlockKind.heading:
        return _heading(context, i, b);
      case MicronBlockKind.text:
        return _indent(b, _line(context, i, b));
    }
  }

  Widget _line(BuildContext context, int i, MicronBlock b) {
    if (!b.hasInputs) {
      return SizedBox(
        width: double.infinity,
        child: Text.rich(
          TextSpan(children: [
            for (var j = 0; j < b.spans.length; j++) _span(context, i, j, b.spans[j]),
          ]),
          textAlign: _align(b.align),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: switch (b.align) {
          MicronAlign.left => WrapAlignment.start,
          MicronAlign.center => WrapAlignment.center,
          MicronAlign.right => WrapAlignment.end,
        },
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var j = 0; j < b.spans.length; j++)
            Text.rich(
              TextSpan(children: [_span(context, i, j, b.spans[j])]),
            ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, int i, MicronBlock b) {
    final first = b.spans.first.style;
    final hs = b.headingStyle!;
    final bg = Color(0xFF000000 | (first.bg ?? hs.bg ?? 0x777777));
    final fg = Color(0xFF000000 | (first.fg ?? hs.fg ?? 0x000000));
    final folded = _collapsed.contains(i);
    final text = Text.rich(
      TextSpan(children: [
        if (b.collapsible)
          TextSpan(text: folded ? '▸ ' : '▾ '),
        for (var j = 0; j < b.spans.length; j++) _span(context, i, j, b.spans[j]),
      ]),
      textAlign: _align(b.align),
      style: _textStyle(context, MicronStyle(fg: first.fg ?? hs.fg, bg: null))
          .copyWith(color: fg),
    );
    Widget bar = Container(
      width: double.infinity,
      color: bg,
      padding: EdgeInsets.symmetric(horizontal: 4 + ((b.depth - 1) * 2 * _charW)),
      child: text,
    );
    if (b.collapsible) {
      bar = InkWell(
        key: ValueKey('micron-fold-$i'),
        onTap: () => setState(() {
          if (!_collapsed.remove(i)) _collapsed.add(i);
        }),
        child: bar,
      );
    }
    return bar;
  }
}
