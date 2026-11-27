import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kestrel_rns/kestrel_rns.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../platform.dart';
import '../providers.dart';
import '../screens/chat_screen.dart';
import '../screens/widgets.dart';
import '../storage/repo.dart' show shortHash;
import 'browser_controller.dart';
import 'micron/micron_view.dart';
import 'nomad_providers.dart';
import 'nomad_store.dart';
import 'nomad_strings.dart';

/// Human readable size (`12 B`, `3.4 KB`, `1.2 MB`).
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// One-line loading/loaded status: phase, hops and transport.
String nomadStatusText(BuildContext context, BrowserController c) {
  String hopsText(int? h) {
    if (h == null) return '';
    if (h <= 1) return nt(context, 'nn_hops_1');
    return nt(context, 'nn_hops', {'n': '$h'});
  }

  final parts = <String>[];
  final p = c.progress;
  if (c.loading && p != null) {
    parts.add(switch (p.phase) {
      NomadPhase.findingPath => nt(context, 'nn_phase_path'),
      NomadPhase.connecting => nt(context, 'nn_phase_connect'),
      NomadPhase.requesting => nt(context, 'nn_phase_request'),
      NomadPhase.receiving => nt(context, 'nn_phase_receive', {
        'pct': '${(p.progress * 100).round()}',
      }),
    });
    if (p.hops != null) parts.add(hopsText(p.hops));
    parts.add(nt(context, 'nn_via', {'transport': 'TCP'}));
    if (p.reusedLink) parts.add(nt(context, 'nn_phase_reused'));
  } else if (c.loading) {
    parts.add(nt(context, 'nn_phase_path'));
  } else if (c.phase == BrowserPhase.loaded && c.current != null) {
    if (c.fromCache) {
      parts.add(nt(context, 'nn_from_cache'));
    } else if (c.lastElapsed != null) {
      parts.add(
        nt(context, 'nn_loaded_in', {
          'secs': (c.lastElapsed!.inMilliseconds / 1000).toStringAsFixed(1),
          'size': formatBytes(c.lastTransferSize ?? c.markup?.length ?? 0),
        }),
      );
      if (c.lastHops != null) parts.add(hopsText(c.lastHops));
      parts.add(nt(context, 'nn_via', {'transport': 'TCP'}));
    }
  }
  return parts.join(' · ');
}

String nomadFailureText(BuildContext context, BrowserController c) {
  final f = c.failure;
  if (f == null) {
    final t = c.failureText ?? '';
    if (t == 'malformed') return nt(context, 'nn_malformed');
    if (t.startsWith('unsupported:')) {
      return nt(context, 'nn_unsupported', {'link': t.substring(12)});
    }
    return nt(context, 'nn_err_generic');
  }
  return switch (f) {
    NomadFailure.noPath => nt(context, 'nn_err_nopath'),
    NomadFailure.linkFailed => nt(context, 'nn_err_link'),
    NomadFailure.timeout => nt(context, 'nn_err_timeout'),
    NomadFailure.requestFailed => nt(context, 'nn_err_request'),
    NomadFailure.tooLarge => nt(context, 'nn_err_toolarge', {
      'limit': formatBytes(16 * 1024 * 1024),
    }),
    NomadFailure.badResponse => nt(context, 'nn_err_badresponse'),
    NomadFailure.cancelled => '',
  };
}

/// Entry point: node list + browser. Two panes from 900 px, otherwise the
/// list with the browser pushed on top.
class NomadScreen extends ConsumerStatefulWidget {
  const NomadScreen({super.key});

  @override
  ConsumerState<NomadScreen> createState() => _NomadScreenState();
}

class _NomadScreenState extends ConsumerState<NomadScreen> {
  late final BrowserController _browser;

  @override
  void initState() {
    super.initState();
    _browser = ref.read(nomadServiceProvider).browser;
    _browser.onOpenChat = _openChat;
  }

