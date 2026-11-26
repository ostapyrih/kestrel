import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import 'update_service.dart';

/// Updater strings (Ukrainian default, English fallback), kept apart from the
/// main l10n tables to stay self-contained.
String ut(
  BuildContext context,
  String key, [
  Map<String, String> args = const {},
]) {
  final en = Strings.of(context).lang == 'en';
  var s = (en ? _en[key] : _uk[key]) ?? _uk[key] ?? key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

String updateErrorText(BuildContext context, UpdateState st) {
  final key = switch (st.error) {
    UpdateError.network => 'upd_err_network',
    UpdateError.assetMissing => 'upd_err_asset',
    UpdateError.badSignature => 'upd_err_signature',
    UpdateError.checksumMismatch => 'upd_err_checksum',
    UpdateError.noPermission => 'upd_err_permission',
    UpdateError.installFailed || null => 'upd_err_install',
  };
  return ut(context, key);
}

const _uk = <String, String>{
  'upd_title': 'Оновлення',
  'upd_auto': 'Перевіряти оновлення автоматично',
  'upd_check_now': 'Перевірити зараз',
  'upd_version': 'Поточна версія: {v}',
  'upd_checking': 'Перевірка...',
  'upd_up_to_date': 'Встановлено найновішу версію',
  'upd_available': 'Доступна версія {v}',
  'upd_banner': 'Доступне оновлення Kestrel {v}',
  'upd_details': 'Докладніше',
  'upd_install': 'Оновити',
  'upd_later': 'Пізніше',
  'upd_close': 'Закрити',
  'upd_downloading': 'Завантаження...',
  'upd_verifying': 'Перевірка підпису...',
  'upd_installing': 'Встановлення, застосунок перезапуститься...',
  'upd_whats_new': 'Що нового',
  'upd_manual':
      'Автоматичне оновлення тут недоступне. Завантажте нову версію вручну.',
  'upd_open_page': 'Відкрити сторінку релізу',
  'upd_copy_link': 'Копіювати посилання',
  'upd_err_network':
      'Не вдалося перевірити або завантажити оновлення. Перевірте зʼєднання.',
  'upd_err_asset':
      'У релізі немає потрібного файлу або підпису. Оновлення скасовано.',
  'upd_err_signature': 'Підпис релізу недійсний. Оновлення скасовано.',
  'upd_err_checksum':
      'Контрольна сума файлу не збігається. Оновлення скасовано.',
  'upd_err_permission':
      'Немає прав на запис до місця встановлення. Оновіть вручну.',
  'upd_err_install': 'Не вдалося встановити оновлення.',
};

const _en = <String, String>{
  'upd_title': 'Updates',
  'upd_auto': 'Check for updates automatically',
  'upd_check_now': 'Check now',
  'upd_version': 'Current version: {v}',
  'upd_checking': 'Checking...',
  'upd_up_to_date': 'You have the latest version',
  'upd_available': 'Version {v} is available',
  'upd_banner': 'Kestrel {v} is available',
  'upd_details': 'Details',
  'upd_install': 'Update',
  'upd_later': 'Later',
  'upd_close': 'Close',
  'upd_downloading': 'Downloading...',
  'upd_verifying': 'Verifying signature...',
  'upd_installing': 'Installing, the app will restart...',
  'upd_whats_new': 'What is new',
  'upd_manual':
      'In-app update is not available here. Download the new version manually.',
  'upd_open_page': 'Open release page',
  'upd_copy_link': 'Copy link',
  'upd_err_network':
      'Could not check for or download the update. Check your connection.',
  'upd_err_asset':
      'The release has no matching file or signature. Update cancelled.',
  'upd_err_signature': 'The release signature is invalid. Update cancelled.',
  'upd_err_checksum': 'The file checksum does not match. Update cancelled.',
  'upd_err_permission':
      'No permission to write to the install location. Update manually.',
  'upd_err_install': 'Could not install the update.',
};
