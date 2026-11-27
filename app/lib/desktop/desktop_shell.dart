import 'dart:async';

import 'close_policy.dart';

/// The main window, as the shell needs it (implemented by `window_manager`;
/// faked in tests).
abstract class WindowHost {
  /// Prepares the window and starts reporting close requests to [onClose].
  Future<void> init({required Future<void> Function() onClose});
  Future<bool> isVisible();
  Future<bool> isMinimized();
  Future<void> show();
  Future<void> hide();
  Future<void> minimize();
  Future<void> restore();
  Future<void> focus();
}

/// Text of the tray menu and tooltip.
class TrayLabels {
  const TrayLabels({
    required this.open,
    required this.quit,
    required this.tooltip,
  });

  final String open;
  final String quit;

  /// Tooltip for [unread] unread messages (0 for none).
  final String Function(int unread) tooltip;
}

/// The tray / menu-bar icon (implemented by `tray_manager`; faked in tests).
abstract class TrayHost {
  /// Creates the icon. Returns false when the platform has no tray to show it
  /// in. [onToggle] is the primary click (Windows), [onOpen] and [onQuit] the
  /// menu entries.
  Future<bool> create({
    required TrayLabels labels,
    required void Function() onToggle,
    required void Function() onOpen,
    required void Function() onQuit,
  });
  Future<void> setTooltip(String text);

  /// Dock badge with the unread count where the platform has one (macOS).
  Future<void> setBadge(int unread);
  Future<void> dispose();
}

/// Hide-to-tray, quit, and the one place that ends the process.
///
/// Platform specifics live behind [WindowHost] and [TrayHost]; this class is
/// the decision logic. On mobile ([desktop] false) it does nothing.
class DesktopShell {
  DesktopShell({
    required this.desktop,
    required this.window,
    required this.tray,
    required this.closeToTray,
    required this.shutdown,
    required this.exitProcess,
    required this.labels,
    this.shutdownTimeout = const Duration(seconds: 4),
  });

  final bool desktop;
  final WindowHost window;
  final TrayHost tray;

  /// The "Close to tray" setting (default on).
  final Future<bool> Function() closeToTray;

  /// Flushes and closes everything (database, node). Must be idempotent.
  final Future<void> Function() shutdown;

  /// Ends the process. Called after [shutdown].
  final Future<void> Function() exitProcess;

  /// Text for the tray; read lazily so a language change is picked up.
  final TrayLabels Function() labels;
  final Duration shutdownTimeout;

  bool _trayAvailable = false;
  bool _quitting = false;
  int _unread = 0;
  Future<void>? _quit;

  bool get trayAvailable => _trayAvailable;
  bool get quitting => _quitting;

  Future<void> start() async {
    if (!desktop) return;
    await window.init(onClose: onCloseRequested);
    try {
      _trayAvailable = await tray.create(
        labels: labels(),
        onToggle: () => unawaited(toggleWindow()),
        onOpen: () => unawaited(showWindow()),
        onQuit: () => unawaited(quit()),
      );
    } catch (_) {
      _trayAvailable = false;
    }
    if (_trayAvailable) await _applyUnread();
  }

  /// The window's close button / Alt+F4 / Cmd+W.
  Future<void> onCloseRequested() async {
    final action = decideClose(
      desktop: desktop,
      closeToTray: await closeToTray(),
      trayAvailable: _trayAvailable,
      quitRequested: _quitting,
    );
    switch (action) {
      case CloseAction.hide:
        await window.hide();
      case CloseAction.minimize:
        await window.minimize();
      case CloseAction.quit:
        await quit();
    }
  }

  /// Shows (and restores, focuses) the window.
  Future<void> showWindow() async {
    if (await window.isMinimized()) await window.restore();
    await window.show();
    await window.focus();
  }

  /// Tray primary click: hide a visible window, show a hidden or minimized one.
  Future<void> toggleWindow() async {
    final visible = await window.isVisible();
    final minimized = await window.isMinimized();
    if (visible && !minimized) {
      await window.hide();
    } else {
      await showWindow();
    }
  }

  /// Shows the window if it is hidden (macOS: Dock click / app activation).
  Future<void> showIfHidden() async {
    if (!desktop || _quitting) return;
    if (!await window.isVisible()) await showWindow();
  }

  /// Total unread messages; shown in the tray tooltip (and the dock badge).
  Future<void> setUnread(int n) async {
    if (n == _unread) return;
    _unread = n;
    if (_trayAvailable) await _applyUnread();
  }

  /// Re-applies the tooltip, e.g. after a language change.
  Future<void> refreshTooltip() async {
    if (_trayAvailable) await _applyUnread();
  }

  Future<void> _applyUnread() async {
    await tray.setTooltip(labels().tooltip(_unread));
    await tray.setBadge(_unread);
  }

  /// Real exit: the tray menu, the updater and "Close to tray" off all end up
  /// here. Never hides. A stuck [shutdown] cannot keep the process alive past
  /// [shutdownTimeout].
  Future<void> quit() => _quit ??= _doQuit();

  Future<void> _doQuit() async {
    _quitting = true;
    try {
      await shutdown().timeout(shutdownTimeout);
    } catch (_) {
      // exiting anyway
    }
    try {
      await tray.dispose();
    } catch (_) {}
    await exitProcess();
  }
}
