#include "native_video_host.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <memory>

namespace {

constexpr wchar_t kNativeVideoHostClass[] = L"MovaNativeVideoHost";

LRESULT CALLBACK NativeVideoHostWindowProc(HWND window,
                                            UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) {
  if (message == WM_NCHITTEST) {
    return HTTRANSPARENT;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

void EnsureWindowClass() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSW window_class{};
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kNativeVideoHostClass;
  window_class.lpfnWndProc = NativeVideoHostWindowProc;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&window_class);
  registered = true;
}

int ReadInt(const flutter::EncodableMap& arguments, const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return 0;
  if (const auto value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value);
  }
  return 0;
}

}  // namespace

NativeVideoHost::NativeVideoHost(flutter::BinaryMessenger* messenger,
                                 HWND flutter_view)
    : flutter_view_(flutter_view) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mova/native_video_host",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "create") {
          Create();
          const auto wid = static_cast<int64_t>(
              reinterpret_cast<uintptr_t>(host_) & 0xffffffffULL);
          result->Success(flutter::EncodableValue(wid));
          return;
        }
        if (call.method_name() == "setBounds") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            SetBounds(ReadInt(*arguments, "left"), ReadInt(*arguments, "top"),
                      ReadInt(*arguments, "width"),
                      ReadInt(*arguments, "height"));
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setVisible") {
          const auto* visible = std::get_if<bool>(call.arguments());
          SetVisible(visible != nullptr && *visible);
          result->Success();
          return;
        }
        if (call.method_name() == "dispose") {
          Dispose();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

NativeVideoHost::~NativeVideoHost() { Dispose(); }

void NativeVideoHost::Create() {
  if (host_ != nullptr || flutter_view_ == nullptr) return;
  EnsureWindowClass();
  host_ = CreateWindowExW(WS_EX_NOACTIVATE, kNativeVideoHostClass, L"", WS_CHILD,
                          0, 0, 1, 1, flutter_view_, nullptr,
                          GetModuleHandle(nullptr), nullptr);
  if (host_ != nullptr) ShowWindow(host_, SW_HIDE);
}

void NativeVideoHost::SetBounds(int left, int top, int width, int height) {
  Create();
  if (host_ == nullptr) return;
  SetWindowPos(host_, HWND_TOP, left, top, (std::max)(1, width),
               (std::max)(1, height), SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void NativeVideoHost::SetVisible(bool visible) {
  if (host_ == nullptr) return;
  ShowWindow(host_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
}

void NativeVideoHost::Dispose() {
  if (host_ != nullptr) {
    DestroyWindow(host_);
    host_ = nullptr;
  }
}
