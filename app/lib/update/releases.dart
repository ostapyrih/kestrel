import 'release_key.dart';
import 'version.dart';

enum UpdatePlatform { windows, macos, linux, android, ios }

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.size = 0});

  final String name;
  final String url;
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });

  final String tag;
  final AppVersion version;
  final String body;
  final String htmlUrl;
  final List<ReleaseAsset> assets;

  ReleaseAsset? asset(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }
}

/// Only assets served from this repository's release downloads are trusted.
bool isTrustedDownloadUrl(String url) => url.startsWith(trustedDownloadPrefix);

/// Parses the GitHub `GET /releases` payload and keeps only published
/// (non-draft, non-prerelease) `app-v*` releases with a valid version.
/// `bridge-v*` and any other tags are ignored.
List<ReleaseInfo> parseAppReleases(Object? json) {
  if (json is! List) return const [];
  final out = <ReleaseInfo>[];
  for (final r in json) {
    if (r is! Map) continue;
    if (r['draft'] == true || r['prerelease'] == true) continue;
    final tag = r['tag_name'];
    if (tag is! String || !tag.startsWith('app-v')) continue;
    final version = AppVersion.tryParse(tag);
    if (version == null) continue;
    final assets = <ReleaseAsset>[];
    for (final a in (r['assets'] as List? ?? const [])) {
      if (a is! Map) continue;
      final name = a['name'], url = a['browser_download_url'];
      if (name is! String || url is! String || !isTrustedDownloadUrl(url)) {
        continue;
      }
      assets.add(
        ReleaseAsset(
          name: name,
          url: url,
          size: (a['size'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.add(
      ReleaseInfo(
        tag: tag,
        version: version,
        body: (r['body'] as String?) ?? '',
        htmlUrl: (r['html_url'] as String?) ?? '',
        assets: assets,
      ),
    );
  }
  return out;
}

/// The newest release strictly newer than [current], or null.
ReleaseInfo? newestUpdate(List<ReleaseInfo> releases, AppVersion current) {
  ReleaseInfo? best;
  for (final r in releases) {
    if (!(r.version > current)) continue;
    if (best == null || r.version > best.version) best = r;
  }
  return best;
}

/// The installable asset for [platform], or null when there is none (mobile, or
/// Linux outside an AppImage, which is updated manually).
ReleaseAsset? selectAsset(
  ReleaseInfo release,
  UpdatePlatform platform, {
  bool linuxAppImage = false,
}) {
  final RegExp re;
  switch (platform) {
    case UpdatePlatform.windows:
      re = RegExp(r'^kestrel-.+-windows-x64-setup\.exe$');
    case UpdatePlatform.macos:
      re = RegExp(r'^kestrel-.+-macos\.dmg$');
    case UpdatePlatform.linux:
      if (!linuxAppImage) return null;
      re = RegExp(r'^kestrel-.+-linux-x86_64\.AppImage$');
    case UpdatePlatform.android:
    case UpdatePlatform.ios:
      return null;
  }
  for (final a in release.assets) {
    if (re.hasMatch(a.name)) return a;
  }
  return null;
}

/// Release notes as plain text: drops the install boilerplate the release
/// workflow appends, markdown emphasis, link syntax and heading hashes.
String plainChangelog(String body) {
  var s = body.replaceAll('\r\n', '\n');
  for (final h in ['### How to install the IPA', '### Desktop install']) {
    final i = s.indexOf(h);
    if (i >= 0) s = s.substring(0, i);
  }
  s = s
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\* ', multiLine: true), '- ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}
