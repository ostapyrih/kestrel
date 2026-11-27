import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'micron_parser.dart';

/// Bundled monospace page font (JetBrains Mono, SIL OFL 1.1).
const micronFontFamily = 'JetBrainsMono';
const micronFontFallback = ['Consolas', 'Menlo', 'Roboto Mono', 'monospace'];

/// Advance of one cell in em (JetBrains Mono: 600/1000).
const micronCharEm = 0.6;

/// Smallest page font fit-to-width may shrink to (logical px).
const micronMinFontSize = 8.0;

/// Registers the bundled font's licence for `showLicensePage`.
void registerMicronFontLicense() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['JetBrains Mono'], text);
  });
}

/// Width of [rune] in terminal cells: 0 for combining marks, 2 for East Asian
/// wide and emoji, else 1.
int runeColumns(int r) {
  if (r == 0) return 0;
  if ((r >= 0x0300 && r <= 0x036F) ||
      (r >= 0x1AB0 && r <= 0x1AFF) ||
      (r >= 0x1DC0 && r <= 0x1DFF) ||
      (r >= 0x20D0 && r <= 0x20FF) ||
      (r >= 0xFE00 && r <= 0xFE0F) ||
      (r >= 0xFE20 && r <= 0xFE2F) ||
      r == 0x200B ||
      r == 0x200C ||
      r == 0x200D) {
    return 0;
  }
  if ((r >= 0x1100 && r <= 0x115F) ||
      (r >= 0x2E80 && r <= 0x303E) ||
      (r >= 0x3041 && r <= 0x33FF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0xA000 && r <= 0xA4CF) ||
      (r >= 0xAC00 && r <= 0xD7A3) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0xFE30 && r <= 0xFE6F) ||
      (r >= 0xFF00 && r <= 0xFF60) ||
      (r >= 0xFFE0 && r <= 0xFFE6) ||
      (r >= 0x1F300 && r <= 0x1F64F) ||
      (r >= 0x1F900 && r <= 0x1F9FF) ||
      (r >= 0x20000 && r <= 0x3FFFD)) {
    return 2;
  }
  return 1;
}

/// Width of [s] in monospace columns (wide characters count 2).
int displayColumns(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += runeColumns(r);
  }
  return n;
}

bool _isBoxOrBlock(int r) =>
    (r >= 0x2500 && r <= 0x259F) || (r >= 0x2800 && r <= 0x28FF);

bool _isLetterOrDigit(int r) {
  if (r >= 0x30 && r <= 0x39) return true;
  if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) return true;
  if (r < 0x80) return false;
  // Latin-1 letters, Latin Extended, Greek, Cyrillic, CJK and friends
  if (r == 0xD7 || r == 0xF7) return false;
  return (r >= 0xC0 && r <= 0x24F) ||
      (r >= 0x370 && r <= 0x52F) ||
      (r >= 0x1E00 && r <= 0x1FFF) ||
      (r >= 0x3040 && r <= 0xD7FF) ||
      r >= 0x10000;
}

/// Punctuation that ordinary prose is full of (not "drawing").
const _proseMarks = ',;:!?\'"\u2019\u00AB\u00BB\u2014\u2013\u2026';

bool _isDrawing(int r) {
  if (_isLetterOrDigit(r)) return false;
  if (r == 0x20 || r == 0xA0) return false;
  if (r < 0x80 && _proseMarks.contains(String.fromCharCode(r))) return false;
  if (r >= 0x80 && _proseMarks.contains(String.fromCharCode(r))) return false;
  return true;
}

/// Layout facts about one line.
class MicronLineInfo {
  const MicronLineInfo({
    required this.structural,
    required this.solid,
    required this.columns,
  });

  /// Never soft wrapped (unless the user turned "wrap long lines" on).
  final bool structural;

  /// Drawn with line height 1.0 so consecutive rows touch.
  final bool solid;

