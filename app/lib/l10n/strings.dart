import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Minimal localisation: a key -> text map per language. Ukrainian is the
/// default, English the fallback for English devices.
class Strings {
  Strings(this.lang);

  final String lang;

  static const supportedLocales = [Locale('uk'), Locale('en')];

  static const delegate = _StringsDelegate();
  static final delegates = <LocalizationsDelegate<Object?>>[
    delegate,
    ...GlobalMaterialLocalizations.delegates,
  ];

  static Strings of(BuildContext context) =>
      Localizations.of<Strings>(context, Strings) ?? Strings('uk');

  /// Picks Ukrainian unless the device language is English.
  static Locale resolve(Locale? device, Iterable<Locale> supported) =>
      device?.languageCode == 'en' ? const Locale('en') : const Locale('uk');

  String t(String key, [Map<String, String> args = const {}]) {
    var s = (lang == 'en' ? _en[key] : _uk[key]) ?? _uk[key] ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }

  /// `B (телефон)` / `A (міст)` for an identity letter.
  String account(String identity) =>
      identity == 'A' ? t('account_a') : t('account_b');

  static const _uk = <String, String>{
    'app_title': 'Kestrel',
    'tcp_online': 'TCP Online',
    'tcp_offline': 'Offline',
    'tcp_connecting': 'TCP...',
    'account_b': 'B (телефон)',
    'account_a': 'A (міст)',
    'account_all': 'Усі',
    'bridge_hint': 'увімкніть міст',
    'chats_empty': 'Чатів ще немає. Натисніть «Новий чат».',
    'new_chat': 'Новий чат',
    'settings': 'Налаштування',
    'address': 'LXMF-адреса (32 hex)',
    'address_hint': 'Вставте адресу співрозмовника',
    'name_optional': 'Імʼя (необовʼязково)',
    'known_peers': 'Відомі вузли (з анонсів)',
    'known_peers_empty': 'Поки жодного анонсу не отримано',
    'open_chat': 'Відкрити чат',
    'invalid_address': 'Адреса має бути 32 hex-символи',
    'display_name': 'Імʼя в мережі',
    'device_name': 'Назва пристрою',
    'device_name_hint': 'Зберігається лише локально; знадобиться для кількох пристроїв.',
    'chat_select': 'Оберіть чат зі списку',
    'save': 'Зберегти',
    'server': 'Сервер Reticulum (TCP)',
    'host': 'Хост',
    'port': 'Порт',
    'apply': 'Застосувати',
    'identity': 'Ідентичність B (телефон)',
    'lxmf_address': 'LXMF-адреса',
    'public_key': 'Публічний ключ (для whitelist мосту)',
    'copy': 'Копіювати',
    'copied': 'Скопійовано',
    'bridge': 'Міст до MeshChatX',
    'bridge_enable': 'Увімкнути міст',
    'bridge_soon': 'буде доступно',
    'bridge_note': 'Перемикач лише зберігається. Чати й повідомлення ніколи не видаляються при зміні режиму.',
    'from': 'Від: {account}',
    'message_hint': 'Повідомлення',
    'send': 'Надіслати',
    'details': 'Деталі повідомлення',
    'hash': 'Хеш LXMF',
    'sender': 'Від імені',
    'route': 'Маршрут',
    'transport': 'Транспорт',
    'status': 'Статус',
    'error': 'Помилка',
    'timeline': 'Етапи доставки',
    'signature_unverified': 'підпис не перевірено',
    'status_queued': 'в черзі',
    'status_sending': 'відправляється',
    'status_sent': 'відправлено',
    'status_delivered': 'доставлено',
    'status_failed': 'помилка',
    'status_received': 'отримано',
    'transport_tcp': 'TCP',
    'transport_lora': 'LoRa (RNode)',
    'transport_none': 'в черзі (офлайн)',
    'stage_queued': 'поставлено в чергу',
    'stage_ready': 'готово до відправки',
    'stage_stamp_generated': 'штамп згенеровано',
    'stage_path_requested': 'запит шляху',
    'stage_link_requested': 'запит зʼєднання',
    'stage_link_established': 'зʼєднання встановлено',
    'stage_sending': 'передача',
    'stage_sent': 'відправлено',
    'stage_delivered': 'доставлено',
    'stage_failed': 'помилка',
    'stage_received': 'отримано',
    'stage_proof_timeout': 'немає підтвердження, повтор',
    'stage_link_closed': 'зʼєднання закрито, повтор',
    'stage_transfer_failed': 'передача не вдалася, повтор',
    'stage_link_send_failed': 'не вдалося надіслати, повтор',
    'stage_rejected': 'отримувач відхилив',
    'stage_cancelled': 'скасовано',
    'starting': 'Запуск вузла...',
  };

