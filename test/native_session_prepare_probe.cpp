// Feasibility gate: paused demuxer cache survives enabling the real video output.
// Synthetic video + silent PCM audio. Usage: probe <libmpv dir> <workspace output dir>.
#include "../windows/native_player/main.cpp"
#include <vfw.h>
#pragma comment(lib, "vfw32.lib")

bool WriteSessionFixture(const std::filesystem::path& path) {
  AVIFileInit();
  PAVIFILE file = nullptr; PAVISTREAM stream = nullptr; PAVISTREAM audio = nullptr;
  bool ok = AVIFileOpenW(&file, path.c_str(), OF_CREATE | OF_WRITE, nullptr) == 0;
  AVISTREAMINFOW info{};
  info.fccType = streamtypeVIDEO; info.dwScale = 1; info.dwRate = 1;
  SetRect(&info.rcFrame, 0, 0, 160, 90);
  if (ok) ok = AVIFileCreateStreamW(file, &stream, &info) == 0;
  BITMAPINFOHEADER format{}; format.biSize = sizeof(format);
  format.biWidth = 160; format.biHeight = 90; format.biPlanes = 1;
  format.biBitCount = 24; format.biSizeImage = 160 * 90 * 3;
  if (ok) ok = AVIStreamSetFormat(stream, 0, &format, sizeof(format)) == 0;
  std::vector<BYTE> pixels(format.biSizeImage, 80);
  for (int frame = 0; ok && frame < 60; ++frame)
    ok = AVIStreamWrite(stream, frame, 1, pixels.data(), static_cast<LONG>(pixels.size()), AVIIF_KEYFRAME, nullptr, nullptr) == 0;
  AVISTREAMINFOW sound{};
  sound.fccType = streamtypeAUDIO; sound.dwScale = 2;
  sound.dwRate = 88200; sound.dwSampleSize = 2;
  if (ok) ok = AVIFileCreateStreamW(file, &audio, &sound) == 0;
  WAVEFORMATEX pcm{};
  pcm.wFormatTag = WAVE_FORMAT_PCM; pcm.nChannels = 1;
  pcm.nSamplesPerSec = 44100; pcm.wBitsPerSample = 16;
  pcm.nBlockAlign = 2; pcm.nAvgBytesPerSec = 88200;
  if (ok) ok = AVIStreamSetFormat(audio, 0, &pcm, sizeof(pcm)) == 0;
  std::vector<BYTE> silence(88200, 0);
  for (int second = 0; ok && second < 60; ++second)
    ok = AVIStreamWrite(audio, second * 44100, 44100, silence.data(), 88200, 0, nullptr, nullptr) == 0;
  if (audio) AVIStreamRelease(audio);
  if (stream) AVIStreamRelease(stream);
  if (file) AVIFileRelease(file);
  AVIFileExit(); return ok;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 3 && argc != 4) return 2;
  const bool negativeAudio = argc == 4 && std::wstring(argv[3]) == L"--invalid-audio-driver";
  SetDllDirectoryW(argv[1]);
  if (!g_mpv.Load()) return 3;
  const auto fixture = std::filesystem::path(argv[2]) / L"session-fixture.avi";
  if (!WriteSessionFixture(fixture)) return 4;
  g_handle = g_mpv.create();
  const auto host = CreateWindowExW(0, L"STATIC", L"Mova session test", WS_POPUP,
                                   0, 0, 160, 90, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  SetOption(g_handle, "wid", std::to_string(reinterpret_cast<intptr_t>(host)));
  for (auto option : {std::pair{"config", "no"}, {"terminal", "no"},
                     {"vo", "null"}, {"pause", "yes"},
                     {"cache", "yes"}, {"demuxer-readahead-secs", "30"},
                     {"keep-open", "yes"}})
    SetOption(g_handle, option.first, option.second);
  if (g_mpv.initialize(g_handle) < 0) return 5;
  const auto url = Utf8(fixture.wstring());
  g_media_urls = {url, url};
  g_playlist_headers.resize(2);
  g_playlist_header_overrides.resize(2, true);
  g_playlist_resumes.resize(2, 0);
  g_playlist_native_network.resize(2, false);
  if (negativeAudio) g_player_options["vid"] = "no";
  PrepareNativeSession(1);
  const auto start = GetTickCount64();
  while (GetTickCount64() - start < 2000) {
    PollPreparedSession();
    Sleep(10);
  }
  auto* prepared = g_prepared_handle;
  auto read = [](mpv_handle* handle, const char* name) {
    char* value = g_mpv.get_property_string(handle, name);
    std::string result = value ? value : "";
    if (value) g_mpv.free(value);
    return result;
  };
  const auto before = read(prepared, "demuxer-cache-duration");
  const auto position = read(prepared, "time-pos");
  // A changed resource must not accidentally promote the old prepared stream.
  g_media_urls[1] = "changed";
  const bool rejected = !PromotePreparedSession(1) && g_prepared_handle == prepared;
  g_media_urls[1] = url;
  if (negativeAudio) g_player_options["ao"] = "auto";
  const bool changed = PromotePreparedSession(1);
  int loads = 0; int failures = 0; int lastError = 0;
  const auto promotion = GetTickCount64();
  while (GetTickCount64() - promotion < 2500) {
    auto* event = g_mpv.wait_event(g_handle, 0);
    if (event->event_id == MPV_EVENT_FILE_LOADED) ++loads;
    if (event->event_id == MPV_EVENT_END_FILE && event->data &&
        static_cast<mpv_event_end_file*>(event->data)->error < 0) {
      ++failures;
      lastError = static_cast<mpv_event_end_file*>(event->data)->error;
    }
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(5);
  }
  const auto after = MpvString("demuxer-cache-duration");
  const auto vo = MpvString("current-vo");
  const auto ao = MpvString("current-ao");
  const auto playing = MpvString("time-pos");
  const bool passed = rejected && changed && prepared == g_handle && loads == 0 &&
      std::atof(position.c_str()) < 0.1 && std::atof(before.c_str()) > 1 &&
      vo == "gpu-next" && !ao.empty() && ao != "null" && failures == 0 &&
      std::atof(playing.c_str()) > 0.5;
  std::printf("reloads=%d paused_position=%s buffered_before=%s promoted=%d buffered_after=%s vo=%s playing=%s passed=%d\n",
              loads, position.c_str(), before.c_str(), changed, after.c_str(), vo.c_str(), playing.c_str(), passed);
  std::printf("audio_output=%s audio_failures=%d error=%d\n", ao.c_str(), failures, lastError);
  PrepareNativeSession(1);
  DiscardPreparedSession();
  DiscardPreparedSession();
  const bool released = !g_prepared_handle && g_prepared_index == -1;
  const bool activeRetained = prepared == g_handle && !MpvString("time-pos").empty();
  g_mpv.terminate_destroy(g_handle); g_handle = nullptr;
  DestroyWindow(host);
  return negativeAudio ? (lastError == -14 ? 0 : 7) :
      (passed && released && activeRetained ? 0 : 6);
}
