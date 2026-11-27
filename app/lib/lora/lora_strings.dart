import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';

/// LoRa / RNode strings (Ukrainian default, English fallback), kept apart
/// from the main l10n tables like the NomadNet and updater strings.
String lt(
  BuildContext context,
  String key, [
  Map<String, String> args = const {},
]) => ltFor(Strings.of(context).lang, key, args);

String ltFor(String lang, String key, [Map<String, String> args = const {}]) {
  var s = (lang == 'en' ? _en[key] : _uk[key]) ?? _uk[key] ?? key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

const _uk = <String, String>{
  'lora_title': 'LoRa радіо',
  'lora_subtitle_off': 'RNode вимкнено',
  'lora_enable': 'Використовувати RNode (LoRa)',
  'lora_enable_hint':
      'Працює разом з інтернет-зʼєднанням: Reticulum використовує обидва.',
  'lora_regs_title': 'Місцеві правила радіозвʼязку',
  'lora_regs_body':
      'Ви самі відповідаєте за дотримання місцевих правил: дозволені частоти, '
      'максимальна потужність та обмеження робочого циклу (duty cycle) у вашій '
      'країні. Типові значення — приклад з документації Reticulum для '
      'діапазону 868 МГц (ЄС), а не юридична порада.',
  'lora_regs_accept': 'Розумію, увімкнути',
  'lora_cancel': 'Скасувати',
  'lora_device': 'Пристрій',
  'lora_no_device': 'Пристрій не вибрано',
  'lora_pick_ble': 'Обрати RNode (Bluetooth)',
  'lora_pick_usb': 'Обрати порт (USB)',
  'lora_change_device': 'Змінити',
  'lora_scanning': 'Пошук RNode…',
  'lora_scan_again': 'Шукати ще раз',
  'lora_no_devices_ble': 'RNode не знайдено. Увімкніть Bluetooth на RNode (режим сполучення) і повторіть.',
  'lora_no_devices_usb':
      'Послідовних портів не знайдено. Підключіть RNode по USB.',
  'lora_refresh': 'Оновити',
  'lora_pairing_hint': 'Перший раз ОС попросить PIN-код, який RNode показує на екрані (режим сполучення).',
  'lora_unsupported': 'Цей тип зʼєднання недоступний на цій платформі.',
  'lora_state_online': 'Підключено',
  'lora_state_connecting': 'Підключення…',
  'lora_state_offline': 'Не підключено',
  'lora_error': 'Помилка: {e}',
  'lora_firmware': 'Прошивка',
  'lora_platform': 'Платформа',
  'lora_last_packet': 'Останній пакет',
  'lora_last_packet_none': 'пакетів ще не було',
  'lora_rssi_snr': 'RSSI {rssi} dBm · SNR {snr} dB',
  'lora_bitrate': 'Швидкість в ефірі',
  'lora_bitrate_value': '{v} біт/с',
  'lora_airtime_packet': 'Ефір на пакет 500 Б',
  'lora_airtime_value': '≈ {s} с',
  'lora_airtime_used': 'Використано ефіру',
  'lora_airtime_used_value': '{short} % (15 с) · {long} % (1 год)',
  'lora_radio': 'Параметри радіо',
  'lora_preset': 'Пресет',
  'lora_preset_reticulum_eu': 'Reticulum EU 868 (приклад із документації)',
  'lora_preset_faster': 'Швидше (SF7, коротша дальність)',
  'lora_preset_longer': 'Далі (SF10, повільніше)',
  'lora_preset_custom': 'Свої значення',
  'lora_preset_source': 'Типово: приклад RNode з посібника Reticulum — 867,2 МГц, 125 кГц, 7 дБм, SF8, CR 4/5.',
  'lora_frequency': 'Частота, МГц',
  'lora_bandwidth': 'Ширина смуги, кГц',
  'lora_sf': 'Spreading factor (SF)',
  'lora_cr': 'Coding rate (CR)',
  'lora_txpower': 'Потужність, дБм',
  'lora_flow': 'Керування потоком (flow control)',
  'lora_flow_hint': 'Чекати сигналу «готово» від RNode між пакетами.',
  'lora_apply': 'Застосувати до радіо',
  'lora_applied': 'Параметри застосовано.',
  'lora_err_frequency': 'Частота має бути від 137 до 3000 МГц',
  'lora_err_bandwidth': 'Смуга має бути від 7,8 до 1625 кГц',
  'lora_err_txPower': 'Потужність має бути від 0 до 37 дБм',
  'lora_err_spreadingFactor': 'SF має бути від 5 до 12',
  'lora_err_codingRate': 'CR має бути від 5 до 8',
  'lora_err_number': 'Введіть число',
  'lora_warning_short':
      'Ви відповідаєте за місцеві правила: частоти, потужність, duty cycle.',
  'lora_large_hint':
      'Великі повідомлення та файли по LoRa не надсилаються (ліміт {kb} КБ).',
};

const _en = <String, String>{
  'lora_title': 'LoRa radio',
  'lora_subtitle_off': 'RNode is off',
  'lora_enable': 'Use an RNode (LoRa)',
  'lora_enable_hint':
      'Runs alongside the internet connection: Reticulum uses both.',
  'lora_regs_title': 'Local radio regulations',
  'lora_regs_body':
      'You are responsible for following the radio rules where you operate: '
      'allowed frequencies, maximum power and duty-cycle limits. The defaults '
      'are the example from the Reticulum manual for the 868 MHz band (EU), '
      'not legal advice.',
  'lora_regs_accept': 'I understand, enable',
  'lora_cancel': 'Cancel',
  'lora_device': 'Device',
  'lora_no_device': 'No device selected',
  'lora_pick_ble': 'Choose an RNode (Bluetooth)',
  'lora_pick_usb': 'Choose a port (USB)',
  'lora_change_device': 'Change',
  'lora_scanning': 'Scanning for RNodes…',
  'lora_scan_again': 'Scan again',
  'lora_no_devices_ble':
      'No RNode found. Turn on Bluetooth pairing mode on the RNode and retry.',
  'lora_no_devices_usb': 'No serial ports found. Plug the RNode in over USB.',
  'lora_refresh': 'Refresh',
  'lora_pairing_hint': 'The first time the OS asks for the PIN the RNode shows on its display (pairing mode).',
  'lora_unsupported': 'This connection type is not available on this platform.',
  'lora_state_online': 'Connected',
  'lora_state_connecting': 'Connecting…',
  'lora_state_offline': 'Not connected',
  'lora_error': 'Error: {e}',
  'lora_firmware': 'Firmware',
  'lora_platform': 'Platform',
  'lora_last_packet': 'Last packet',
  'lora_last_packet_none': 'no packets yet',
  'lora_rssi_snr': 'RSSI {rssi} dBm · SNR {snr} dB',
  'lora_bitrate': 'On-air bitrate',
  'lora_bitrate_value': '{v} bit/s',
  'lora_airtime_packet': 'Airtime per 500 B packet',
  'lora_airtime_value': '≈ {s} s',
  'lora_airtime_used': 'Airtime used',
  'lora_airtime_used_value': '{short} % (15 s) · {long} % (1 h)',
  'lora_radio': 'Radio parameters',
  'lora_preset': 'Preset',
  'lora_preset_reticulum_eu': 'Reticulum EU 868 (manual example)',
  'lora_preset_faster': 'Faster (SF7, shorter range)',
  'lora_preset_longer': 'Longer range (SF10, slower)',
  'lora_preset_custom': 'Custom',
  'lora_preset_source': 'Default: the RNode example in the Reticulum manual: 867.2 MHz, 125 kHz, 7 dBm, SF8, CR 4/5.',
  'lora_frequency': 'Frequency, MHz',
  'lora_bandwidth': 'Bandwidth, kHz',
  'lora_sf': 'Spreading factor (SF)',
  'lora_cr': 'Coding rate (CR)',
  'lora_txpower': 'TX power, dBm',
  'lora_flow': 'Flow control',
  'lora_flow_hint': 'Wait for the RNode\'s "ready" signal between packets.',
  'lora_apply': 'Apply to the radio',
  'lora_applied': 'Parameters applied.',
  'lora_err_frequency': 'Frequency must be 137 to 3000 MHz',
  'lora_err_bandwidth': 'Bandwidth must be 7.8 to 1625 kHz',
  'lora_err_txPower': 'TX power must be 0 to 37 dBm',
  'lora_err_spreadingFactor': 'SF must be 5 to 12',
  'lora_err_codingRate': 'CR must be 5 to 8',
  'lora_err_number': 'Enter a number',
  'lora_warning_short':
      'You are responsible for local rules: frequencies, power, duty cycle.',
  'lora_large_hint':
      'Large messages and files are not sent over LoRa (limit {kb} KB).',
};
