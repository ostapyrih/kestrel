import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../node/node_service.dart';

/// Small coloured badge with the identity letter (`A` / `B`).
class IdentityBadge extends StatelessWidget {
  const IdentityBadge(this.identity, {super.key, this.label});
  final String identity;

  /// Replaces the letter, e.g. `B · iPhone` for a history of another device.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isB = identity == 'B';
    return Container(
      key: ValueKey('badge-$identity'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: isB ? cs.primaryContainer : cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label ?? identity,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: isB ? cs.onPrimaryContainer : cs.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// `TCP Online` / `Offline` indicator.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator(this.state, {super.key});
  final NodeConnection state;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cs = Theme.of(context).colorScheme;
    final (text, color) = switch (state) {
      NodeConnection.online => (s.t('tcp_online'), Colors.green),
      NodeConnection.connecting => (s.t('tcp_connecting'), Colors.orange),
      NodeConnection.offline => (s.t('tcp_offline'), cs.error),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}

String formatTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return hm;
  }
  return '${two(d.day)}.${two(d.month)} $hm';
}
