// Windows-only runtime regression: build with MSVC, gdiplus/shell32/dwmapi.
// Usage: probe.exe <installed libmpv directory> <output PNG directory>
// Includes the real worker, result handler and drawing code. No user media.
#include "../windows/native_player/main.cpp"
#include <vfw.h>
#pragma comment(lib, "vfw32.lib")

namespace {
bool WriteSeekableVideo(const std::filesystem::path& path) {
  AVIFileInit();
  PAVIFILE file = nullptr; PAVISTREAM stream = nullptr;
  bool ok = AVIFileOpenW(&file, path.c_str(), OF_CREATE | OF_WRITE, nullptr) == 0;
  AVISTREAMINFOW info{};
  info.fccType = streamtypeVIDEO; info.dwScale = 1; info.dwRate = 1;
  info.dwSuggestedBufferSize = 320 * 180 * 3;
  SetRect(&info.rcFrame, 0, 0, 320, 180);
  if (ok) ok = AVIFileCreateStreamW(file, &stream, &info) == 0;
  BITMAPINFOHEADER format{}; format.biSize = sizeof(format);
  format.biWidth = 320; format.biHeight = 180; format.biPlanes = 1;
  format.biBitCount = 24; format.biCompression = BI_RGB;
  format.biSizeImage = 320 * 180 * 3;
  if (ok) ok = AVIStreamSetFormat(stream, 0, &format, sizeof(format)) == 0;
  std::vector<BYTE> pixels(format.biSizeImage);
  for (int second = 0; ok && second < 6; ++second) {
    for (size_t i = 0; i < pixels.size(); i += 3) {
      pixels[i] = 0; pixels[i + 1] = second >= 3 ? 240 : 0;
      pixels[i + 2] = second < 3 ? 240 : 0;
    }
    ok = AVIStreamWrite(stream, second, 1, pixels.data(), static_cast<LONG>(pixels.size()), AVIIF_KEYFRAME, nullptr, nullptr) == 0;
  }
  if (stream) AVIStreamRelease(stream);
  if (file) AVIFileRelease(file);
  AVIFileExit();
  return ok;
}
bool SavePng(Gdiplus::Bitmap& bitmap, const std::filesystem::path& path) {
  UINT count = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  std::vector<BYTE> buffer(size);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  Gdiplus::GetImageEncoders(count, size, encoders);
  for (UINT i = 0; i < count; ++i) {
    if (std::wcscmp(encoders[i].MimeType, L"image/png") == 0)
      return bitmap.Save(path.c_str(), &encoders[i].Clsid) == Gdiplus::Ok;
  }
  return false;
}
LRESULT CALLBACK ProbeProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kSeekPreviewReady) return WindowProc(window, message, wparam, lparam);
  return DefWindowProcW(window, message, wparam, lparam);
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  SetDllDirectoryW(argv[1]);
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr);
  if (!g_mpv.Load()) return 3;
  WNDCLASSW cls{};
  cls.lpfnWndProc = ProbeProc; cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"MovaPreviewRuntimeProbe";
  RegisterClassW(&cls);
  g_window = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 1, 1,
                          HWND_MESSAGE, nullptr, cls.hInstance, nullptr);
  g_handle = g_mpv.create();
  g_mpv.set_option_string(g_handle, "config", "no");
  g_mpv.set_option_string(g_handle, "terminal", "no");
  g_mpv.initialize(g_handle);
  const auto video = std::filesystem::path(argv[2]) / L"seekable-colors.avi";
  if (!WriteSeekableVideo(video)) return 4;
  g_media_urls = {Utf8(video.wstring())};
  g_playlist_position = 0; g_seek_dragging = true; g_seek_preview_id = 1;
  SeekPreviewResult request; request.id = 1; request.index = 0; request.seconds = 1;
  StartPreviewDecode(request);
  // Emulate the cursor advancing before the older result is dispatched.
  // The old exact-id filter rejected this otherwise valid completed frame.
  g_seek_preview_id = 10;
  const auto started = GetTickCount64();
  while (!g_seek_preview_bitmap && GetTickCount64() - started < 10000) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(5);
  }
  const bool extracted = g_seek_preview_bitmap && g_seek_preview_bitmap->GetWidth() == 320 &&
                         g_seek_preview_displayed_id == 1 && g_seek_preview_image_second == 1;
  bool saved = extracted && SavePng(*g_seek_preview_bitmap, std::filesystem::path(argv[2]) / L"preview-frame.png");
  const auto extract_next = [&](int second, uint64_t id) {
    g_seek_preview_id = id;
    request.id = id; request.seconds = second;
    StartPreviewDecode(request);
    const auto started = GetTickCount64();
    while (g_seek_preview_displayed_id != id && GetTickCount64() - started < 10000) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
      Sleep(5);
    }
    std::printf("target=%d elapsed=%llu displayed=%d\n", second, GetTickCount64() - started,
                g_seek_preview_displayed_id == id);
    return g_seek_preview_displayed_id == id && g_seek_preview_image_second == second;
  };
  const bool reused = extract_next(3, 11);
  Gdiplus::Color green;
  if (g_seek_preview_bitmap) g_seek_preview_bitmap->GetPixel(160, 90, &green);
  const bool changed = green.GetG() > 200 && green.GetR() < 30;
  const bool cache_hit = extract_next(1, 12);
  Gdiplus::Color red;
  if (g_seek_preview_bitmap) g_seek_preview_bitmap->GetPixel(160, 90, &red);
  const bool restored = red.GetR() > 200 && red.GetG() < 30;
  std::printf("different_position_changed_pixels=%d cache_restored_pixels=%d\n", changed, restored);
  auto stale = std::make_unique<SeekPreviewResult>();
  stale->id = 1; stale->index = 0; stale->seconds = 1; stale->decoded = true;
  if (g_seek_preview_bitmap) stale->bitmap.reset(g_seek_preview_bitmap->Clone(0, 0, 320, 180, PixelFormat32bppARGB));
  HideSeekPreview();
  WindowProc(g_window, kSeekPreviewReady, 0, reinterpret_cast<LPARAM>(stale.release()));
  const bool rejected = !g_seek_preview_bitmap;
  {
    Gdiplus::Bitmap buttons(160, 64, PixelFormat32bppARGB);
    Gdiplus::Graphics graphics(&buttons); ConfigureGlassGraphics(graphics);
    graphics.Clear(Gdiplus::Color(255, 8, 10, 14));
    for (int selected = 0; selected < 2; ++selected) {
      const float x = 42.0f + selected * 76.0f;
      Gdiplus::RectF disc(x - 18, 14, 36, 36);
      Gdiplus::GraphicsPath path; AddRoundedRectPath(path, disc, 18);
      FillGlassSurface(graphics, path, disc, GlassDiscAlpha(false), GlassDiscAlpha(true), true);
      StrokeGlassEdge(graphics, path);
      if (selected) {
        Gdiplus::SolidBrush pearl(Gdiplus::Color(220, 245, 245, 247));
        graphics.FillEllipse(&pearl, disc);
      }
      DrawPinGlyph(graphics, x, 32, selected ? Gdiplus::Color(255, 38, 43, 48) : IconInk(), selected != 0);
    }
    graphics.Flush();
    saved = SavePng(buttons, std::filesystem::path(argv[2]) / L"pin-buttons.png") && saved;
  }
  g_running = false; g_seek_preview_condition.notify_all();
  if (g_seek_preview_worker.joinable()) g_seek_preview_worker.join();
  g_mpv.terminate_destroy(g_handle); g_handle = nullptr;
  DestroyWindow(g_window);
  Gdiplus::GdiplusShutdown(g_gdiplus_token);
  std::printf("extract=%d displayed_during_newer_target=%d stale_rejected=%d png_saved=%d\n",
              extracted, extracted, rejected, saved);
  return extracted && reused && changed && cache_hit && restored && rejected && saved ? 0 : 1;
}
