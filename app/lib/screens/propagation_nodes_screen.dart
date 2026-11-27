import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';

import '../node/node_service.dart';
import '../providers.dart';
import 'propagation_widgets.dart';

/// Full list of known propagation nodes, opened by "Change" in Settings:
/// searchable by name or hash, nearest first, with the current and default
/// node marked. Picking a node pins it; "Automatic" and "Reset to default"
/// are explicit choices too. Pops after a choice.
class PropagationNodesScreen extends ConsumerStatefulWidget {
  const PropagationNodesScreen({super.key});

  @override
  ConsumerState<PropagationNodesScreen> createState() =>
      _PropagationNodesScreenState();
}

class _PropagationNodesScreenState
    extends ConsumerState<PropagationNodesScreen> {
  String _query = '';

  bool _matches(String hash, String? name) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return hash.contains(q) || (name?.toLowerCase().contains(q) ?? false);
  }

  Future<void> _choose(Future<void> Function() action) async {
    await action();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final node = ref.read(nodeProvider);
    final v = ref.watch(propagationProvider).value;
    final text = Theme.of(context).textTheme;
    final children = <Widget>[];
    if (v != null) {
      final defHex = toHex(v.defaultNodeOrConst);
      final pinHex = v.pinned == null ? null : toHex(v.pinned!);
      final activeHex = v.active == null ? null : toHex(v.active!);
      final heard = {for (final n in v.nodes) n.hashHex: n};
      final rows = <_Row>[
        for (final n in v.nodes) _Row(n.hashHex, n),
        // The default and a pinned node are listed even if never heard.
        if (!heard.containsKey(defHex)) _Row(defHex, null),
        if (pinHex != null && !heard.containsKey(pinHex) && pinHex != defHex)
          _Row(pinHex, null),
      ];
      rows.sort((a, b) {
        final ah = a.node?.hops ?? 1 << 30;
        final bh = b.node?.hops ?? 1 << 30;
        if (ah != bh) return ah.compareTo(bh);
        final at = a.node?.lastSeen;
        final bt = b.node?.lastSeen;
        if (at != null && bt != null) return bt.compareTo(at);
        return a.hash.compareTo(b.hash);
      });
      final shown = [
        for (final r in rows)
          if (_matches(r.hash, r.node?.name)) r,
      ];
      children.addAll([
        ListTile(
          key: const ValueKey('mail-node-auto'),
          leading: const Icon(Icons.auto_mode),
          title: Text(pt(context, 'mail_node_auto')),
          trailing: v.choice == PropagationChoice.automatic
              ? const Icon(Icons.check)
              : null,
          onTap: () => _choose(() => node.setPropagationNode(null)),
        ),
        ListTile(
          key: const ValueKey('mail-node-reset'),
          leading: const Icon(Icons.restart_alt),
          title: Text(pt(context, 'mail_node_reset')),
          trailing: v.choice == PropagationChoice.defaultNode
              ? const Icon(Icons.check)
              : null,
          onTap: () => _choose(node.resetPropagationNode),
        ),
        const Divider(),
      ]);
      if (shown.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              pt(
                context,
                _query.isEmpty ? 'mail_nodes_empty' : 'mail_search_none',
              ),
              key: const ValueKey('mail-nodes-empty'),
              style: text.bodySmall,
            ),
          ),
        );
      }
      for (final r in shown) {
        final n = r.node;
        final isDefault = r.hash == defHex;
        final isCurrent = r.hash == activeHex;
        final label = n != null
            ? nodeLabel(n)
            : pt(context, 'mail_node_unknown', {'h': nodeShortHash(r.hash)});
        final badges = [
          if (isCurrent) pt(context, 'mail_node_current_badge'),
          if (isDefault) pt(context, 'mail_node_default'),
          if (r.hash == pinHex) pt(context, 'mail_node_pinned'),
        ];
        final selected =
            r.hash == pinHex ||
            (isDefault && v.choice == PropagationChoice.defaultNode);
        children.add(
          ListTile(
            key: ValueKey('mail-node-${r.hash}'),
            title: Text(label),
            subtitle: Text(
              [
                if (n != null)
                  nodeDetail(context, n)
                else
                  pt(context, 'mail_node_not_heard'),
                ...badges,
              ].join(' · '),
            ),
            trailing: selected ? const Icon(Icons.check) : null,
            selected: isCurrent,
            // Picking the default node is the same as resetting to it.
            onTap: () => _choose(
              isDefault
                  ? node.resetPropagationNode
                  : () => node.setPropagationNode(r.hash),
            ),
          ),
        );
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(pt(context, 'mail_nodes_title'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              key: const ValueKey('mail-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: pt(context, 'mail_search'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Expanded(
            child: v == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(children: children),
          ),
        ],
      ),
    );
  }
}

class _Row {
  const _Row(this.hash, this.node);
  final String hash;
  final LxmPropagationNode? node;
}
