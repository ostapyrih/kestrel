import 'dart:convert';
import 'dart:typed_data';

import '../destination.dart';
import '../transport/transport.dart';
import '../util.dart';

/// Destination name of a NomadNet node.
const String nomadNodeApp = 'nomadnetwork';
const List<String> nomadNodeAspects = ['node'];

final Uint8List _nodeNameHash =
    Destination.nameHashFor(nomadNodeApp, nomadNodeAspects);

/// A NomadNet node learned from an announce.
class NomadNodeAnnounce {
  NomadNodeAnnounce({
    required this.hash,
    required this.name,
    required this.hops,
  });

  final Uint8List hash;

  /// The announced node name (UTF-8 `app_data`, sanitised); empty if none.
  final String name;
  final int hops;

  String get hashHex => toHex(hash);

  /// Returns the node if [e] is a `nomadnetwork.node` announce, else null.
  static NomadNodeAnnounce? fromEvent(AnnounceEvent e) {
    if (!_eq(e.announce.nameHash, _nodeNameHash)) return null;
    return NomadNodeAnnounce(
      hash: e.destinationHash,
      name: decodeNodeName(e.appData),
      hops: e.hops,
    );
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// Same ranges as nomadnet.util.STRIP_CONTROL_RE.
bool _isStripped(int c) =>
    (c <= 0x08) ||
    c == 0x0B ||
    c == 0x0C ||
    (c >= 0x0E && c <= 0x1F) ||
    (c >= 0x7F && c <= 0x9F) ||
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x202A && c <= 0x202E) ||
    (c >= 0x2060 && c <= 0x206F) ||
    c == 0xFEFF ||
    (c >= 0xFFF0 && c <= 0xFFF8);

/// Decodes the node name from announce app_data (`Node.announce`: the name
/// as UTF-8). Control and bidi characters are stripped, whitespace collapsed
/// and the result trimmed; undecodable bytes become U+FFFD.
String decodeNodeName(Uint8List? appData) {
  if (appData == null || appData.isEmpty) return '';
  final s = utf8.decode(appData, allowMalformed: true);
  final kept = String.fromCharCodes(s.runes.where((c) => !_isStripped(c)));
  return kept.replaceAll(RegExp(r'\s+'), ' ').trim();
}
