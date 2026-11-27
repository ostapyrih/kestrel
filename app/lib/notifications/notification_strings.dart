import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import 'notification_models.dart';

const _uk = <String, String>{
  'n_title': 'Сповіщення',
  'n_enable': 'Сповіщення про нові повідомлення',
  'n_content': 'Показувати текст повідомлення',
  'n_content_hint': 'Вимкнено: лише «Нове повідомлення», без імені й тексту.',
  'n_sound': 'Звук',
  'n_new_message': 'Нове повідомлення',
  'n_new_messages': 'Нових повідомлень: {n}',
  'n_mute_chat': 'Вимкнути сповіщення чату',
  'n_unmute_chat': 'Увімкнути сповіщення чату',
  'n_background': 'Працювати у фоні',
  'n_background_hint':
      'Постійне сповіщення «Kestrel підключено» тримає зʼєднання, щоб '
      'повідомлення приходили одразу.',
  'n_battery': 'Дозволити роботу без обмежень батареї',
  'n_battery_hint':
      'Без цього Android може зупиняти Kestrel у фоні, і повідомлення '
      'запізнюватимуться.',
  'n_battery_ok': 'Обмеження батареї для Kestrel вимкнено',
  'n_battery_why':
      'Щоб повідомлення приходили у фоні, Android не повинен «присипляти» '
      'Kestrel. Дозвольте роботу без обмежень батареї на наступному екрані.',
  'n_allow': 'Дозволити',
  'n_later': 'Пізніше',
  'n_fg_title': 'Kestrel підключено',
  'n_fg_text': 'Тримає зʼєднання з мережею для нових повідомлень',
  'n_ios_info':
      'iOS не дає програмам без Apple-сервера (APNs) отримувати повідомлення '
      'миттєво. Kestrel тримає зʼєднання, поки програма відкрита, а у фоні '
      'iOS сама час від часу будить його, щоб перевірити пошту на вузлі; '
      'коли саме і як часто, вирішує iOS (від хвилин до годин), тож '
      'сповіщення можуть запізнюватися. Якщо програму закрито свайпом, '
      'перевірок не буде.',
  'n_desktop_info':
      'Сповіщення зʼявляються, коли вікно сховане в трей або не в фокусі.',
};

const _en = <String, String>{
  'n_title': 'Notifications',
  'n_enable': 'New message notifications',
  'n_content': 'Show message text',
  'n_content_hint': 'Off: only "New message", without name or text.',
  'n_sound': 'Sound',
  'n_new_message': 'New message',
  'n_new_messages': '{n} new messages',
  'n_mute_chat': 'Mute chat notifications',
  'n_unmute_chat': 'Unmute chat notifications',
  'n_background': 'Run in background',
  'n_background_hint':
      'A persistent "Kestrel is connected" notification keeps the '
      'connection alive so messages arrive right away.',
  'n_battery': 'Allow unrestricted battery use',
  'n_battery_hint':
      'Without it Android may stop Kestrel in the background and messages '
      'will be late.',
  'n_battery_ok': 'Battery restrictions are off for Kestrel',
  'n_battery_why':
      'To receive messages in the background Android must not put Kestrel '
      'to sleep. Allow unrestricted battery use on the next screen.',
  'n_allow': 'Allow',
  'n_later': 'Later',
  'n_fg_title': 'Kestrel is connected',
  'n_fg_text': 'Keeping the network connection for new messages',
  'n_ios_info':
      'Without an Apple push server (APNs) iOS cannot deliver messages '
      'instantly. Kestrel keeps its connection while the app is open; in '
      'the background iOS wakes it up from time to time to check the mail '
      'node, and iOS decides when and how often (minutes to hours), so '
      'notifications can be late. If you swipe the app away there are no '
      'checks.',
  'n_desktop_info':
      'Notifications appear while the window is hidden in the tray or '
      'unfocused.',
};

String notifText(
  String lang,
  String key, [
  Map<String, String> args = const {},
]) {
  var s = (lang == 'en' ? _en[key] : _uk[key]) ?? _uk[key] ?? key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

/// [notifText] for the language of [context].
String nf(
  BuildContext context,
  String key, [
  Map<String, String> args = const {},
]) => notifText(Strings.of(context).lang, key, args);

/// Words for notifications in [lang] (no BuildContext needed).
NotificationText notificationTextFor(String lang) => NotificationText(
  appName: 'Kestrel',
  newMessage: notifText(lang, 'n_new_message'),
  newMessages: (n) => notifText(lang, 'n_new_messages', {'n': '$n'}),
);
