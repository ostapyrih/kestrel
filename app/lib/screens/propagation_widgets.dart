import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';

import '../l10n/strings.dart';
import '../node/node_service.dart';
import '../providers.dart';
import 'propagation_nodes_screen.dart';

/// Strings of the "Mail via node" feature (Ukrainian default, English
/// fallback), kept apart from the main table like the updater strings.
String pt(
  BuildContext context,
  String key, [
  Map<String, String> args = const {},
]) {
  final en = Strings.of(context).lang == 'en';
  var s = (en ? _en[key] : _uk[key]) ?? _uk[key] ?? key;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

/// Label of a message route (`direct`, `propagated`, ...).
String routeLabel(BuildContext context, String route) => switch (route) {
  'via_bridge' => Strings.of(context).t('route_via_bridge'),
  'propagated' => pt(context, 'mail_route_node'),
  _ => route,
};

const _uk = <String, String>{
  'mail_title': 'Пошта через вузол',
  'mail_hint':
      'Вузол розсилки (propagation node) зберігає листи, поки вас немає в мережі. '
      'Kestrel лише користується чужим вузлом.',
  'mail_route_node': 'через вузол',
  'mail_node_auto': 'Автоматично (найближчий вузол)',
  'mail_node_current': 'Зараз: {node}',
  'mail_node_none': 'Вузол ще не знайдено',
  'mail_nodes_empty':
      'Жодного вузла розсилки ще не чути. Вони зʼявляються з анонсів мережі.',
  'mail_node_hops': 'стрибків: {n}',
  'mail_node_disabled': 'вимкнений',
  'mail_node_cost': 'вартість штампа {c}',
  'mail_node_seen': 'чутно {t}',
  'mail_node_pinned': 'закріплений',
  'mail_node_unknown': 'Невідомий вузол {h}',
  'mail_interval': 'Перевіряти пошту',
  'mail_interval_off': 'Вручну',
  'mail_interval_min': 'кожні {n} хв',
  'mail_interval_hour': 'щогодини',
  'mail_fallback': 'Надсилати через вузол, якщо напряму не вдалося',
  'mail_fallback_hint': 'Коли отримувач недоступний, лист залишиться на вузлі, доки той його забере.',
  'mail_check_now': 'Перевірити пошту',
  'mail_checking': 'Перевіряємо...',
  'mail_phase_path': 'Шукаємо шлях до вузла...',
  'mail_phase_link': 'Зʼєднуємося з вузлом...',
  'mail_phase_list': 'Запитуємо список листів...',
  'mail_phase_receive': 'Завантажуємо листи... {p}%',
  'mail_phase_persist': 'Зберігаємо листи...',
  'mail_phase_confirm': 'Підтверджуємо отримання...',
  'mail_last': 'Остання перевірка {t}: {r}',
  'mail_never': 'Пошту ще не перевіряли',
  'mail_result_ok': 'нових листів: {n}',
  'mail_result_ok_left': 'нових листів: {n}, ще на вузлі: {m}',
  'mail_err_noNode': 'вузол не знайдено',
  'mail_err_nodeDisabled': 'вузол не приймає листи',
  'mail_err_noPath': 'немає шляху до вузла',
  'mail_err_linkFailed': 'не вдалося зʼєднатися з вузлом',
  'mail_err_noIdentity': 'вузол не розпізнав вашу ідентичність',
  'mail_err_noAccess': 'вузол не дозволяє вам забирати пошту',
  'mail_err_transferFailed': 'передача перервалася',
  'mail_err_invalidResponse': 'вузол відповів незрозуміло',
  'mail_err_timeout': 'вузол не відповів вчасно',
  'mail_err_disabled': 'на цьому пристрої перевірку вимкнено',
  'mail_err_stopped': 'зупинено',
  'send_via_node': 'Надіслати через вузол',
  'mail_change': 'Змінити',
  'mail_nodes_title': 'Вузол розсилки',
  'mail_search': 'Пошук за назвою або хешем',
  'mail_search_none': 'Нічого не знайдено',
  'mail_node_default': 'типовий',
  'mail_node_current_badge': 'зараз',
  'mail_node_reset': 'Скинути до типового',
  'mail_node_current_default': 'Зараз: {node} (типовий)',
  'mail_node_default_down': 'Типовий вузол недоступний, використовуємо {node}',
  'mail_node_default_down_none': 'Типовий вузол недоступний',
  'mail_node_not_heard': 'ще не чути',
  'mail_node_heard': 'чутно {t}',
};

const _en = <String, String>{
  'mail_title': 'Mail via node',
  'mail_hint':
      'A propagation node keeps your messages while you are offline. '
      'Kestrel only uses other people\'s nodes, it never runs one.',
  'mail_route_node': 'via node',
  'mail_node_auto': 'Automatic (nearest node)',
  'mail_node_current': 'Using: {node}',
  'mail_node_none': 'No node found yet',
  'mail_nodes_empty':
      'No propagation node heard yet. They show up from network announces.',
  'mail_node_hops': '{n} hops',
  'mail_node_disabled': 'disabled',
  'mail_node_cost': 'stamp cost {c}',
  'mail_node_seen': 'heard {t}',
  'mail_node_pinned': 'pinned',
  'mail_node_unknown': 'Unknown node {h}',
  'mail_interval': 'Check mail',
  'mail_interval_off': 'Manually',
  'mail_interval_min': 'every {n} min',
  'mail_interval_hour': 'hourly',
  'mail_fallback': 'Send via node when direct delivery fails',
  'mail_fallback_hint': 'If the recipient is unreachable the message waits on the node until they fetch it.',
  'mail_check_now': 'Check mail now',
  'mail_checking': 'Checking...',
  'mail_phase_path': 'Looking for a path to the node...',
  'mail_phase_link': 'Connecting to the node...',
  'mail_phase_list': 'Asking for the message list...',
  'mail_phase_receive': 'Downloading messages... {p}%',
  'mail_phase_persist': 'Saving messages...',
  'mail_phase_confirm': 'Confirming receipt...',
  'mail_last': 'Last check {t}: {r}',
  'mail_never': 'Mail has not been checked yet',
  'mail_result_ok': 'new messages: {n}',
  'mail_result_ok_left': 'new messages: {n}, still on the node: {m}',
  'mail_err_noNode': 'no node found',
  'mail_err_nodeDisabled': 'the node does not accept messages',
  'mail_err_noPath': 'no path to the node',
  'mail_err_linkFailed': 'could not connect to the node',
  'mail_err_noIdentity': 'the node did not recognise your identity',
  'mail_err_noAccess': 'the node does not let you fetch mail',
  'mail_err_transferFailed': 'transfer interrupted',
  'mail_err_invalidResponse': 'unexpected answer from the node',
  'mail_err_timeout': 'the node did not answer in time',
  'mail_err_disabled': 'checking is turned off on this device',
  'mail_err_stopped': 'stopped',
  'send_via_node': 'Send via node',
  'mail_change': 'Change',
  'mail_nodes_title': 'Propagation node',
  'mail_search': 'Search by name or hash',
  'mail_search_none': 'Nothing found',
  'mail_node_default': 'default',
  'mail_node_current_badge': 'current',
  'mail_node_reset': 'Reset to default',
  'mail_node_current_default': 'Using: {node} (default)',
  'mail_node_default_down': 'Default node unreachable, using {node}',
  'mail_node_default_down_none': 'Default node unreachable',
  'mail_node_not_heard': 'not heard yet',
  'mail_node_heard': 'heard {t}',
};

/// One-line description of a sync result, e.g. `new messages: 2`.
String syncResultText(BuildContext context, LxmSyncResult r) {
  if (r.ok) {
    return r.remaining > 0
        ? pt(context, 'mail_result_ok_left', {
            'n': '${r.delivered}',
            'm': '${r.remaining}',
          })
        : pt(context, 'mail_result_ok', {'n': '${r.delivered}'});
  }
  return pt(context, 'mail_err_${r.error.name}');
}

/// Text for a sync phase while it is running.
String syncPhaseText(BuildContext context, LxmSyncProgress p) =>
    switch (p.phase) {
      LxmSyncPhase.pathRequested => pt(context, 'mail_phase_path'),
      LxmSyncPhase.linkEstablishing => pt(context, 'mail_phase_link'),
      LxmSyncPhase.listing => pt(context, 'mail_phase_list'),
      LxmSyncPhase.receiving => pt(context, 'mail_phase_receive', {
        'p': '${(p.progress * 100).round()}',
      }),
      LxmSyncPhase.persisting => pt(context, 'mail_phase_persist'),
      LxmSyncPhase.confirming => pt(context, 'mail_phase_confirm'),
      _ => pt(context, 'mail_checking'),
    };

String nodeShortHash(String hex) =>
    hex.length <= 12 ? hex : '${hex.substring(0, 8)}...';

String nodeLabel(LxmPropagationNode n) => n.name ?? nodeShortHash(n.hashHex);

String agoText(BuildContext context, DateTime t) {
  final d = DateTime.now().difference(t);
  final en = Strings.of(context).lang == 'en';
  if (d.inMinutes < 1) return en ? 'just now' : 'щойно';
  if (d.inHours < 1) {
    return en ? '${d.inMinutes} min ago' : '${d.inMinutes} хв тому';
  }
  if (d.inDays < 1) return en ? '${d.inHours} h ago' : '${d.inHours} год тому';
  return en ? '${d.inDays} d ago' : '${d.inDays} дн тому';
}

/// Live propagation state for the settings section.
final propagationProvider = StreamProvider<PropagationView>((ref) async* {
  final n = ref.watch(nodeProvider);
  await n.ready;
  yield n.propagation;
  yield* n.propagationChanges;
});

const _intervals = [0, 5, 15, 30, 60];

/// Settings -> "Mail via node": the current node, the last sync result,
/// "Check mail now", interval, fallback toggle and a "Change" button that opens
/// the full node list ([PropagationNodesScreen]).
class PropagationSettingsSection extends ConsumerWidget {
  const PropagationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final node = ref.read(nodeProvider);
    final v = ref.watch(propagationProvider).value;
    return Column(
      key: const ValueKey('mail-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(pt(context, 'mail_title'), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(pt(context, 'mail_hint'), style: text.bodySmall),
        const SizedBox(height: 8),
        if (v == null)
          Text(Strings.of(context).t('starting'))
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _CurrentNode(view: v)),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('mail-change'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PropagationNodesScreen(),
                  ),
                ),
                child: Text(pt(context, 'mail_change')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text(pt(context, 'mail_interval'))),
              DropdownButton<int>(
                key: const ValueKey('mail-interval'),
                value: _intervals.contains(v.intervalMinutes)
                    ? v.intervalMinutes
                    : defaultPropagationIntervalMinutes,
                items: [
                  for (final m in _intervals)
                    DropdownMenuItem(
                      value: m,
                      child: Text(switch (m) {
                        0 => pt(context, 'mail_interval_off'),
                        60 => pt(context, 'mail_interval_hour'),
                        _ => pt(context, 'mail_interval_min', {'n': '$m'}),
                      }),
                    ),
                ],
                onChanged: (m) {
                  if (m != null) node.setPropagationInterval(m);
                },
              ),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('mail-fallback-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(pt(context, 'mail_fallback')),
            subtitle: Text(pt(context, 'mail_fallback_hint')),
            value: v.fallback,
            onChanged: node.setPropagationFallback,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('mail-check-now'),
              onPressed: v.syncing ? null : node.syncMail,
              icon: v.syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.mail_outline),
              label: Text(
                v.syncing
                    ? pt(context, 'mail_checking')
                    : pt(context, 'mail_check_now'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _SyncStatus(view: v),
        ],
      ],
    );
  }
}

