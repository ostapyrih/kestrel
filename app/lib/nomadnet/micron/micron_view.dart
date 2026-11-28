import 'package:flutter/gestures.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';

import 'micron_layout.dart';
import 'micron_parser.dart';

/// Called when a link is activated: the raw [target] and the request data
/// NomadNet would send (`var_*` / `field_*`), null for a plain link.
typedef MicronLinkTap = void Function(
  String target,
  Map<String, String>? requestData,
);

/// Pinch-zoom limits (multiplier on top of fit-to-width).
const micronMinZoom = 0.5;
const micronMaxZoom = 4.0;

/// Programming ligatures (`->`, `!=`, `^=`...) off: a terminal draws each
/// character separately.
const _noLigatures = [
  FontFeature.disable('calt'),
  FontFeature.disable('liga'),
];

/// Renders a [MicronDocument]: monospace, selectable, theme aware, with
/// working links, input fields, checkboxes, radio buttons and foldable
/// headings. Nothing is loaded from anywhere: links only call [onLink].
///
/// Micron is a fixed-width, terminal style format, so lines that carry layout
/// (art, tables, aligned columns, background colour) are never soft wrapped:
/// the page font shrinks to fit the widest one (down to
/// [micronMinFontSize]); below that the page scrolls horizontally as one
/// block. Ordinary prose wraps at the viewport width. See
/// [classifyMicronBlock].
class MicronView extends StatefulWidget {
  const MicronView({
    super.key,
    required this.document,
    required this.onLink,
    this.scrollToAnchor,
    this.controller,
    this.fontSize = 14,
    this.padding = const EdgeInsets.all(12),
    this.zoom = 1,
    this.onZoomChanged,
    this.wrapAll = false,
  });

  final MicronDocument document;
  final MicronLinkTap onLink;

  /// Scrolls to this anchor once after build (`var_anchor`).
  final String? scrollToAnchor;
  final ScrollController? controller;
  final double fontSize;
  final EdgeInsets padding;

  /// Pinch / menu zoom multiplier applied on top of fit-to-width.
  final double zoom;

  /// Called when the user changes the zoom (pinch end, double-tap reset).
  final ValueChanged<double>? onZoomChanged;

  /// Wrap every line, structural ones included (no fit, no horizontal scroll).
  final bool wrapAll;

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
  final _infos = <MicronLineInfo>[];
  int _columns = 0;
  late double _zoom = widget.zoom;
  double _zoomStart = 1;
  double _fs = 14;
  MicronFit _fit = const MicronFit(
    fontSize: 14,
    contentWidth: 0,
    scrolls: false,
  );
  final _hScroll = ScrollController();

  /// Font size the page is currently drawn with (logical px).
  double get effectiveFontSize => _fs;

