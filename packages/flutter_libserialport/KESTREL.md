# Vendored flutter_libserialport 0.6.0

Upstream: https://github.com/jpnurmi/flutter_libserialport (MIT; bundles libserialport, LGPL-3.0+).

Why vendored: the upstream Android build script still uses `jcenter()` (removed from Gradle 9), which
breaks `flutter build apk` for the whole app. Kestrel only uses the plugin on Windows, macOS and Linux (USB
RNode), so this copy drops the `android/` folder and the Android platform entry. Nothing else is changed.
Drop this copy when upstream fixes its Android build.
