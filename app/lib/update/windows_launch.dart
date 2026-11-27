import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _detachedProcess = 0x00000008;
const _createNewProcessGroup = 0x00000200;
const _createBreakawayFromJob = 0x01000000;

/// Why a process could not be started.
class LaunchException implements Exception {
  LaunchException(this.message);
  final String message;
  @override
  String toString() => 'LaunchException($message)';
}

/// Starts [commandLine] (already quoted, e.g. `"C:\a b\x.exe" /FLAG`) as a
/// process that does not depend on this one: no console, its own process group
/// and, when allowed, outside this process's job object. Unlike
/// `Process.start(..., detached)` followed by an immediate exit, the child
/// survives the parent exiting. Windows only.
void launchDetachedWindows(String commandLine) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final createProcess = k32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          Int32,
          Uint32,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        )
      >('CreateProcessW');
  final closeHandle = k32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final getLastError = k32.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );

  // STARTUPINFOW is 104 bytes on x64 (cb first); PROCESS_INFORMATION is 24.
  const siSize = 104;
  final si = calloc<Uint8>(siSize);
  final pi = calloc<Uint8>(24);
  final cmd = commandLine.toNativeUtf16(); // CreateProcessW may modify it
  try {
    si.cast<Uint32>().value = siSize;
    var ok = 0;
    var lastError = 0;
    // Breakaway needs the parent's job to allow it; fall back without it.
    for (final flags in [
      _detachedProcess | _createNewProcessGroup | _createBreakawayFromJob,
      _detachedProcess | _createNewProcessGroup,
    ]) {
      ok = createProcess(
        nullptr,
        cmd,
        nullptr,
        nullptr,
        0,
        flags,
        nullptr,
        nullptr,
        si,
        pi,
      );
      if (ok != 0) break;
      lastError = getLastError();
    }
    if (ok == 0) {
      throw LaunchException('CreateProcessW failed (error $lastError)');
    }
    final handles = pi.cast<IntPtr>();
    closeHandle(handles[0]); // hProcess
    closeHandle(handles[1]); // hThread
  } finally {
    calloc.free(cmd);
    calloc.free(si);
    calloc.free(pi);
  }
}
