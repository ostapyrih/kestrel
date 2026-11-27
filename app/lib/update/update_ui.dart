import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../platform.dart';
import '../providers.dart';
import 'release_key.dart';
import 'releases.dart';
import 'update_outcome.dart';
import 'update_service.dart';
import 'update_strings.dart';

/// Wraps the app (via `MaterialApp.builder`) and shows an update banner on top.
class UpdateHost extends ConsumerWidget {
  const UpdateHost({super.key, required this.navigatorKey, this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(updateStateProvider).value;
    final release = st?.release;
    final working =
        st != null &&
        (st.status == UpdateStatus.downloading ||
            st.status == UpdateStatus.verifying ||
            st.status == UpdateStatus.installing);
    final show =
        st != null &&
        release != null &&
        (working ||
            (!st.dismissed &&
                (st.status == UpdateStatus.available ||
                    (st.status == UpdateStatus.error))));
    final failure = st?.failure;
    if (!show && failure == null) return child ?? const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (failure != null) UpdateFailedBanner(failure: failure),
        if (show)
          Material(
            color: scheme.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.system_update_alt,
                      color: scheme.onSecondaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        key: const ValueKey('update-banner'),
                        ut(context, 'upd_banner', {'v': '${release.version}'}),
                        style: TextStyle(color: scheme.onSecondaryContainer),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('update-details'),
                      onPressed: () {
                        final ctx = navigatorKey.currentContext;
                        if (ctx != null) showUpdateDialog(ctx);
                      },
                      child: Text(ut(context, 'upd_details')),
                    ),
                    if (!working)
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: ut(context, 'upd_later'),
                        onPressed: () =>
                            ref.read(updateServiceProvider).dismiss(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: child ?? const SizedBox.shrink()),
      ],
    );
  }
}

/// "The update did not install": shown after a start that still runs the old
/// version, with the installer log and a way to install by hand.
class UpdateFailedBanner extends ConsumerWidget {
  const UpdateFailedBanner({super.key, required this.failure});

  final UpdateOutcome failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final service = ref.read(updateServiceProvider);
    final u = failure.pending!;
    final fg = scheme.onErrorContainer;
    return Material(
      key: const ValueKey('update-failed-banner'),
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ut(context, 'upd_failed', {'v': u.target}),
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              SelectableText(
                updateFailureDetail(context, failure),
                key: const ValueKey('update-failed-log'),
                style: TextStyle(color: fg, fontSize: 12),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('update-failed-dismiss'),
                    onPressed: service.dismissFailure,
                    child: Text(ut(context, 'upd_close')),
                  ),
                  FilledButton(
                    key: const ValueKey('update-failed-manual'),
                    onPressed: () => service.installManually(failure),
                    child: Text(ut(context, 'upd_failed_manual')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showUpdateDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const UpdateDialog());

class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(updateServiceProvider);
    final st = ref.watch(updateStateProvider).value ?? service.state;
    final release = st.release;
    if (release == null) {
      return AlertDialog(
        title: Text(ut(context, 'upd_title')),
        content: Text(ut(context, 'upd_up_to_date')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ut(context, 'upd_close')),
          ),
        ],
      );
    }
    final busy =
        st.status == UpdateStatus.downloading ||
        st.status == UpdateStatus.verifying ||
        st.status == UpdateStatus.installing;
    final status = switch (st.status) {
      UpdateStatus.downloading => ut(context, 'upd_downloading'),
      UpdateStatus.verifying => ut(context, 'upd_verifying'),
      UpdateStatus.installing => ut(context, 'upd_installing'),
      _ => null,
    };
    final notes = plainChangelog(release.body);
    return AlertDialog(
      title: Text(ut(context, 'upd_available', {'v': '${release.version}'})),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ut(context, 'upd_whats_new'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SelectableText(
                notes.isEmpty ? release.tag : notes,
                key: const ValueKey('update-notes'),
              ),
              if (status != null) ...[
                const SizedBox(height: 16),
                Text(status),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: st.status == UpdateStatus.downloading
                      ? st.progress
                      : null,
                ),
              ],
              if (st.status == UpdateStatus.error) ...[
                const SizedBox(height: 16),
                Text(
                  updateErrorText(context, st),
                  key: const ValueKey('update-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (st.manualOnly) ...[
                const SizedBox(height: 16),
                Text(ut(context, 'upd_manual')),
                SelectableText(release.htmlUrl),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ut(context, 'upd_later')),
          ),
        if (st.manualOnly) ...[
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: release.htmlUrl)),
            child: Text(ut(context, 'upd_copy_link')),
          ),
          if (Platform.isLinux)
            FilledButton(
              onPressed: () => Process.run('xdg-open', [release.htmlUrl]),
              child: Text(ut(context, 'upd_open_page')),
            ),
        ] else
          FilledButton(
            key: const ValueKey('update-install'),
            onPressed: busy ? null : () => service.install(),
            child: Text(ut(context, 'upd_install')),
          ),
      ],
    );
  }
}

/// Settings block: current version, the auto-check switch and "Check now".
/// Desktop only; renders nothing on mobile.
class UpdateSettingsSection extends ConsumerWidget {
  const UpdateSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) return const SizedBox.shrink();
    final service = ref.watch(updateServiceProvider);
    if (!service.enabled) return const SizedBox.shrink();
    final st = ref.watch(updateStateProvider).value ?? service.state;
    final auto = ref.watch(settingProvider(updateAutoCheckKey)).value != '0';
    final text = Theme.of(context).textTheme;
    final line = switch (st.status) {
      UpdateStatus.checking => ut(context, 'upd_checking'),
      UpdateStatus.upToDate => ut(context, 'upd_up_to_date'),
      UpdateStatus.available => ut(context, 'upd_available', {
        'v': '${st.release?.version}',
      }),
      UpdateStatus.error => updateErrorText(context, st),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(ut(context, 'upd_title'), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          ut(context, 'upd_version', {'v': '${st.current ?? ''}'}),
          style: text.bodySmall,
        ),
        SwitchListTile(
          key: const ValueKey('update-auto'),
          contentPadding: EdgeInsets.zero,
          title: Text(ut(context, 'upd_auto')),
          value: auto,
          onChanged: (v) => ref
              .read(repoProvider)
              .setSetting(updateAutoCheckKey, v ? '1' : '0'),
        ),
        ListTile(
          key: const ValueKey('update-check-now'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.refresh),
          title: Text(ut(context, 'upd_check_now')),
          subtitle: line == null ? null : Text(line),
          onTap: st.status == UpdateStatus.checking
              ? null
              : () async {
                  await service.checkNow();
                  final s = service.state;
                  if (s.status == UpdateStatus.available && context.mounted) {
                    await showUpdateDialog(context);
                  }
                },
        ),
      ],
    );
  }
}

/// One line for the failure banner: the reason and exit code only when known.
String updateFailureDetail(BuildContext context, UpdateOutcome failure) {
  final log = failure.log;
  final parts = <String>[
    if (log != null && !log.exists)
      ut(context, 'upd_failed_nostart')
    else if (log?.reason != null)
      log!.reason!,
    if (failure.exitCode != null)
      ut(context, 'upd_failed_code', {'code': '${failure.exitCode}'}),
    ut(context, 'upd_failed_log', {'path': failure.pending!.logPath}),
  ];
  return parts.join(' ');
}
