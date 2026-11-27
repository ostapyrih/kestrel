import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';

/// Tray and "Close to tray" strings (Ukrainian default, English fallback),
/// kept apart from the main l10n tables like the updater's.
const desktopStringsUk = <String, String>{
  'tray_open': 'Відкрити Kestrel',
  'tray_quit': 'Вийти',
  'tray_tooltip': 'Kestrel',
  'tray_tooltip_unread': 'Kestrel — непрочитаних: {n}',
  'close_to_tray': 'Згортати в трей при закритті',
  'close_to_tray_hint': 'Закриття вікна лишає Kestrel працювати у фоні; вийти можна з меню іконки в треї.',
};

const desktopStringsEn = <String, String>{
  'tray_open': 'Open Kestrel',
  'tray_quit': 'Quit',
  'tray_tooltip': 'Kestrel',
  'tray_tooltip_unread': 'Kestrel — {n} unread',
  'close_to_tray': 'Close to tray',
  'close_to_tray_hint': 'Closing the window keeps Kestrel running in the background; quit from the tray icon menu.',
};

String desktopText(
  String lang,
  String key, [
  Map<String, String> args = const {},
]) {
  var s =
      (lang == 'en' ? desktopStringsEn[key] : desktopStringsUk[key]) ??
      desktopStringsUk[key] ??
      key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

/// [desktopText] for the language of [context].
String dt(
  BuildContext context,
  String key, [
  Map<String, String> args = const {},
]) => desktopText(Strings.of(context).lang, key, args);

/// UI language for code without a [BuildContext] (the tray): the device
/// language decides, as for the app itself.
String deviceLang() =>
    Strings.resolve(
          WidgetsBinding.instance.platformDispatcher.locale,
          Strings.supportedLocales,
        ).languageCode ==
        'en'
    ? 'en'
    : 'uk';
