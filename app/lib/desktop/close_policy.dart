/// What the main window's close request turns into.
enum CloseAction {
  /// Hide the window; the app keeps running behind the tray icon.
  hide,

  /// Minimize the window (no tray to bring it back from, so never hide it).
  minimize,

  /// Really exit: flush, close the database, end the process.
  quit,
}

/// Decides what a close request on the main window does.
///
/// * [desktop] is false on mobile: nothing is intercepted, closing means exit.
/// * [quitRequested] is true when the user (tray menu, updater, shutdown) has
///   asked to quit: that always wins over the setting.
/// * [closeToTray] is the "Close to tray" setting.
/// * [trayAvailable] is false when the platform has no tray to restore the
///   window from (Linux desktops without a StatusNotifier host).
CloseAction decideClose({
  required bool desktop,
  required bool closeToTray,
  required bool trayAvailable,
  bool quitRequested = false,
}) {
  if (quitRequested || !desktop || !closeToTray) return CloseAction.quit;
  return trayAvailable ? CloseAction.hide : CloseAction.minimize;
}