  /// True when the page block is wider than the viewport.
  bool get scrollsHorizontally => _fit.scrolls;

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
    if (oldWidget.zoom != widget.zoom) _zoom = widget.zoom;
    if (!identical(oldWidget.document, widget.document)) {
      _disposeState();
      _init();
      _scheduleAnchor();
    }
  }

  void _init() {
    final blocks = widget.document.blocks;
    _infos
      ..clear()
      ..addAll([
        for (final b in blocks)
          classifyMicronBlock(b, pageBg: widget.document.background),
      ]);
    _columns = widestStructuralColumns(widget.document);
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
    _hScroll.dispose();
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
        (idx * _fs * 1.5).clamp(0, _scroll.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => ensure());
    }
  }

  /// End (exclusive) of the section folded under heading [i]: up to the
  /// first row of a lower level or the next heading of the same or a higher
  /// level (`Browser.init_folds`).
  int _sectionEnd(int i) {
    final blocks = widget.document.blocks;
    final depth = blocks[i].depth;
    for (var k = i + 1; k < blocks.length; k++) {
      final b = blocks[k];
      if (b.depth < depth ||
          (b.kind == MicronBlockKind.heading && b.depth <= depth)) {
        return k;
      }
    }
    return blocks.length;
  }

  void _revealIndex(int idx) {
    // unfold headings whose folded section contains [idx]
    var changed = false;
    for (final h in [..._collapsed]) {
      if (h < idx && idx < _sectionEnd(h)) {
        _collapsed.remove(h);
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

  double get _charW => _fs * micronCharEm;

  List<int> _visible() {
    final blocks = widget.document.blocks;
    final out = <int>[];
    var i = 0;
    while (i < blocks.length) {
      out.add(i);
      final b = blocks[i];
      if (b.kind == MicronBlockKind.heading &&
          b.collapsible &&
          _collapsed.contains(i)) {
        i = _sectionEnd(i);
      } else {
        i++;
      }
    }
    return out;
  }

  Offset? _downAt;
  Duration _downTime = Duration.zero;
  Offset? _lastTapAt;
  Duration _lastTapTime = Duration.zero;

  void _pointerUp(PointerUpEvent e) {
    final down = _downAt;
    if (down == null) return;
    _downAt = null;
    const slop = 24.0;
    const gap = Duration(milliseconds: 300);
    if ((e.position - down).distance > slop || e.timeStamp - _downTime > gap) {
      _lastTapAt = null;
      return;
    }
    final last = _lastTapAt;
    if (last != null &&
        e.timeStamp - _lastTapTime < gap &&
        (e.position - last).distance < slop * 2) {
      _lastTapAt = null;
      _setZoom(1);
    } else {
      _lastTapAt = e.position;
      _lastTapTime = e.timeStamp;
    }
  }

  bool _nowrap(int i) => !widget.wrapAll && _infos[i].structural;

  void _setZoom(double z, {bool notify = true}) {
    z = z.clamp(micronMinZoom, micronMaxZoom);
    setState(() => _zoom = z);
    if (notify) widget.onZoomChanged?.call(z);
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final bg = doc.background != null ? Color(0xFF000000 | doc.background!) : null;
    final visible = _visible();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final child = LayoutBuilder(
      builder: (context, box) {
        final viewport = box.maxWidth.isFinite ? box.maxWidth : 400.0;
        final pad = widget.padding.horizontal;
        if (widget.wrapAll) {
          _fit = MicronFit(
            fontSize: widget.fontSize * _zoom,
            contentWidth: viewport,
            scrolls: false,
          );
        } else {
          _fit = fitMicron(
            viewport: viewport,
            columns: _columns,
            baseFont: widget.fontSize,
            zoom: _zoom,
            dpr: dpr,
            padding: pad,
          );
        }
        _fs = _fit.fontSize;
        final proseW = (viewport - pad).clamp(1.0, double.infinity);
        Widget list = ListView.builder(
          controller: _scroll,
          padding: widget.padding,
          itemCount: visible.length,
          itemBuilder: (context, n) {
            final i = visible[n];
            return KeyedSubtree(
              key: _keys.putIfAbsent(i, GlobalKey.new),
              child: _block(context, i, doc.blocks[i], proseW),
            );
          },
        );
        if (_fit.scrolls) {
          list = SingleChildScrollView(
            key: const ValueKey('micron-hscroll'),
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _fit.contentWidth,
              height: box.maxHeight.isFinite ? box.maxHeight : null,
              child: list,
            ),
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: (_) => _zoomStart = _zoom,
          onScaleUpdate: (d) {
            if (d.pointerCount < 2) return;
            _setZoom(_zoomStart * d.scale, notify: false);
          },
          onScaleEnd: (_) {
            if (_zoom != widget.zoom) widget.onZoomChanged?.call(_zoom);
          },
          // Double-tap is detected from raw pointers: a DoubleTap recognizer
          // would sit in the gesture arena and delay every link/checkbox tap.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              _downAt = e.position;
              _downTime = e.timeStamp;
            },
            onPointerUp: _pointerUp,
            child: list,
          ),
        );
      },
    );
    final area = SelectionArea(child: child);
    return bg == null ? area : ColoredBox(color: bg, child: area);
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

  TextStyle _textStyle(
    BuildContext context,
    MicronStyle s, {
    bool link = false,
    bool solid = false,
  }) {
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
      fontFamily: micronFontFamily,
      fontFamilyFallback: micronFontFallback,
      fontSize: _fs,
      // Micron is a character grid: every glyph advances exactly
      // [micronCharEm]. Do not inherit the theme's tracking (Material 3
      // body text has +0.25 px per glyph, which skews every row of a
      // colour-block map) and keep programming ligatures off.
      letterSpacing: 0,
      wordSpacing: 0,
      fontFeatures: _noLigatures,
      height: solid ? 1.0 : 1.25,
      leadingDistribution: TextLeadingDistribution.even,
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

  InlineSpan _span(
    BuildContext context,
    int bi,
    int si,
    MicronSpan s, {
    bool solid = false,
  }) {
    switch (s) {
      case MicronText t:
        return TextSpan(
          text: t.text,
          style: _textStyle(context, t.style, solid: solid),
        );
      case MicronLinkSpan l:
        final rec = _recognizers.putIfAbsent(
          (bi, si),
          () => TapGestureRecognizer(),
        )..onTap = () => _tapLink(l);
        return TextSpan(
          text: l.label,
          style: _textStyle(context, l.style, link: true, solid: solid),
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
            size: _fs + 6,
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

  Widget _prose(double width, Widget child) => _fit.scrolls
      ? Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        )
      : child;

  Widget _block(BuildContext context, int i, MicronBlock b, double proseW) {
    switch (b.kind) {
      case MicronBlockKind.blank:
        return SizedBox(height: _fs * 1.25);
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
                style: _textStyle(context, const MicronStyle(), solid: true),
              );
            },
          ),
        );
      case MicronBlockKind.heading:
        return _prose(proseW, _heading(context, i, b));
      case MicronBlockKind.text:
        final line = _line(context, i, b);
        return _nowrap(i) ? _indent(b, line) : _prose(proseW, _indent(b, line));
    }
  }

  Widget _line(BuildContext context, int i, MicronBlock b) {
    final solid = _infos[i].solid;
    if (!b.hasInputs) {
      return SizedBox(
        width: double.infinity,
        child: Text.rich(
          TextSpan(children: [
            for (var j = 0; j < b.spans.length; j++)
              _span(context, i, j, b.spans[j], solid: solid),
          ]),
          textAlign: _align(b.align),
          softWrap: !_nowrap(i),
          style: _textStyle(context, const MicronStyle(), solid: solid),
          strutStyle: solid
              ? StrutStyle(
                  fontFamily: micronFontFamily,
                  fontFamilyFallback: micronFontFallback,
                  fontSize: _fs,
                  height: 1.0,
                  leading: 0,
                  forceStrutHeight: true,
                )
              : null,
          textHeightBehavior: TextHeightBehavior(
            applyHeightToFirstAscent: !solid,
            applyHeightToLastDescent: !solid,
            leadingDistribution: TextLeadingDistribution.even,
          ),
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
