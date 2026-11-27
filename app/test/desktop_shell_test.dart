import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/desktop/close_policy.dart';
import 'package:kestrel/desktop/desktop_settings.dart';
import 'package:kestrel/desktop/desktop_shell.dart';
import 'package:kestrel/desktop/desktop_strings.dart';
import 'package:kestrel/update/update_service.dart';

class FakeWindow implements WindowHost {
  bool visible = true;
  bool minimized = false;
  bool focused = false;
  Future<void> Function()? onClose;
  final calls = <String>[];

  @override
  Future<void> init({required Future<void> Function() onClose}) async {
    this.onClose = onClose;
    calls.add('init');
  }

  @override
  Future<bool> isVisible() async => visible;
  @override
  Future<bool> isMinimized() async => minimized;
  @override
  Future<void> show() async {
    visible = true;
    calls.add('show');
  }

  @override
  Future<void> hide() async {
    visible = false;
    calls.add('hide');
  }

  @override
  Future<void> minimize() async {
    minimized = true;
    calls.add('minimize');
  }

  @override
  Future<void> restore() async {
    minimized = false;
    calls.add('restore');
  }

  @override
  Future<void> focus() async {
    focused = true;
    calls.add('focus');
  }
}

class FakeTray implements TrayHost {
  FakeTray({this.available = true});
  final bool available;
  String? tooltip;
  int badge = 0;
  bool disposed = false;
  void Function()? toggle;
  void Function()? open;
  void Function()? quit;

  @override
  Future<bool> create({
    required TrayLabels labels,
    required void Function() onToggle,
    required void Function() onOpen,
    required void Function() onQuit,
  }) async {
    toggle = onToggle;
    open = onOpen;
    quit = onQuit;
    return available;
  }

  @override
  Future<void> setTooltip(String text) async => tooltip = text;
  @override
  Future<void> setBadge(int unread) async => badge = unread;
  @override
  Future<void> dispose() async => disposed = true;
}

class Rig {
  Rig({bool desktop = true, this.closeToTray = true, bool trayAvailable = true})
    : window = FakeWindow(),
      tray = FakeTray(available: trayAvailable) {
    shell = DesktopShell(
      desktop: desktop,
      window: window,
      tray: tray,
      closeToTray: () async => closeToTray,
      shutdown: () async => events.add('shutdown'),
      exitProcess: () async => events.add('exit'),
      labels: () => TrayLabels(
        open: 'Open',
        quit: 'Quit',
        tooltip: (n) => n > 0 ? 'Kestrel $n' : 'Kestrel',
      ),
    );
  }

  final FakeWindow window;
  final FakeTray tray;
  late final DesktopShell shell;
  bool closeToTray;
  final events = <String>[];
}

