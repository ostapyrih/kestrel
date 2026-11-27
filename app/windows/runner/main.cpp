#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance: a second launch (Start menu, relaunch after an update)
  // shows the window of the running one, which may be hidden in the tray, and
  // exits. The mutex is owned by the running process, so it is released the
  // moment that process dies (the installer closes it before relaunching).
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\KestrelSingleInstance");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = nullptr;
    for (int i = 0; i < 20 && existing == nullptr; ++i) {
      existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Kestrel");
      if (existing == nullptr) ::Sleep(100);
    }
    if (existing != nullptr) {
      ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(existing);
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
    // No window: either the other process is still starting or it is dying.
    // If it goes away within a few seconds, take over; otherwise give up.
    DWORD wait = ::WaitForSingleObject(instance_mutex, 5000);
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Kestrel", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
