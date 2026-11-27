// The legacy window_manager API is the compat layer that keeps the 0.5.x
// semantics (set-prevent-close, hidden-window lookup on Windows).
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart' show Application;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/legacy.dart' as wm;

import 'desktop_shell.dart';

/// [WindowHost] on `window_manager`.
class NativeWindowHost extends wm.WindowListener implements WindowHost {
  Future<void> Function()? _onClose;

  @override
  Future<void> init({required Future<void> Function() onClose}) async {
    _onClose = onClose;
    await wm.windowManager.ensureInitialized();
    wm.windowManager.addListener(this);
    // every close request is reported to Dart and decided there
    await wm.windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() => unawaited(_onClose?.call());

  @override
  Future<bool> isVisible() => wm.windowManager.isVisible();
  @override
  Future<bool> isMinimized() => wm.windowManager.isMinimized();
  @override
  Future<void> show() => wm.windowManager.show();
  @override
  Future<void> hide() => wm.windowManager.hide();
  @override
  Future<void> minimize() => wm.windowManager.minimize();
  @override
  Future<void> restore() => wm.windowManager.restore();
  @override
  Future<void> focus() => wm.windowManager.focus();
}

/// [TrayHost] on `tray_manager`.
class NativeTrayHost implements TrayHost {
  TrayIcon? _icon;
  final _keepAlive = <Object>[];

  @override
  Future<bool> create({
    required TrayLabels labels,
    required void Function() onToggle,
    required void Function() onOpen,
    required void Function() onQuit,
  }) async {
    if (Platform.isLinux && !await _linuxTrayHostPresent()) return false;
    final icon = TrayIcon.create();
    if (icon == null) return false;
    final image = ImageAsset.fromAsset(
      Platform.isMacOS
          ? 'assets/tray/tray_template.png'
          : Platform.isWindows
          ? 'assets/tray/tray.ico'
          : 'assets/tray/tray.png',
    );
    if (image == null) {
      icon.dispose();
      return false;
    }
    icon.icon = image;
    // macOS: a black silhouette the menu bar tints for light/dark
    if (Platform.isMacOS) icon.isIconTemplate = true;
    icon.setTooltip(labels.tooltip(0));

    final menu = Menu.create();
    final open = MenuItem.createWithLabelAndType(
      labels.open,
      MenuItemType.normal,
    );
    final quit = MenuItem.createWithLabelAndType(
      labels.quit,
      MenuItemType.normal,
    );
    if (menu == null || open == null || quit == null) {
      icon.dispose();
      return false;
    }
    open.addListener((e) {
      if (e is MenuItemClickedEvent) onOpen();
    });
    quit.addListener((e) {
      if (e is MenuItemClickedEvent) onQuit();
    });
    menu
      ..addItem(open)
      ..addSeparator()
      ..addItem(quit);
    icon.setContextMenu(menu);
    if (Platform.isMacOS) {
      // menu bar convention: a click opens the menu
      icon.setContextMenuTrigger(ContextMenuTrigger.clicked);
    } else {
      icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      // Windows: left click toggles the window. Linux panels report no clicks
      // (they open the menu themselves, whose first entry opens the window).
      icon.addListener((e) {
        if (e is TrayIconClickedEvent) onToggle();
      });
    }
    icon.setVisible(true);
    _icon = icon;
    _keepAlive.addAll([menu, open, quit]); // the wrappers must outlive the icon
    return true;
  }

  @override
  Future<void> setTooltip(String text) async => _icon?.setTooltip(text);

  @override
  Future<void> setBadge(int unread) async {
    // dock badge on macOS only; elsewhere the tooltip carries the count
    if (!Platform.isMacOS) return;
    try {
      Application.instance.setBadgeLabel(unread > 0 ? '$unread' : '');
    } catch (e) {
      debugPrint('badge: $e');
    }
  }

  @override
  Future<void> dispose() async {
    _icon?.setVisible(false);
    _icon?.dispose();
    _icon = null;
    _keepAlive.clear();
  }
}

/// Linux: the tray is a StatusNotifierItem, which needs a host on the session
/// bus (KDE, GNOME with the AppIndicator extension, ...). Without one the icon
/// would be invisible and a hidden window unrecoverable, so the caller falls
/// back to minimizing. If the check itself cannot run, assume no tray (the
/// safe side).
Future<bool> _linuxTrayHostPresent() async {
  try {
    final r = await Process.run('dbus-send', const [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.DBus',
      '/org/freedesktop/DBus',
      'org.freedesktop.DBus.NameHasOwner',
      'string:org.kde.StatusNotifierWatcher',
    ]).timeout(const Duration(seconds: 2));
    return r.exitCode == 0 && '${r.stdout}'.contains('boolean true');
  } catch (_) {
    return false;
  }
}