void main() {
  group('decideClose', () {
    test('setting on + tray: hide', () {
      expect(
        decideClose(desktop: true, closeToTray: true, trayAvailable: true),
        CloseAction.hide,
      );
    });
    test('setting on, no tray: minimize, never hide', () {
      expect(
        decideClose(desktop: true, closeToTray: true, trayAvailable: false),
        CloseAction.minimize,
      );
    });
    test('setting off: quit', () {
      expect(
        decideClose(desktop: true, closeToTray: false, trayAvailable: true),
        CloseAction.quit,
      );
    });
    test('quit requested beats the setting', () {
      expect(
        decideClose(
          desktop: true,
          closeToTray: true,
          trayAvailable: true,
          quitRequested: true,
        ),
        CloseAction.quit,
      );
    });
    test('mobile is never intercepted', () {
      expect(
        decideClose(desktop: false, closeToTray: true, trayAvailable: true),
        CloseAction.quit,
      );
    });
  });

  test('close hides the window and keeps running', () async {
    final r = Rig();
    await r.shell.start();
    await r.window.onClose!();
    expect(r.window.visible, isFalse);
    expect(r.events, isEmpty);
    expect(r.tray.disposed, isFalse);
  });

  test('close with the setting off quits', () async {
    final r = Rig(closeToTray: false);
    await r.shell.start();
    await r.window.onClose!();
    expect(r.events, ['shutdown', 'exit']);
    expect(r.window.visible, isTrue);
  });

  test('setting is read at close time', () async {
    final r = Rig();
    await r.shell.start();
    r.closeToTray = false;
    await r.window.onClose!();
    expect(r.events, ['shutdown', 'exit']);
  });

  test('no tray: close minimizes', () async {
    final r = Rig(trayAvailable: false);
    await r.shell.start();
    expect(r.shell.trayAvailable, isFalse);
    await r.window.onClose!();
    expect(r.window.minimized, isTrue);
    expect(r.window.visible, isTrue);
    expect(r.events, isEmpty);
  });

  test('tray Quit really quits, even with the setting on', () async {
    final r = Rig();
    await r.shell.start();
    r.tray.quit!();
    await Future<void>.delayed(Duration.zero);
    await r.shell.quit();
    expect(r.events, ['shutdown', 'exit']);
    expect(r.tray.disposed, isTrue);
  });

  test('quit runs shutdown and exit once', () async {
    final r = Rig();
    await r.shell.start();
    await Future.wait([r.shell.quit(), r.shell.quit()]);
    expect(r.events, ['shutdown', 'exit']);
  });

  test('a close request while quitting does not hide', () async {
    final r = Rig();
    await r.shell.start();
    final q = r.shell.quit();
    await r.window.onClose!();
    await q;
    expect(r.window.calls, isNot(contains('hide')));
    expect(r.events, ['shutdown', 'exit']);
  });

  test('a stuck shutdown cannot block the exit', () async {
    final r = Rig();
    final shell = DesktopShell(
      desktop: true,
      window: r.window,
      tray: r.tray,
      closeToTray: () async => true,
      shutdown: () => Completer0().future,
      exitProcess: () async => r.events.add('exit'),
      labels: () => TrayLabels(open: 'o', quit: 'q', tooltip: (n) => 'k'),
      shutdownTimeout: const Duration(milliseconds: 20),
    );
    await shell.start();
    await shell.quit();
    expect(r.events, ['exit']);
  });

  test('the updater exits through quit(), not through hide', () async {
    final r = Rig();
    await r.shell.start();
    final svc = UpdateService.disabled();
    expect(svc.exitApp, isNotNull); // default is a plain exit; main injects:
    final injected = UpdateService(
      currentVersion: null,
      platform: null,
      tempDir: svc.tempDir,
      exitApp: () => r.shell.quit(),
    );
    injected.exitApp();
    await Future<void>.delayed(Duration.zero);
    expect(r.events, ['shutdown', 'exit']);
    expect(r.window.calls, isNot(contains('hide')));
  });

  test('tray click toggles, Open shows and restores', () async {
    final r = Rig();
    await r.shell.start();
    await r.shell.toggleWindow();
    expect(r.window.visible, isFalse);
    await r.shell.toggleWindow();
    expect(r.window.visible, isTrue);
    expect(r.window.focused, isTrue);
    r.window.minimized = true;
    await r.shell.toggleWindow(); // minimized counts as not shown
    expect(r.window.minimized, isFalse);
    r.window.visible = false;
    await r.shell.showWindow();
    expect(r.window.visible, isTrue);
  });

  test('unread count reaches tooltip and badge', () async {
    final r = Rig();
    await r.shell.start();
    expect(r.tray.tooltip, 'Kestrel');
    await r.shell.setUnread(3);
    expect(r.tray.tooltip, 'Kestrel 3');
    expect(r.tray.badge, 3);
    await r.shell.setUnread(0);
    expect(r.tray.tooltip, 'Kestrel');
  });

  test('showIfHidden (Dock click) reopens only a hidden window', () async {
    final r = Rig();
    await r.shell.start();
    await r.shell.showIfHidden();
    expect(r.window.calls, isNot(contains('show')));
    r.window.visible = false;
    await r.shell.showIfHidden();
    expect(r.window.visible, isTrue);
  });

  test('mobile: shell does nothing', () async {
    final r = Rig(desktop: false);
    await r.shell.start();
    expect(r.window.calls, isEmpty);
    expect(r.tray.toggle, isNull);
    await r.shell.setUnread(5);
    expect(r.tray.tooltip, isNull);
    await r.shell.showIfHidden();
    expect(r.window.calls, isEmpty);
  });

  test('Close to tray defaults on', () {
    expect(closeToTrayFrom(null), isTrue);
    expect(closeToTrayFrom('1'), isTrue);
    expect(closeToTrayFrom('0'), isFalse);
  });

  test('tray strings: uk default, en fallback, unread count', () {
    expect(desktopText('uk', 'tray_open'), 'Відкрити Kestrel');
    expect(desktopText('uk', 'tray_quit'), 'Вийти');
    expect(desktopText('en', 'tray_quit'), 'Quit');
    expect(desktopText('uk', 'close_to_tray'), 'Згортати в трей при закритті');
    expect(desktopText('en', 'tray_tooltip_unread', {'n': '4'}), contains('4'));
  });
}

/// A future that never completes.
class Completer0 {
  final future = Future<void>.delayed(const Duration(hours: 1));
}
