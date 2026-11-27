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
    required this.startedAt,
  });

  factory PendingUpdate.fromJson(Map<String, Object?> m) => PendingUpdate(
    from: '${m['from']}',
    target: '${m['target']}',
    installerPath: '${m['installer']}',
    logPath: '${m['log']}',
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['started'] as num?)?.toInt() ?? 0,
    ),
  );

  final String from;
  final String target;
  final String installerPath;

  /// The Inno Setup `/LOG=` file (Windows).
  final String logPath;

  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'from': from,
    'target': target,
    'installer': installerPath,
    'log': logPath,
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
  const UpdateOutcome(this.kind, {this.pending, this.log});

  final UpdateOutcomeKind kind;
  final PendingUpdate? pending;

  /// What the installer log says (null when it was not read).
  final InstallerLogInfo? log;

  /// The installer's exit code, only when the log states it.
  int? get exitCode => log?.exitCode;

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
  InstallerLogInfo? log,
}) {
  if (pending == null) return const UpdateOutcome(UpdateOutcomeKind.none);
  final target = AppVersion.tryParse(pending.target);
  if (target == null ||
      now.difference(pending.startedAt) > pendingUpdateMaxAge) {
    return const UpdateOutcome(UpdateOutcomeKind.none);
  }
  if (!(target > running)) {
    return UpdateOutcome(UpdateOutcomeKind.succeeded, pending: pending);
  }
  return UpdateOutcome(UpdateOutcomeKind.failed, pending: pending, log: log);
}

/// What was found in an Inno Setup `/LOG=` file.
class InstallerLogInfo {
  const InstallerLogInfo({this.exists = false, this.exitCode, this.reason});

  /// False when the installer never got to create its log (it did not start).
  final bool exists;
  final int? exitCode;

  /// The last line of the log that looks like an error, if any.
  final String? reason;
}

final _logStamp = RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d+)?\s+');
final _exitCode = RegExp(
  r'exit(?:ing)? with code[: ]+(-?\d+)|exit code[: ]+(-?\d+)',
  caseSensitive: false,
);
final _errorLine = RegExp(
  r'error|fail|exception|abort|cannot|could not|denied|in use|not allowed',
  caseSensitive: false,
);

/// Reads the interesting part from the tail of an Inno Setup log: the exit
/// code when stated and the last error-looking line.
InstallerLogInfo parseInstallerLog(String text, {int tailLines = 60}) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final tail = lines.length > tailLines
      ? lines.sublist(lines.length - tailLines)
      : lines;
  int? code;
  String? reason;
  for (final raw in tail) {
    final line = raw.replaceFirst(_logStamp, '');
    final m = _exitCode.firstMatch(line);
    if (m != null) code = int.tryParse(m.group(1) ?? m.group(2) ?? '');
    if (_errorLine.hasMatch(line) && !_exitCode.hasMatch(line)) {
      reason = line.length > 200 ? line.substring(0, 200) : line;
    }
  }
  return InstallerLogInfo(exists: true, exitCode: code, reason: reason);
}

/// Where the installer log goes: next to the download.
String updateLogPath(File installer) =>
    p.join(installer.parent.path, 'kestrel-update.log');

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

/// Reads the installer log of [u]; `exists: false` when there is none.
Future<InstallerLogInfo> readInstallerLog(PendingUpdate u) async {
  try {
    final f = File(u.logPath);
    if (!await f.exists()) return const InstallerLogInfo();
    final len = await f.length();
    final raf = await f.open();
    try {
      // only the tail matters; logs can be large
      const keep = 64 * 1024;
      if (len > keep) await raf.setPosition(len - keep);
      final bytes = await raf.read(keep);
      return parseInstallerLog(String.fromCharCodes(bytes));
    } finally {
      await raf.close();
    }
  } on Object {
    return const InstallerLogInfo();
  }
}

/// Removes the per-update temp directory (installer, log) after a success.
/// Only directories created by the updater (`kestrel-update*`) are touched.
Future<void> deleteUpdateDir(PendingUpdate u) async {
  try {
    final dir = Directory(p.dirname(u.installerPath));
    if (!p.basename(dir.path).startsWith('kestrel-update')) return;
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // best effort
  }
}
