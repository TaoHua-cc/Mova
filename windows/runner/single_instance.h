#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Vista and later; spelled out in case the SDK headers in use predate it.
#ifndef PROCESS_QUERY_LIMITED_INFORMATION
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000
#endif

// Keeps Mova a single instance on Windows: launching it again brings the
// already running window forward instead of opening a second copy.
//
// Two pieces:
//  * a named mutex, owned for the whole process lifetime. The kernel drops it
//    automatically when the process dies, so a crash can never leave Mova
//    unable to start again.
//  * an EnumWindows lookup that matches on the *executable path*, not on the
//    window class. Every Flutter app registers the very same
//    "FLUTTER_RUNNER_WIN32_WINDOW" class name, so matching on the class alone
//    would happily focus an unrelated app.
//
// Header-only on purpose: adding a .cpp would mean touching
// runner/CMakeLists.txt, which the Flutter tooling regenerates.
namespace mova {
namespace single_instance {

// Scoped to this app by GUID, and deliberately without a "Global\" prefix so a
// standard-user process does not need elevated rights to own the mutex.
constexpr const wchar_t kMutexName[] =
    L"Mova.SingleInstance.{9F2C5A31-4D6E-4F8B-9E1D-2B7A0C5E8D43}";

constexpr const wchar_t kActivateMessageName[] =
    L"Mova.SingleInstance.Activate.{9F2C5A31-4D6E-4F8B-9E1D-2B7A0C5E8D43}";

// Window class registered by windows/runner/win32_window.cpp. Only a cheap
// pre-filter before the more expensive executable-path comparison.
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// QueryFullProcessImageNameW is resolved dynamically: taking its address keeps
// this file independent of the _WIN32_WINNT value the toolchain happens to use.
typedef BOOL(WINAPI* QueryFullProcessImageNameFn)(HANDLE, DWORD, LPWSTR,
                                                  PDWORD);

inline QueryFullProcessImageNameFn QueryFullProcessImageNamePtr() {
  HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll");
  if (kernel32 == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<QueryFullProcessImageNameFn>(
      ::GetProcAddress(kernel32, "QueryFullProcessImageNameW"));
}

namespace internal {

// Case-insensitive compare, ASCII folding only. Enough for paths (drive letter
// casing) and free of any CRT dependency.
inline bool SamePath(const wchar_t* left, const wchar_t* right) {
  int i = 0;
  while (left[i] != L'\0' && right[i] != L'\0') {
    const wchar_t a = left[i];
    const wchar_t b = right[i];
    if (a != b) {
      const wchar_t upper_a =
          (a >= L'a' && a <= L'z') ? static_cast<wchar_t>(a - 32) : a;
      const wchar_t upper_b =
          (b >= L'a' && b <= L'z') ? static_cast<wchar_t>(b - 32) : b;
      if (upper_a != upper_b) {
        return false;
      }
    }
    ++i;
  }
  return left[i] == right[i];
}

struct WindowSearch {
  wchar_t executable_path[MAX_PATH];
  HWND visible;  // preferred: a window the user can actually see
  HWND hidden;   // fallback: still ours, just not on screen
};

inline BOOL CALLBACK EnumWindowsCallback(HWND window, LPARAM lparam) {
  WindowSearch* search = reinterpret_cast<WindowSearch*>(lparam);

  wchar_t class_name[128];
  class_name[0] = L'\0';
  if (::GetClassNameW(window, class_name, 128) == 0) {
    return TRUE;
  }
  if (!SamePath(class_name, kWindowClassName)) {
    return TRUE;
  }

  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0 || process_id == ::GetCurrentProcessId()) {
    return TRUE;
  }

  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return TRUE;
  }
  wchar_t path[MAX_PATH];
  path[0] = L'\0';
  DWORD size = static_cast<DWORD>(MAX_PATH);
  const QueryFullProcessImageNameFn query = QueryFullProcessImageNamePtr();
  const BOOL resolved = query != nullptr
                            ? query(process, 0, path, &size)
                            : FALSE;
  ::CloseHandle(process);
  if (!resolved || path[0] == L'\0') {
    return TRUE;
  }
  if (!SamePath(path, search->executable_path)) {
    return TRUE;
  }

  if (::IsWindowVisible(window)) {
    search->visible = window;
    return FALSE;  // good enough, stop enumerating
  }
  if (search->hidden == nullptr) {
    search->hidden = window;
  }
  return TRUE;
}

}  // namespace internal

// Handle of this process' mutex. Kept open on purpose: closing it would give up
// the "an instance is running" state while the app is still up.
inline HANDLE& InstanceMutex() {
  static HANDLE handle = nullptr;
  return handle;
}

// True when another copy of this executable is already running.
inline bool AnotherInstanceIsRunning() {
  HANDLE& handle = InstanceMutex();
  if (handle != nullptr) {
    return true;  // already asked (and won) earlier in this process
  }
  handle = ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (handle == nullptr) {
    // Never block startup because of this: if the mutex cannot be created we
    // simply behave as before and let a second window open.
    return false;
  }
  return ::GetLastError() == ERROR_ALREADY_EXISTS;
}

inline UINT ActivateMessageId() {
  return ::RegisterWindowMessageW(kActivateMessageName);
}

// Restore / show / focus. Deliberately allocation free: this runs from WndProc,
// which is noexcept.
inline void BringToFront(HWND window) {
  if (window == nullptr || !::IsWindow(window)) {
    return;
  }

  WINDOWPLACEMENT placement;
  placement.length = static_cast<UINT>(sizeof(WINDOWPLACEMENT));
  if (::GetWindowPlacement(window, &placement) &&
      placement.showCmd == SW_SHOWMINIMIZED) {
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }

  ::BringWindowToTop(window);
  if (!::SetForegroundWindow(window)) {
    // Another thread owns the foreground: borrow its input queue for the
    // duration of the call, otherwise Windows only flashes the taskbar button.
    const DWORD foreground_thread =
        ::GetWindowThreadProcessId(::GetForegroundWindow(), nullptr);
    const DWORD target_thread = ::GetWindowThreadProcessId(window, nullptr);
    if (foreground_thread != 0 && target_thread != 0 &&
        foreground_thread != target_thread) {
      ::AttachThreadInput(foreground_thread, target_thread, TRUE);
      ::BringWindowToTop(window);
      ::SetForegroundWindow(window);
      ::AttachThreadInput(foreground_thread, target_thread, FALSE);
    } else {
      ::FlashWindow(window, TRUE);
    }
  }
}

inline HWND FindExistingWindow() {
  internal::WindowSearch search;
  search.executable_path[0] = L'\0';
  search.visible = nullptr;
  search.hidden = nullptr;
  if (::GetModuleFileNameW(nullptr, search.executable_path, MAX_PATH) == 0) {
    return nullptr;
  }
  ::EnumWindows(internal::EnumWindowsCallback,
                reinterpret_cast<LPARAM>(&search));
  return search.visible != nullptr ? search.visible : search.hidden;
}

// Called by the second copy right before it quits.
inline void ActivateExistingInstance() {
  HWND window = FindExistingWindow();
  // The first copy may still be cold-starting with no window yet; give it a
  // moment before giving up on it.
  for (int attempt = 0; window == nullptr && attempt < 12; ++attempt) {
    ::Sleep(150);
    window = FindExistingWindow();
  }
  if (window != nullptr) {
    BringToFront(window);
    return;
  }
  // Nothing to focus yet: leave a broadcast behind so the first copy pops up as
  // soon as its window exists.
  const UINT message = ActivateMessageId();
  if (message != 0) {
    ::PostMessage(HWND_BROADCAST, message, 0, 0);
  }
}

// Called from Win32Window::WndProc. Returns true when |message| was the
// activate-ourself broadcast and has been handled.
inline bool HandleActivateMessage(HWND window, UINT message) {
  const UINT id = ActivateMessageId();
  if (id == 0 || message != id) {
    return false;
  }
  BringToFront(window);
  return true;
}

}  // namespace single_instance
}  // namespace mova

#endif  // RUNNER_SINGLE_INSTANCE_H_