  static const _en = <String, String>{
    'tcp_offline': 'Offline',
    'chats_empty': 'No chats yet. Tap "New chat".',
    'account_b': 'B (phone)',
    'account_a': 'A (bridge)',
    'account_all': 'All',
    'bridge_hint': 'enable the bridge',
    'new_chat': 'New chat',
    'settings': 'Settings',
    'address': 'LXMF address (32 hex)',
    'address_hint': 'Paste the peer address',
    'name_optional': 'Name (optional)',
    'known_peers': 'Known peers (from announces)',
    'known_peers_empty': 'No announces received yet',
    'open_chat': 'Open chat',
    'invalid_address': 'The address must be 32 hex characters',
    'display_name': 'Display name',
    'device_name': 'Device name',
    'device_name_hint': 'Stored locally only; used later for multiple devices.',
    'chat_select': 'Select a chat from the list',
    'save': 'Save',
    'server': 'Reticulum server (TCP)',
    'host': 'Host',
    'port': 'Port',
    'apply': 'Apply',
    'identity': 'Identity B (phone)',
    'lxmf_address': 'LXMF address',
    'public_key': 'Public key (for the bridge whitelist)',
    'copy': 'Copy',
    'copied': 'Copied',
    'bridge': 'Bridge to MeshChatX',
    'bridge_enable': 'Enable bridge',
    'bridge_soon': 'coming soon',
    'bridge_note': 'The switch is only stored. Chats and messages are never deleted when the mode changes.',
    'from': 'From: {account}',
    'message_hint': 'Message',
    'send': 'Send',
    'details': 'Message details',
    'hash': 'LXMF hash',
    'sender': 'Sent as',
    'route': 'Route',
    'transport': 'Transport',
    'status': 'Status',
    'error': 'Error',
    'timeline': 'Delivery timeline',
    'signature_unverified': 'signature not verified',
    'status_queued': 'queued',
    'status_sending': 'sending',
    'status_sent': 'sent',
    'status_delivered': 'delivered',
    'status_failed': 'failed',
    'status_received': 'received',
    'transport_none': 'queued (offline)',
    'stage_queued': 'queued',
    'stage_ready': 'ready to send',
    'stage_stamp_generated': 'stamp generated',
    'stage_path_requested': 'path requested',
    'stage_link_requested': 'link requested',
    'stage_link_established': 'link established',
    'stage_sending': 'transferring',
    'stage_sent': 'sent',
    'stage_delivered': 'delivered',
    'stage_failed': 'failed',
    'stage_received': 'received',
    'stage_proof_timeout': 'no proof, retrying',
    'stage_link_closed': 'link closed, retrying',
    'stage_transfer_failed': 'transfer failed, retrying',
    'stage_link_send_failed': 'send failed, retrying',
    'stage_rejected': 'rejected by receiver',
    'stage_cancelled': 'cancelled',
    'starting': 'Starting node...',
  };
}

class _StringsDelegate extends LocalizationsDelegate<Strings> {
  const _StringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'uk' || locale.languageCode == 'en';

  @override
  Future<Strings> load(Locale locale) =>
      SynchronousFuture(Strings(locale.languageCode));

  @override
  bool shouldReload(_StringsDelegate old) => false;
}