  Future<void> _openChat(String hash) async {
    final node = ref.read(nodeProvider);
    try {
      final target = await node.openChat(hash);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => target.isDraft
              ? ChatScreen(draft: target)
              : ChatScreen(chatId: target.chatId),
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nt(context, 'nn_open_chat_failed'))),
      );
    }
  }

  @override
  void dispose() {
    if (_browser.onOpenChat == _openChat) _browser.onOpenChat = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
    final c = ref.watch(nomadServiceProvider).browser;
    final conn = ref.watch(connectionProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: Text(nt(context, 'nn_title')),
        actions: [
          if (conn != null) Center(child: ConnectionIndicator(conn)),
          const SizedBox(width: 12),
        ],
      ),
      body: wide
          ? Row(
              children: [
                SizedBox(
                  width: 360,
                  child: NodeListPane(onOpen: (url) => c.go(url)),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: BrowserPane(controller: c)),
              ],
            )
          : NodeListPane(
              onOpen: (url) {
                c.go(url);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NomadBrowserScreen(controller: c),
                  ),
                );
              },
            ),
    );
  }
}

/// Full-screen browser (narrow layout).
class NomadBrowserScreen extends StatelessWidget {
  const NomadBrowserScreen({super.key, required this.controller});
  final BrowserController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PopScope(
        canPop: !controller.canGoBack,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) controller.back();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              controller.title.isEmpty
                  ? nt(context, 'nn_title')
                  : controller.title,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: BrowserPane(controller: controller),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ node list

enum _Sort { seen, name, hops }

class NodeListPane extends ConsumerStatefulWidget {
  const NodeListPane({super.key, required this.onOpen});

  /// Opens a node page in the browser.
  final void Function(NomadUrl url) onOpen;

  @override
  ConsumerState<NodeListPane> createState() => _NodeListPaneState();
}

class _NodeListPaneState extends ConsumerState<NodeListPane> {
  final _search = TextEditingController();
  final _address = TextEditingController();
  _Sort _sort = _Sort.seen;
  bool _favOnly = false;

  @override
  void dispose() {
    _search.dispose();
    _address.dispose();
    super.dispose();
  }

