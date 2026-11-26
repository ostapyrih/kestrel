/// A parsed `MAJOR.MINOR.PATCH[-pre][+build]` version.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.pre = const []]);

  final int major;
  final int minor;
  final int patch;

  /// Pre-release identifiers (empty for a release).
  final List<String> pre;

  static final _re = RegExp(
    r'^(?:app-)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Accepts `0.5.0`, `0.5.0+5`, `v0.5.0`, `app-v0.5.0`, `1.0.0-rc.1`.
  static AppVersion? tryParse(String s) {
    final m = _re.firstMatch(s.trim());
    if (m == null) return null;
    return AppVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4] == null ? const [] : m[4]!.split('.'),
    );
  }

  @override
  int compareTo(AppVersion o) {
    for (final (a, b) in [
      (major, o.major),
      (minor, o.minor),
      (patch, o.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    // A release is newer than any of its pre-releases.
    if (pre.isEmpty || o.pre.isEmpty) {
      return pre.isEmpty == o.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final a = pre[i], b = o.pre[i];
      final an = int.tryParse(a), bn = int.tryParse(b);
      final c = an != null && bn != null
          ? an.compareTo(bn)
          : an != null
          ? -1
          : bn != null
          ? 1
          : a.compareTo(b);
      if (c != 0) return c;
    }
    return pre.length.compareTo(o.pre.length);
  }

  bool operator >(AppVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'));

  @override
  String toString() =>
      '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}
