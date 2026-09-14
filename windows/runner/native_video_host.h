#ifndef RUNNER_NATIVE_VIDEO_HOST_H_
#define RUNNER_NATIVE_VIDEO_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class NativeVideoHost {
 public:
  NativeVideoHost(flutter::BinaryMessenger* messenger, HWND flutter_view);
  ~NativeVideoHost();

  NativeVideoHost(const NativeVideoHost&) = delete;
  NativeVideoHost& operator=(const NativeVideoHost&) = delete;

 private:
  void Create();
  void SetBounds(int left, int top, int width, int height);
  void SetVisible(bool visible);
  void Dispose();

  HWND flutter_view_ = nullptr;
  HWND host_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NATIVE_VIDEO_HOST_H_
