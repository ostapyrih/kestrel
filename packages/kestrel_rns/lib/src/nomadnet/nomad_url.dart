import 'dart:typed_data';

import '../util.dart';

/// Default page path of a NomadNet node (`Browser.DEFAULT_PATH`).
const String nomadDefaultPath = '/page/index.mu';

/// Length of a destination hash in hex characters.
const int nomadHashHexLength = 32;

/// A NomadNet address: `<32 hex>:<path>` plus optional link variables
/// (`` ` ``-suffix, `a=b|c=d`), as parsed by `Browser.retrieve_url`.
class NomadUrl {
  NomadUrl(this.hash, this.path, {Map<String, String>? vars})
      : vars = vars ?? const {};

  /// Destination hash of the node (16 bytes).
  final Uint8List hash;

  /// Request path, e.g. `/page/index.mu` or `/file/x.bin`.
  final String path;

  /// Link variables without the `var_` prefix, in order.
  final Map<String, String> vars;

  String get hashHex => toHex(hash);

  bool get isFile => path.startsWith('/file/');

  /// `<hash>:<path>` (without variables).
  String get location => '$hashHex:$path';

  /// Canonical text form including variables (`Browser.current_url`).
  String get text {
    if (vars.isEmpty) return location;
    return '$location`${vars.entries.map((e) => '${e.key}=${e.value}').join('|')}';
  }

  /// Request data for the variables only (no form fields).
  Map<String, String>? get requestData =>
      vars.isEmpty ? null : {for (final e in vars.entries) 'var_${e.key}': e.value};

  NomadUrl withVars(Map<String, String> v) => NomadUrl(hash, path, vars: v);

  @override
  bool operator ==(Object other) =>
      other is NomadUrl && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;

  /// Parses [input] like NomadNet's `Browser.retrieve_url`: `hash`,
  /// `hash:path`, or `:path` relative to [current] (a node hash). Throws
  /// [FormatException] when malformed.
  static NomadUrl parse(String input, {Uint8List? current}) {
    var url = input.trim();
    Map<String, String> vars = {};
    final parts = url.split('`');
    if (parts.length > 2) throw const FormatException('Malformed URL');
    if (parts.length == 2) {
      url = parts[0];
      vars = _parseVars(parts[1]);
    }
    final comps = url.split(':');
    Uint8List hash;
    String path;
    if (comps.length == 1) {
      hash = _hash(comps[0]);
      path = nomadDefaultPath;
    } else if (comps.length == 2) {
      if (comps[0].length == nomadHashHexLength) {
        hash = _hash(comps[0]);
        path = comps[1].isEmpty ? nomadDefaultPath : comps[1];
      } else if (comps[0].isEmpty && current != null) {
        hash = current;
        path = comps[1].isEmpty ? nomadDefaultPath : comps[1];
      } else {
        throw const FormatException('Malformed URL');
      }
    } else {
      throw const FormatException('Malformed URL');
    }
    return NomadUrl(hash, path, vars: vars);
  }

  /// Like [parse] but returns null instead of throwing.
  static NomadUrl? tryParse(String input, {Uint8List? current}) {
    try {
      return parse(input, current: current);
    } on FormatException {
      return null;
    }
  }

  static Uint8List _hash(String hex) {
    if (hex.length != nomadHashHexLength ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      throw const FormatException('Malformed URL');
    }
    return fromHex(hex);
  }

  /// `a=b|c=d` -> `{a: b, c: d}`; entries that are not exactly `k=v` are
  /// skipped, as NomadNet does.
  static Map<String, String> _parseVars(String s) {
    final out = <String, String>{};
    if (s.isEmpty) return out;
    for (final e in s.split('|')) {
      final c = e.split('=');
      if (c.length == 2) out[c[0]] = c[1];
    }
    return out;
  }
}

/// What a link target in a Micron page points at.
enum NomadLinkKind { anchor, node, lxmf, rrc, partial, unknown }

/// A parsed Micron link target (`Browser.handle_link`).
class NomadLink {
  NomadLink._(this.kind, {this.url, this.lxmfHash, this.anchor, this.raw = ''});

  final NomadLinkKind kind;

  /// For [NomadLinkKind.node]: the (possibly relative) node URL text; resolve
  /// it with [NomadUrl.parse] against the current node.
  final String? url;

  /// For [NomadLinkKind.lxmf]: the address, lower-case hex (32 chars).
  final String? lxmfHash;

  /// For [NomadLinkKind.anchor]: the anchor name (without `#`).
  final String? anchor;
  final String raw;

  /// Classifies [target] like `Browser.handle_link`: `#anchor`, `rrc://...`,
  /// `type@target` (`nnn`, `lxmf`, `rrc` shorthands), `p:` partials, else a
  /// node URL.
  static NomadLink parse(String target) {
    if (target.startsWith('#')) {
      return NomadLink._(NomadLinkKind.anchor,
          anchor: target.substring(1), raw: target);
    }
    if (target.startsWith('rrc://')) {
      return NomadLink._(NomadLinkKind.rrc, raw: target);
    }
    final comps = target.split('@');
    if (comps.length == 2) {
      final type = switch (comps[0]) {
        'nnn' => 'nomadnetwork.node',
        'lxmf' => 'lxmf.delivery',
        'rrc' => 'rrc.hub.session',
        final t => t,
      };
      switch (type) {
        case 'nomadnetwork.node':
          return NomadLink._(NomadLinkKind.node, url: comps[1], raw: target);
        case 'lxmf.delivery':
          final h = comps[1].trim().toLowerCase();
          if (RegExp(r'^[0-9a-f]{32}$').hasMatch(h)) {
            return NomadLink._(NomadLinkKind.lxmf, lxmfHash: h, raw: target);
          }
          return NomadLink._(NomadLinkKind.unknown, raw: target);
        case 'rrc.hub.session':
          return NomadLink._(NomadLinkKind.rrc, raw: target);
        default:
          return NomadLink._(NomadLinkKind.unknown, raw: target);
      }
    }
    if (target.startsWith('p:')) {
      return NomadLink._(NomadLinkKind.partial, raw: target);
    }
    if (comps.length == 1) {
      return NomadLink._(NomadLinkKind.node, url: comps[0], raw: target);
    }
    return NomadLink._(NomadLinkKind.unknown, raw: target);
  }
}

/// Builds the request data map NomadNet sends for a link or form submit
/// (`Browser.handle_link`).
///
/// [linkFields] is the link's field list (`name`, `k=v`, `*`): `k=v` entries
/// become `var_k`, plain names (or all of [fields] when `*` is present)
/// become `field_<name>` with the value from [fields]. Returns null when
/// there is nothing to send (NomadNet then sends no data).
///
/// [fields] maps each form field name to its current value; checkbox groups
/// pass their selected values joined with `,`, unselected checkboxes and
/// radio groups with no selection are simply absent.
Map<String, String>? buildNomadRequestData(
  List<String>? linkFields,
  Map<String, String> fields,
) {
  if (linkFields == null) return null;
  final data = <String, String>{};
  final all = linkFields.contains('*');
  final names = <String>[];
  for (final e in linkFields) {
    if (e.contains('=')) {
      final c = e.split('=');
      if (c.length == 2) data['var_${c[0]}'] = c[1];
    } else {
      names.add(e);
    }
  }
  for (final k in fields.keys) {
    if (all || names.contains(k)) data['field_$k'] = fields[k]!;
  }
  return data;
}