  void _openAddress() {
    final text = _address.text.trim();
    if (text.isEmpty) return;
    final u = NomadUrl.tryParse(text);
    if (u == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(nt(context, 'nn_malformed'))));
      return;
    }
    widget.onOpen(u);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const ValueKey('nn-address-list'),
              controller: _address,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: nt(context, 'nn_address_hint'),
                suffixIcon: IconButton(
                  tooltip: nt(context, 'nn_go'),
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _openAddress,
                ),
              ),
              onSubmitted: (_) => _openAddress(),
            ),
          ),
          TabBar(
            tabs: [
              Tab(text: nt(context, 'nn_tab_nodes')),
              Tab(text: nt(context, 'nn_tab_bookmarks')),
              Tab(text: nt(context, 'nn_tab_history')),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _nodes(context),
                _bookmarks(context),
                _history(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nodes(BuildContext context) {
    final nodes = ref.watch(nomadNodesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('nn-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: nt(context, 'nn_search'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                key: const ValueKey('nn-fav-filter'),
                tooltip: nt(context, 'nn_favourites_only'),
                icon: Icon(_favOnly ? Icons.star : Icons.star_border),
                onPressed: () => setState(() => _favOnly = !_favOnly),
              ),
              PopupMenuButton<_Sort>(
                key: const ValueKey('nn-sort'),
                tooltip: nt(context, 'nn_sort'),
                icon: const Icon(Icons.sort),
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _Sort.seen,
                    child: Text(nt(context, 'nn_sort_seen')),
                  ),
                  PopupMenuItem(
                    value: _Sort.name,
                    child: Text(nt(context, 'nn_sort_name')),
                  ),
                  PopupMenuItem(
                    value: _Sort.hops,
                    child: Text(nt(context, 'nn_sort_hops')),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: nodes.when(
            data: (all) {
              final q = _search.text.trim().toLowerCase();
              var list = all
                  .where((n) => n.announced || n.favourite)
                  .where(
                    (n) =>
                        q.isEmpty ||
                        n.name.toLowerCase().contains(q) ||
                        n.hash.contains(q),
                  )
                  .where((n) => !_favOnly || n.favourite)
                  .toList();
              list.sort((a, b) {
                if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
                return switch (_sort) {
                  _Sort.seen => b.lastSeen.compareTo(a.lastSeen),
                  _Sort.name => a.title.toLowerCase().compareTo(
                    b.title.toLowerCase(),
                  ),
                  _Sort.hops => (a.hops ?? 999).compareTo(b.hops ?? 999),
                };
              });
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      nt(context, 'nn_nodes_empty'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _NodeTile(
                  node: list[i],
                  onOpen: () => widget.onOpen(
                    NomadUrl(fromHex(list[i].hash), nomadDefaultPath),
                  ),
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
          ),
        ),
      ],
    );
  }

  Widget _bookmarks(BuildContext context) {
    final list = ref.watch(nomadBookmarksProvider).value ?? const [];
    final store = ref.read(nomadServiceProvider).store;
    if (list.isEmpty) {
      return Center(child: Text(nt(context, 'nn_bookmarks_empty')));
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final b = list[i];
        return ListTile(
          leading: const Icon(Icons.bookmark),
          title: Text(b.title.isEmpty ? b.url : b.title, maxLines: 1),
          subtitle: Text(b.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => store.removeBookmark(b.url),
          ),
          onTap: () {
            final u = NomadUrl.tryParse(b.url);
            if (u != null) widget.onOpen(u);
          },
        );
      },
    );
  }

  Widget _history(BuildContext context) {
    final list = ref.watch(nomadHistoryProvider).value ?? const [];
    final store = ref.read(nomadServiceProvider).store;
    if (list.isEmpty) {
      return Center(child: Text(nt(context, 'nn_history_empty')));
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: store.clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(nt(context, 'nn_clear_history')),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final h = list[i];
              return ListTile(
                leading: const Icon(Icons.history),
                title: Text(h.title.isEmpty ? h.url : h.title, maxLines: 1),
                subtitle: Text(
                  '${h.url} · ${formatTime(h.ts)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  final u = NomadUrl.tryParse(h.url);
                  if (u != null) widget.onOpen(u);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NodeTile extends ConsumerWidget {
  const _NodeTile({required this.node, required this.onOpen});
  final NomadNodeRow node;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(nomadServiceProvider).store;
    final hops = node.hops;
    final hopsText = hops == null
        ? ''
        : hops <= 1
        ? nt(context, 'nn_hops_1')
        : nt(context, 'nn_hops', {'n': '$hops'});
    return ListTile(
      key: ValueKey('nn-node-${node.hash}'),
      leading: IconButton(
        key: ValueKey('nn-star-${node.hash}'),
        tooltip: node.favourite
            ? nt(context, 'nn_unfavourite')
            : nt(context, 'nn_favourite'),
        icon: Icon(
          node.favourite ? Icons.star : Icons.star_border,
          color: node.favourite ? Colors.amber : null,
        ),
        onPressed: () => store.setFavourite(node.hash, !node.favourite),
      ),
      title: Text(
        node.name.isEmpty ? nt(context, 'nn_never_named') : node.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          shortHash(node.hash),
          if (hopsText.isNotEmpty) hopsText,
          nt(context, 'nn_seen', {'time': formatTime(node.lastSeen)}),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'forget') {
            await store.forgetNode(node.hash);
          } else if (v == 'identify') {
            if (!node.identify) {
              final ok = await confirmIdentify(context);
              if (!ok) return;
            }
            await store.setIdentify(node.hash, !node.identify);
          }
        },
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
            value: 'identify',
            checked: node.identify,
            child: Text(nt(context, 'nn_identify')),
          ),
          PopupMenuItem(value: 'forget', child: Text(nt(context, 'nn_forget'))),
        ],
      ),
      onTap: onOpen,
    );
  }
}

/// Warns that identifying reveals this device's identity to the node.
Future<bool> confirmIdentify(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(nt(ctx, 'nn_identify_title')),
      content: Text(nt(ctx, 'nn_identify_warn')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(Strings.of(ctx).t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(nt(ctx, 'nn_enable')),
        ),
      ],
    ),
  );
  return r ?? false;
}

// ------------------------------------------------------------------- browser

class BrowserPane extends ConsumerStatefulWidget {
  const BrowserPane({super.key, required this.controller});
  final BrowserController controller;

  @override
  ConsumerState<BrowserPane> createState() => _BrowserPaneState();
}

class _BrowserPaneState extends ConsumerState<BrowserPane> {
  final _address = TextEditingController();
  final _focus = FocusNode();
  final _viewKey = GlobalKey<MicronViewState>();
  String? _shownUrl;
  bool _bookmarked = false;
  String? _lastSavedPrompt;
  String? _prefsHash;
  double _zoom = 1;
  bool _wrapAll = false;

  BrowserController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(BrowserPane old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(_sync);
      c.addListener(_sync);
    }
  }

  @override
  void dispose() {
    c.removeListener(_sync);
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _sync() {
    final u = (c.loading ? c.target : c.current)?.text;
    if (u != null && u != _shownUrl && !_focus.hasFocus) {
      _shownUrl = u;
      _address.text = u;
    }
    c.isBookmarked().then((b) {
      if (mounted && b != _bookmarked) setState(() => _bookmarked = b);
    });
    _loadPrefs();
    final a = c.pendingAnchor;
    if (a != null && c.phase == BrowserPhase.loaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewKey.currentState?.scrollToAnchor(a);
      });
      c.pendingAnchor = null;
    }
  }

  /// Loads the zoom / wrap preferences of the node being browsed.
  Future<void> _loadPrefs() async {
    final h = (c.current ?? c.target)?.hashHex;
    if (h == null || h == _prefsHash) return;
    _prefsHash = h;
    final row = await ref.read(nomadServiceProvider).store.node(h);
    if (!mounted || _prefsHash != h) return;
    setState(() {
      _zoom = row?.fontScale ?? 1;
      _wrapAll = row?.wrapAll ?? false;
    });
  }

  void _savePrefs({double? zoom, bool? wrapAll}) {
    if (zoom != null) _zoom = zoom;
    if (wrapAll != null) _wrapAll = wrapAll;
    setState(() {});
    final h = _prefsHash;
    if (h == null) return;
    ref
        .read(nomadServiceProvider)
        .store
        .setViewPrefs(h, fontScale: zoom, wrapAll: wrapAll);
  }

  void _stepZoom(double factor) =>
      _savePrefs(zoom: (_zoom * factor).clamp(micronMinZoom, micronMaxZoom));

  Future<void> _toggleIdentify() async {
    final u = c.current ?? c.target;
    if (u == null) return;
    final store = ref.read(nomadServiceProvider).store;
    final row = await store.node(u.hashHex);
    final now = row?.identify ?? false;
    if (!now) {
      if (!mounted) return;
      final ok = await confirmIdentify(context);
      if (!ok) return;
    }
    await store.setIdentify(u.hashHex, !now);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    c.dark = dark;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final status = nomadStatusText(context, c);
        final p = c.progress;
        return Column(
          children: [
            _toolbar(context),
            if (c.loading)
              LinearProgressIndicator(
                key: const ValueKey('nn-progress'),
                value: (p != null && p.phase == NomadPhase.receiving)
                    ? p.progress
                    : null,
              ),
            if (status.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  child: Text(
                    status,
                    key: const ValueKey('nn-status'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            if (c.phase == BrowserPhase.failed) _failureBanner(context),
            if (c.download != null) _downloadBanner(context),
            Expanded(child: _body(context)),
          ],
        );
      },
    );
  }

  Widget _toolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('nn-back'),
            tooltip: nt(context, 'nn_back'),
            icon: const Icon(Icons.arrow_back),
            onPressed: c.canGoBack ? c.back : null,
          ),
          IconButton(
            key: const ValueKey('nn-forward'),
            tooltip: nt(context, 'nn_forward'),
            icon: const Icon(Icons.arrow_forward),
            onPressed: c.canGoForward ? c.forward : null,
          ),
          if (c.loading)
            IconButton(
              key: const ValueKey('nn-stop'),
              tooltip: nt(context, 'nn_stop'),
              icon: const Icon(Icons.close),
              onPressed: c.cancel,
            )
          else
            IconButton(
              key: const ValueKey('nn-reload'),
              tooltip: nt(context, 'nn_reload'),
              icon: const Icon(Icons.refresh),
              onPressed: (c.current ?? c.target) == null ? null : c.reload,
            ),
          Expanded(
            child: TextField(
              key: const ValueKey('nn-address'),
              controller: _address,
              focusNode: _focus,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: nt(context, 'nn_address_hint'),
              ),
              onSubmitted: (v) {
                _shownUrl = null;
                c.open(v);
                _focus.unfocus();
              },
            ),
          ),
          IconButton(
            key: const ValueKey('nn-bookmark'),
            tooltip: _bookmarked
                ? nt(context, 'nn_bookmark_remove')
                : nt(context, 'nn_bookmark_add'),
            icon: Icon(_bookmarked ? Icons.bookmark : Icons.bookmark_border),
            onPressed: c.current == null ? null : c.toggleBookmark,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('nn-menu'),
            enabled: (c.current ?? c.target) != null,
            onSelected: (v) {
              if (v == 'copy') {
                Clipboard.setData(
                  ClipboardData(text: (c.current ?? c.target)!.text),
                );
              } else if (v == 'identify') {
                _toggleIdentify();
              } else if (v == 'wrap') {
                _savePrefs(wrapAll: !_wrapAll);
              } else if (v == 'zoom_in') {
                _stepZoom(1.15);
              } else if (v == 'zoom_out') {
                _stepZoom(1 / 1.15);
              } else if (v == 'zoom_reset') {
                _savePrefs(zoom: 1);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'copy',
                child: Text(nt(context, 'nn_copy_address')),
              ),
              PopupMenuItem(
                value: 'identify',
                child: Text(nt(context, 'nn_identify')),
              ),
              CheckedPopupMenuItem(
                key: const ValueKey('nn-menu-wrap'),
                value: 'wrap',
                checked: _wrapAll,
                child: Text(nt(context, 'nn_wrap_lines')),
              ),
              PopupMenuItem(
                key: const ValueKey('nn-menu-zoom-in'),
                value: 'zoom_in',
                child: Text(nt(context, 'nn_zoom_in')),
              ),
              PopupMenuItem(
                key: const ValueKey('nn-menu-zoom-out'),
                value: 'zoom_out',
                child: Text(nt(context, 'nn_zoom_out')),
              ),
              PopupMenuItem(
                key: const ValueKey('nn-menu-zoom-reset'),
                value: 'zoom_reset',
                child: Text(nt(context, 'nn_zoom_reset')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _failureBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('nn-failure'),
      width: double.infinity,
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              nomadFailureText(context, c),
              style: TextStyle(color: cs.onErrorContainer),
            ),
          ),
          if (c.target != null)
            TextButton(
              key: const ValueKey('nn-retry'),
              onPressed: () => c.go(c.target!),
              child: Text(nt(context, 'nn_retry')),
            ),
        ],
      ),
    );
  }

  Widget _downloadBanner(BuildContext context) {
    final d = c.download!;
    final cs = Theme.of(context).colorScheme;
    if (_lastSavedPrompt != d.name && d.savedTo == null) {
      _lastSavedPrompt = d.name;
      WidgetsBinding.instance.addPostFrameCallback((_) => c.saveDownload());
    }
    return Container(
      key: const ValueKey('nn-download'),
      width: double.infinity,
      color: cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              d.savedTo != null
                  ? nt(context, 'nn_saved', {'where': d.savedTo!})
                  : nt(context, 'nn_download_ready', {
                      'name': d.name,
                      'size': formatBytes(d.size),
                    }),
              style: TextStyle(color: cs.onSecondaryContainer),
            ),
          ),
          if (d.savedTo == null)
            TextButton(
              key: const ValueKey('nn-save'),
              onPressed: c.saveDownload,
              child: Text(nt(context, 'nn_save')),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: c.dismissDownload,
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final doc = c.document;
    if (doc == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            nt(context, 'nn_empty_page'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return MicronView(
      key: _viewKey,
      document: doc,
      zoom: _zoom,
      wrapAll: _wrapAll,
      onZoomChanged: (z) => _savePrefs(zoom: z),
      onLink: (target, data) => c.followLink(target, data),
    );
  }
}
