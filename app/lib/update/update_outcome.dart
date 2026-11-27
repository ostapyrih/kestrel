import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'version.dart';

/// Written right before the installer is started and read on the next start:
/// the only way to tell "updated" from "the installer failed silently and the
/// old version was reopened".
class PendingUpdate {
  PendingUpdate({
    required this.from,
    required this.target,
    required this.installerPath,
    required this.logPath,
    required this.resultPath,
    required this.startedAt,
  });

  factory PendingUpdate.fromJson(Map<String, Object?> m) => PendingUpdate(
    from: '${m['from']}',
    target: '${m['target']}',
    installerPath: '${m['installer']}',
    logPath: '${m['log']}',
    resultPath: '${m['result']}',
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['started'] as num?)?.toInt() ?? 0,
    ),
  );

  final String from;
  final String target;
  final String installerPath;

  /// The Inno Setup `/LOG=` file (Windows).
  final String logPath;

  /// The file the update script writes the installer's exit code to.
  final String resultPath;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'from': from,
    'target': target,
    'installer': installerPath,
    'log': logPath,
    'result': resultPath,
    'started': startedAt.millisecondsSinceEpoch,
  };
}

enum UpdateOutcomeKind {
  /// No update was started before this launch.
  none,

  /// The running version is the one the update was meant to install.
  succeeded,

  /// An update was started but the old version is still running.
  failed,
}

class UpdateOutcome {
  const UpdateOutcome(this.kind, {this.pending, this.exitCode});

  final UpdateOutcomeKind kind;
  final PendingUpdate? pending;

  /// The installer's exit code, when the script got to write it.
  final int? exitCode;

  bool get failed => kind == UpdateOutcomeKind.failed;
}

/// How long a marker stays meaningful: an old one (the update was started
/// long ago, the app was started by hand much later) is dropped silently.
const pendingUpdateMaxAge = Duration(days: 3);

/// Decides what a start after an update attempt means.
UpdateOutcome evaluateUpdateOutcome({
  required PendingUpdate? pending,
  required AppVersion running,
  required DateTime now,
  int? exitCode,
}) {
  if (pending == null) return const UpdateOutcome(UpdateOutcomeKind.none);
  final target = AppVersion.tryParse(pending.target);
  if (target == null || now.difference(pending.startedAt) > pendingUpdateMaxAge) {
    return const UpdateOutcome(UpdateOutcomeKind.none);
  }
  if (!(target > running)) {
    return UpdateOutcome(UpdateOutcomeKind.succeeded, pending: pending);
  }
  return UpdateOutcome(
    UpdateOutcomeKind.failed,
    pending: pending,
    exitCode: exitCode,
  );
}

/// Where the installer log and the exit code go: next to the download.
String updateLogPath(File installer) =>
    p.join(installer.parent.path, 'kestrel-update.log');
String updateResultPath(File installer) =>
    p.join(installer.parent.path, 'kestrel-update-result.txt');

/// The marker file lives in the temp directory itself (a stable place the next
/// start can find), not in the per-update subfolder.
File pendingUpdateFile(Directory tempDir) =>
    File(p.join(tempDir.path, 'kestrel-update-pending.json'));

Future<void> writePendingUpdate(Directory tempDir, PendingUpdate u) async {
  await pendingUpdateFile(tempDir).writeAsString(jsonEncode(u.toJson()));
}

Future<void> clearPendingUpdate(Directory tempDir) async {
  try {
    final f = pendingUpdateFile(tempDir);
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // best effort
  }
}

Future<PendingUpdate?> readPendingUpdate(Directory tempDir) async {
  try {
    final f = pendingUpdateFile(tempDir);
    if (!await f.exists()) return null;
    final m = jsonDecode(await f.readAsString());
    return m is Map<String, Object?> ? PendingUpdate.fromJson(m) : null;
  } on Object {
    return null;
  }
}

/// The installer's exit code from the result file, or null.
Future<int?> readInstallerExitCode(PendingUpdate u) async {
  try {
    final f = File(u.resultPath);
    if (!await f.exists()) return null;
    return int.tryParse((await f.readAsString()).trim());
  } on Object {
    return null;
  }
}