/// "Hops, last heard" detail line of a node.
String nodeDetail(BuildContext context, LxmPropagationNode n) => [
  pt(context, 'mail_node_hops', {'n': '${n.hops}'}),
  if (!n.enabled) pt(context, 'mail_node_disabled'),
  pt(context, 'mail_node_heard', {'t': agoText(context, n.lastSeen)}),
].join(' · ');

class _CurrentNode extends StatelessWidget {
  const _CurrentNode({required this.view});

  final PropagationView view;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    final n = view.activeNode;
    final label = n != null
        ? nodeLabel(n)
        : (view.active != null ? nodeShortHash(toHex(view.active!)) : null);
    final defaultDown =
        view.choice == PropagationChoice.defaultNode && view.defaultUnreachable;
    final String title;
    if (label == null) {
      title = pt(
        context,
        defaultDown ? 'mail_node_default_down_none' : 'mail_node_none',
      );
    } else if (defaultDown) {
      title = pt(context, 'mail_node_default_down', {'node': label});
    } else {
      title = switch (view.choice) {
        PropagationChoice.pinned => pt(context, 'mail_node_current', {
          'node': '$label (${pt(context, 'mail_node_pinned')})',
        }),
        PropagationChoice.defaultNode => pt(
          context,
          'mail_node_current_default',
          {'node': label},
        ),
        PropagationChoice.automatic => pt(context, 'mail_node_current', {
          'node': label,
        }),
      };
    }
    final detail = label == null
        ? null
        : (n != null
              ? nodeDetail(context, n)
              : pt(context, 'mail_node_not_heard'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            key: const ValueKey('mail-current-node'),
            style: style.bodyMedium,
          ),
          if (detail != null)
            Text(
              detail,
              key: const ValueKey('mail-current-detail'),
              style: style.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.view});

  final PropagationView view;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    if (view.syncing) {
      return Text(
        syncPhaseText(context, view.progress),
        key: const ValueKey('mail-progress'),
        style: style,
      );
    }
    final r = view.lastSync;
    if (r == null) {
      return Text(
        pt(context, 'mail_never'),
        key: const ValueKey('mail-last'),
        style: style,
      );
    }
    final failed = !r.ok;
    return Text(
      pt(context, 'mail_last', {
        't': agoText(context, r.at),
        'r': syncResultText(context, r),
      }),
      key: const ValueKey('mail-last'),
      style: failed
          ? style?.copyWith(color: Theme.of(context).colorScheme.error)
          : style,
    );
  }
}