  /// Width in monospace columns, indentation included.
  final int columns;
}

/// Classifies [b]. A line is prose (may wrap) only when it is ordinary text:
/// no background colour, not literal, no internal run of 2+ spaces and not
/// mostly drawing characters. [pageBg] is the page's `#!bg=` (not a "line
/// background").
MicronLineInfo classifyMicronBlock(MicronBlock b, {int? pageBg}) {
  final text = b.plainText;
  final cols = displayColumns(text) + (b.depth > 1 ? (b.depth - 1) * 4 : 0);
  if (b.kind != MicronBlockKind.text) {
    return MicronLineInfo(structural: false, solid: false, columns: 0);
  }
  if (b.hasInputs) {
    // forms flow in a Wrap; never forced wide
    return MicronLineInfo(structural: false, solid: false, columns: 0);
  }
  var hasBg = false;
  for (final s in b.spans) {
    if (s.style.bg != null && s.style.bg != pageBg) hasBg = true;
  }
  var hasBox = false;
  var nonSpace = 0;
  var drawing = 0;
  for (final r in text.runes) {
    if (r == 0x20 || r == 0xA0 || r == 0x09) continue;
    nonSpace++;
    if (_isBoxOrBlock(r)) hasBox = true;
    if (_isDrawing(r)) drawing++;
  }
  final mostlyDrawing = nonSpace > 0 && drawing * 2 > nonSpace;
  final trimmed = text.trim();
  // two spaces after a sentence end are prose style, not alignment
  final alignedSpaces = trimmed.contains(
    RegExp(r'(?<![.!?:])[ \u00A0]{2}|[ \u00A0]{3}|\t'),
  );
  final structural =
      b.literal || hasBg || alignedSpaces || mostlyDrawing || hasBox;
  return MicronLineInfo(
    structural: structural,
    solid: hasBg || hasBox || mostlyDrawing,
    columns: cols,
  );
}

/// Widest non-wrapping line of [doc], in columns (0 when everything wraps).
int widestStructuralColumns(MicronDocument doc) {
  var w = 0;
  for (final b in doc.blocks) {
    final i = classifyMicronBlock(b, pageBg: doc.background);
    if (i.structural && i.columns > w) w = i.columns;
  }
  return w;
}

/// Result of fitting a page into a viewport.
@immutable
class MicronFit {
  const MicronFit({
    required this.fontSize,
    required this.contentWidth,
    required this.scrolls,
  });

  /// Font size to render with (logical px).
  final double fontSize;

  /// Width of the whole page block (>= viewport width).
  final double contentWidth;

  /// True when the page block is wider than the viewport.
  final bool scrolls;
}

/// Fit-to-width: shrinks [baseFont] so [columns] cells fit [viewport], down
/// to [micronMinFontSize]; never upscales beyond [baseFont]. [zoom]
/// multiplies the fitted size (pinch). [dpr] snaps the size to whole device
/// pixels so rows of background colour have no seams.
MicronFit fitMicron({
  required double viewport,
  required int columns,
  required double baseFont,
  double zoom = 1,
  double dpr = 1,
  double padding = 0,
}) {
  double snap(double f) {
    final s = (f * dpr).floorToDouble() / dpr;
    return s <= 0 ? f : s;
  }

  final avail = (viewport - padding).clamp(1.0, double.infinity);
  var font = baseFont;
  if (columns > 0) {
    final fit = avail / (columns * micronCharEm);
    if (fit < font) font = fit;
    final minF = baseFont < micronMinFontSize ? baseFont : micronMinFontSize;
    if (font < minF) font = minF;
  }
  font = snap(font * zoom);
  final need = columns * micronCharEm * font + padding;
  final scrolls = columns > 0 && need > viewport + 0.01;
  return MicronFit(
    fontSize: font,
    contentWidth: scrolls ? need : viewport,
    scrolls: scrolls,
  );
}
