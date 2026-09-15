#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <gdiplus.h>

#include <atomic>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cwctype>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

namespace {

struct mpv_handle;
enum mpv_event_id {
  MPV_EVENT_NONE = 0,
  MPV_EVENT_SHUTDOWN = 1,
  MPV_EVENT_END_FILE = 7,
  MPV_EVENT_FILE_LOADED = 8,
  MPV_EVENT_PROPERTY_CHANGE = 22,
};
enum mpv_format {
  MPV_FORMAT_NONE = 0,
  MPV_FORMAT_STRING = 1,
  MPV_FORMAT_FLAG = 3,
  MPV_FORMAT_INT64 = 4,
  MPV_FORMAT_DOUBLE = 5,
};
struct mpv_event {
  mpv_event_id event_id;
  int error;
  uint64_t reply_userdata;
  void* data;
};
struct mpv_event_property {
  const char* name;
  mpv_format format;
  void* data;
};

using CreateFn = mpv_handle* (*)();
using InitializeFn = int (*)(mpv_handle*);
using SetOptionStringFn = int (*)(mpv_handle*, const char*, const char*);
using CommandFn = int (*)(mpv_handle*, const char* const*);
using WaitEventFn = mpv_event* (*)(mpv_handle*, double);
using ObservePropertyFn = int (*)(mpv_handle*, uint64_t, const char*, mpv_format);
using TerminateDestroyFn = void (*)(mpv_handle*);
using GetPropertyStringFn = char* (*)(mpv_handle*, const char*);
using MpvFreeFn = void (*)(void*);

struct MpvApi {
  HMODULE module = nullptr;
  CreateFn create = nullptr;
  InitializeFn initialize = nullptr;
  SetOptionStringFn set_option_string = nullptr;
  CommandFn command = nullptr;
  WaitEventFn wait_event = nullptr;
  ObservePropertyFn observe_property = nullptr;
  TerminateDestroyFn terminate_destroy = nullptr;
  GetPropertyStringFn get_property_string = nullptr;
  MpvFreeFn free = nullptr;

  bool Load() {
    module = LoadLibraryW(L"libmpv-2.dll");
    if (!module) return false;
    create = reinterpret_cast<CreateFn>(GetProcAddress(module, "mpv_create"));
    initialize = reinterpret_cast<InitializeFn>(GetProcAddress(module, "mpv_initialize"));
    set_option_string = reinterpret_cast<SetOptionStringFn>(GetProcAddress(module, "mpv_set_option_string"));
    command = reinterpret_cast<CommandFn>(GetProcAddress(module, "mpv_command"));
    wait_event = reinterpret_cast<WaitEventFn>(GetProcAddress(module, "mpv_wait_event"));
    observe_property = reinterpret_cast<ObservePropertyFn>(GetProcAddress(module, "mpv_observe_property"));
    terminate_destroy = reinterpret_cast<TerminateDestroyFn>(GetProcAddress(module, "mpv_terminate_destroy"));
    get_property_string = reinterpret_cast<GetPropertyStringFn>(
        GetProcAddress(module, "mpv_get_property_string"));
    free = reinterpret_cast<MpvFreeFn>(GetProcAddress(module, "mpv_free"));
    return create && initialize && set_option_string && command && wait_event &&
           observe_property && terminate_destroy && get_property_string && free;
  }

  ~MpvApi() {
    if (module) FreeLibrary(module);
  }
};

constexpr wchar_t kWindowClass[] = L"MovaNativePlayerWindow";
constexpr UINT kMpvShutdown = WM_APP + 1;
constexpr UINT kPlayerStateChanged = WM_APP + 2;
constexpr wchar_t kControlsClass[] = L"MovaNativePlayerControls";
constexpr wchar_t kPanelClass[] = L"MovaNativePlayerPanel";
constexpr wchar_t kTopBarClass[] = L"MovaNativePlayerTopBar";

MpvApi g_mpv;
mpv_handle* g_handle = nullptr;
std::atomic<bool> g_running{true};
std::atomic<double> g_position{0};
std::atomic<double> g_duration{0};
std::atomic<bool> g_paused{false};
std::atomic<double> g_volume{100};
std::atomic<double> g_speed{1};
std::atomic<bool> g_muted{false};
std::atomic<bool> g_buffering{false};
std::atomic<double> g_cache_fraction{0};
std::atomic<int64_t> g_playlist_position{0};
std::atomic<int> g_hover_control{0};
std::atomic<double> g_seek_hover{-1};
HWND g_window = nullptr;
HWND g_controls = nullptr;
HWND g_panel = nullptr;
HWND g_top_bar = nullptr;
ULONG_PTR g_gdiplus_token = 0;
BYTE g_controls_alpha = 232;
ULONGLONG g_last_interaction = 0;
bool g_fullscreen = false;
LONG_PTR g_windowed_style = 0;
WINDOWPLACEMENT g_window_placement{sizeof(WINDOWPLACEMENT)};
std::wstring g_media_title = L"Mova";
std::vector<std::wstring> g_playlist_titles;
int g_panel_hover = -1;

struct PanelItem {
  std::wstring label;
  std::string property;
  std::string value;
  std::string toast;
  bool selected = false;
  bool enabled = true;
};
std::vector<PanelItem> g_panel_items;

void ShowControls();
std::string Utf8(const std::wstring& value);
void OpenPanel(std::vector<PanelItem> items, int anchor_x, int anchor_y);

bool MpvCommand(const char* name, const char* value = nullptr,
                const char* mode = nullptr) {
  if (!g_handle) return false;
  const char* command[] = {name, value, mode, nullptr};
  return g_mpv.command(g_handle, command) >= 0;
}

void ShowToast(const std::string& text) {
  MpvCommand("show-text", text.c_str(), "1200");
}

std::string MpvString(const std::string& property) {
  if (!g_handle) return {};
  char* value = g_mpv.get_property_string(g_handle, property.c_str());
  if (!value) return {};
  std::string result(value);
  g_mpv.free(value);
  return result;
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  std::wstring output(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      output.data(), length);
  return output;
}

struct MediaTrack {
  std::string id;
  std::wstring label;
  bool selected = false;
};

std::vector<MediaTrack> ReadTracks(const char* wanted_type) {
  std::vector<MediaTrack> tracks;
  const int count = std::atoi(MpvString("track-list/count").c_str());
  for (int index = 0; index < count; ++index) {
    const std::string prefix = "track-list/" + std::to_string(index) + "/";
    if (MpvString(prefix + "type") != wanted_type) continue;
    const std::string id = MpvString(prefix + "id");
    const std::string language = MpvString(prefix + "lang");
    const std::string title = MpvString(prefix + "title");
    std::wstring label = Wide(title);
    if (label.empty()) label = Wide(language);
    if (label.empty()) label = wanted_type == std::string("audio")
                                   ? L"音轨"
                                   : L"字幕";
    if (!language.empty() && !title.empty()) {
      label += L" · " + Wide(language);
    }
    tracks.push_back(
        {id, label, MpvString(prefix + "selected") == "yes"});
  }
  return tracks;
}

void ShowTrackMenu(HWND owner, bool audio, int anchor_x, int anchor_y) {
  const auto tracks = ReadTracks(audio ? "audio" : "sub");
  std::vector<PanelItem> items;
  if (!audio) {
    const bool off = MpvString("sid") == "no";
    items.push_back(
        {L"关闭字幕", "sid", "no", "字幕已关闭", off, true});
  }
  for (const auto& track : tracks) {
    items.push_back({track.label, audio ? "aid" : "sid", track.id,
                     std::string(audio ? "音轨：" : "字幕：") +
                         Utf8(track.label),
                     track.selected, true});
  }
  if (tracks.empty()) {
    items.push_back({audio ? L"没有其他音轨" : L"没有内嵌字幕", "", "",
                     "", false, false});
  }
  OpenPanel(std::move(items), anchor_x, anchor_y);
}

void ShowPlaybackMenu(HWND owner, int anchor_x, int anchor_y) {
  std::vector<PanelItem> items;
  const double speeds[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0};
  const wchar_t* speed_labels[] = {L"0.5×", L"0.75×", L"正常速度",
                                   L"1.25×", L"1.5×", L"2.0×"};
  for (int index = 0; index < 6; ++index) {
    const bool selected = std::abs(g_speed.load() - speeds[index]) < 0.01;
    const std::string value = std::to_string(speeds[index]);
    items.push_back({speed_labels[index], "speed", value,
                     "播放速度 " + value + "×", selected, true});
  }
  items.push_back({L"画面比例 · 自动", "video-aspect-override", "0",
                   "画面比例 自动"});
  items.push_back({L"画面比例 · 16:9", "video-aspect-override", "16:9",
                   "画面比例 16:9"});
  items.push_back({L"画面比例 · 4:3", "video-aspect-override", "4:3",
                   "画面比例 4:3"});
  items.push_back({L"画面比例 · 21:9", "video-aspect-override", "21:9",
                   "画面比例 21:9"});
  OpenPanel(std::move(items), anchor_x, anchor_y);
}

void ShowPlaylistMenu(int anchor_x, int anchor_y) {
  std::vector<PanelItem> items;
  for (size_t index = 0; index < g_playlist_titles.size(); ++index) {
    const std::string value = std::to_string(index);
    std::wstring label = std::to_wstring(index + 1) + L"  " +
                         g_playlist_titles[index];
    items.push_back({label, "playlist-pos", value,
                     "正在播放 " + Utf8(g_playlist_titles[index]),
                     static_cast<int64_t>(index) == g_playlist_position.load(),
                     true});
  }
  if (items.empty()) {
    items.push_back({L"当前内容没有剧集列表", "", "", "", false, false});
  }
  OpenPanel(std::move(items), anchor_x, anchor_y);
}

void EmitProgress(double position, double duration) {
  char text[128]{};
  const int length = std::snprintf(text, sizeof(text),
                                   "MOVA_POSITION=%.3f|%.3f|%lld\r\n", position,
                                   duration,
                                   static_cast<long long>(g_playlist_position.load()));
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE && length > 0) {
    DWORD written = 0;
    WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
  }
}

void PositionControls() {
  if (!g_window || !g_controls) return;
  RECT client{};
  GetClientRect(g_window, &client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  const int client_width = static_cast<int>(client.right - client.left);
  const int width = std::min(960, std::max(520, client_width - 40));
  const int height = 96;
  SetWindowPos(g_controls, HWND_TOP, origin.x + (client.right - width) / 2,
               origin.y + client.bottom - height - 24, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  SetWindowRgn(g_controls, CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                              28, 28), TRUE);
  InvalidateRect(g_controls, nullptr, FALSE);
  if (g_top_bar) {
    const int top_width =
        std::min(760, std::max(460, client_width - 40));
    const int top_height = 54;
    SetWindowPos(g_top_bar, HWND_TOP,
                 origin.x + (client_width - top_width) / 2, origin.y + 16,
                 top_width, top_height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowRgn(g_top_bar,
                 CreateRoundRectRgn(0, 0, top_width + 1, top_height + 1, 28,
                                    28),
                 TRUE);
    InvalidateRect(g_top_bar, nullptr, FALSE);
  }
}

void ShowControls() {
  g_last_interaction = GetTickCount64();
  if (g_controls) {
    ShowWindow(g_controls, SW_SHOWNOACTIVATE);
  }
  if (g_top_bar) ShowWindow(g_top_bar, SW_SHOWNOACTIVATE);
  SetCursor(LoadCursor(nullptr, IDC_ARROW));
}

void ToggleFullscreen() {
  if (!g_window) return;
  const LONG_PTR style = GetWindowLongPtrW(g_window, GWL_STYLE);
  if (!g_fullscreen) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (GetWindowPlacement(g_window, &g_window_placement) &&
        GetMonitorInfoW(MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      SetWindowLongPtrW(g_window, GWL_STYLE, style & ~WS_THICKFRAME);
      SetWindowPos(g_window, HWND_TOP, monitor.rcMonitor.left,
                   monitor.rcMonitor.top,
                   monitor.rcMonitor.right - monitor.rcMonitor.left,
                   monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
      g_fullscreen = true;
    }
  } else {
    SetWindowLongPtrW(g_window, GWL_STYLE, g_windowed_style);
    SetWindowPlacement(g_window, &g_window_placement);
    SetWindowPos(g_window, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                     SWP_NOZORDER | SWP_NOOWNERZORDER);
    g_fullscreen = false;
  }
  PositionControls();
}

void DrawPlayIcon(Gdiplus::Graphics& graphics, float x, float y, bool paused) {
  Gdiplus::SolidBrush ink(Gdiplus::Color(255, 18, 18, 20));
  if (paused) {
    Gdiplus::PointF points[] = {{x - 5, y - 11}, {x + 11, y},
                               {x - 5, y + 11}};
    graphics.FillPolygon(&ink, points, 3);
  } else {
    graphics.FillRectangle(&ink, Gdiplus::RectF(x - 7, y - 11, 5, 22));
    graphics.FillRectangle(&ink, Gdiplus::RectF(x + 3, y - 11, 5, 22));
  }
}

void DrawSpeaker(Gdiplus::Graphics& graphics, float x, float y, bool muted) {
  Gdiplus::Pen pen(Gdiplus::Color(255, 245, 245, 247), 2.0f);
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
  Gdiplus::PointF speaker[] = {{x - 10, y - 4}, {x - 5, y - 4},
                              {x + 1, y - 10}, {x + 1, y + 10},
                              {x - 5, y + 4}, {x - 10, y + 4}};
  graphics.DrawPolygon(&pen, speaker, 6);
  if (muted) {
    graphics.DrawLine(&pen, x + 6, y - 6, x + 16, y + 6);
    graphics.DrawLine(&pen, x + 16, y - 6, x + 6, y + 6);
  } else {
    graphics.DrawArc(&pen, Gdiplus::RectF(x - 4, y - 9, 19, 18), -55, 110);
  }
}

void DrawFullscreen(Gdiplus::Graphics& graphics, float x, float y) {
  Gdiplus::Pen pen(Gdiplus::Color(255, 245, 245, 247), 2.0f);
  graphics.DrawLine(&pen, x - 9, y - 3, x - 9, y - 9);
  graphics.DrawLine(&pen, x - 9, y - 9, x - 3, y - 9);
  graphics.DrawLine(&pen, x + 3, y - 9, x + 9, y - 9);
  graphics.DrawLine(&pen, x + 9, y - 9, x + 9, y - 3);
  graphics.DrawLine(&pen, x - 9, y + 3, x - 9, y + 9);
  graphics.DrawLine(&pen, x - 9, y + 9, x - 3, y + 9);
  graphics.DrawLine(&pen, x + 3, y + 9, x + 9, y + 9);
  graphics.DrawLine(&pen, x + 9, y + 9, x + 9, y + 3);
}

void ConfigureControlPen(Gdiplus::Pen& pen) {
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
}

void DrawSkipIcon(Gdiplus::Graphics& graphics, float x, float y, bool next) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  const float direction = next ? 1.0f : -1.0f;
  graphics.DrawLine(&pen, x + direction * 8, y - 9, x + direction * 8, y + 9);
  Gdiplus::PointF triangle[] = {
      {x + direction * 5, y}, {x - direction * 7, y - 8},
      {x - direction * 7, y + 8}};
  Gdiplus::SolidBrush brush(Gdiplus::Color(242, 245, 245, 247));
  graphics.FillPolygon(&brush, triangle, 3);
}

void DrawSeekIcon(Gdiplus::Graphics& graphics, float x, float y, bool forward) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  const float start = forward ? -70.0f : 110.0f;
  graphics.DrawArc(&pen, Gdiplus::RectF(x - 10, y - 10, 20, 20), start, 255);
  Gdiplus::PointF arrow[3]{};
  if (forward) {
    arrow[0] = {x + 7, y - 11};
    arrow[1] = {x + 13, y - 9};
    arrow[2] = {x + 9, y - 4};
  } else {
    arrow[0] = {x - 7, y - 11};
    arrow[1] = {x - 13, y - 9};
    arrow[2] = {x - 9, y - 4};
  }
  Gdiplus::SolidBrush brush(Gdiplus::Color(242, 245, 245, 247));
  graphics.FillPolygon(&brush, arrow, 3);
  Gdiplus::Font number(L"Segoe UI Variable", 8, Gdiplus::FontStyleBold,
                        Gdiplus::UnitPixel);
  Gdiplus::StringFormat centered;
  centered.SetAlignment(Gdiplus::StringAlignmentCenter);
  centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  graphics.DrawString(L"10", -1, &number, Gdiplus::RectF(x - 8, y - 7, 16, 14),
                      &centered, &brush);
}

void DrawAudioIcon(Gdiplus::Graphics& graphics, float x, float y) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  const float heights[] = {5, 11, 16, 9};
  for (int i = 0; i < 4; ++i) {
    const float px = x - 9 + i * 6;
    graphics.DrawLine(&pen, px, y - heights[i] / 2, px, y + heights[i] / 2);
  }
}

void DrawSubtitleIcon(Gdiplus::Graphics& graphics, float x, float y) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  graphics.DrawRectangle(&pen, Gdiplus::RectF(x - 11, y - 8, 22, 16));
  graphics.DrawLine(&pen, x - 7, y + 2, x - 1, y + 2);
  graphics.DrawLine(&pen, x + 2, y + 2, x + 7, y + 2);
}

void DrawPlaylistIcon(Gdiplus::Graphics& graphics, float x, float y) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  Gdiplus::SolidBrush dot(Gdiplus::Color(242, 245, 245, 247));
  for (int row = -1; row <= 1; ++row) {
    graphics.FillEllipse(&dot,
                         Gdiplus::RectF(x - 10, y + row * 7 - 1, 2, 2));
    graphics.DrawLine(&pen, x - 4, y + row * 7, x + 10, y + row * 7);
  }
}

void DrawSettingsIcon(Gdiplus::Graphics& graphics, float x, float y) {
  Gdiplus::Pen pen(Gdiplus::Color(242, 245, 245, 247), 1.8f);
  ConfigureControlPen(pen);
  graphics.DrawLine(&pen, x - 10, y - 6, x + 10, y - 6);
  graphics.DrawLine(&pen, x - 10, y, x + 10, y);
  graphics.DrawLine(&pen, x - 10, y + 6, x + 10, y + 6);
  Gdiplus::SolidBrush knob(Gdiplus::Color(255, 245, 245, 247));
  graphics.FillEllipse(&knob, Gdiplus::RectF(x - 5, y - 9, 6, 6));
  graphics.FillEllipse(&knob, Gdiplus::RectF(x + 2, y - 3, 6, 6));
  graphics.FillEllipse(&knob, Gdiplus::RectF(x - 2, y + 3, 6, 6));
}

void FillPill(Gdiplus::Graphics& graphics, Gdiplus::Brush& brush, float x,
              float y, float width, float height) {
  const float radius = height / 2.0f;
  graphics.FillRectangle(&brush,
                         Gdiplus::RectF(x + radius, y, width - height, height));
  graphics.FillEllipse(&brush, Gdiplus::RectF(x, y, height, height));
  graphics.FillEllipse(&brush,
                       Gdiplus::RectF(x + width - height, y, height, height));
}

enum ControlId {
  kNone = 0,
  kBackTen,
  kPreviousEpisode,
  kPlayPause,
  kForwardTen,
  kNextEpisode,
  kMute,
  kVolume,
  kAudio,
  kSubtitle,
  kFullscreen,
  kPlaybackSettings,
  kPlaylist,
};

ControlId HitControl(int x, int y, int width) {
  if (y < 34) return kNone;
  const bool compact = width < 780;
  const int center = width / 2;
  if (!compact && x >= center - 166 && x < center - 116)
    return kPreviousEpisode;
  if (x >= center - 104 && x < center - 48) return kBackTen;
  if (x >= center - 28 && x <= center + 28) return kPlayPause;
  if (x > center + 48 && x <= center + 104) return kForwardTen;
  if (!compact && x > center + 116 && x <= center + 166)
    return kNextEpisode;
  if (x >= width - 304 && x < width - 270) return kMute;
  if (x >= width - 270 && x < width - 196) return kVolume;
  if (!compact && x >= width - 194 && x < width - 158) return kAudio;
  if (x >= width - 156 && x < width - 120) return kSubtitle;
  if (!compact && x >= width - 118 && x < width - 82) return kPlaylist;
  if (x >= width - 80 && x < width - 44) return kPlaybackSettings;
  if (x >= width - 42) return kFullscreen;
  return kNone;
}

void DrawHover(Gdiplus::Graphics& graphics, ControlId id, float x, float y,
               float size = 38) {
  if (g_hover_control.load() != id) return;
  Gdiplus::SolidBrush hover(Gdiplus::Color(42, 255, 255, 255));
  graphics.FillEllipse(&hover,
                       Gdiplus::RectF(x - size / 2, y - size / 2, size, size));
}

LRESULT CALLBACK PanelProc(HWND window, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      HDC buffer_dc = CreateCompatibleDC(dc);
      HBITMAP bitmap = CreateCompatibleBitmap(dc, rect.right, rect.bottom);
      HGDIOBJ old_bitmap = SelectObject(buffer_dc, bitmap);
      {
        Gdiplus::Graphics graphics(buffer_dc);
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        graphics.Clear(Gdiplus::Color(248, 27, 28, 33));
        Gdiplus::Font font(L"Segoe UI Variable", 13,
                           Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush text(Gdiplus::Color(255, 244, 244, 247));
        Gdiplus::SolidBrush disabled(Gdiplus::Color(120, 174, 176, 184));
        Gdiplus::SolidBrush hover(Gdiplus::Color(38, 255, 255, 255));
        Gdiplus::SolidBrush accent(Gdiplus::Color(255, 62, 135, 255));
        Gdiplus::StringFormat format;
        format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        for (size_t index = 0; index < g_panel_items.size(); ++index) {
          const float top = 8.0f + static_cast<float>(index) * 40.0f;
          if (g_panel_hover == static_cast<int>(index) &&
              g_panel_items[index].enabled) {
            FillPill(graphics, hover, 8, top, rect.right - 16.0f, 36);
          }
          if (g_panel_items[index].selected) {
            graphics.FillEllipse(&accent, Gdiplus::RectF(18, top + 14, 8, 8));
          }
          graphics.DrawString(
              g_panel_items[index].label.c_str(), -1, &font,
              Gdiplus::RectF(36, top, rect.right - 50.0f, 36), &format,
              g_panel_items[index].enabled ? &text : &disabled);
        }
        graphics.Flush(Gdiplus::FlushIntentionSync);
      }
      BitBlt(dc, 0, 0, rect.right, rect.bottom, buffer_dc, 0, 0, SRCCOPY);
      SelectObject(buffer_dc, old_bitmap);
      DeleteObject(bitmap);
      DeleteDC(buffer_dc);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const int index = (GET_Y_LPARAM(lparam) - 8) / 40;
      const int next = index >= 0 && index < static_cast<int>(g_panel_items.size())
                           ? index
                           : -1;
      if (g_panel_hover != next) {
        g_panel_hover = next;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const int index = (GET_Y_LPARAM(lparam) - 8) / 40;
      if (index >= 0 && index < static_cast<int>(g_panel_items.size())) {
        const auto item = g_panel_items[index];
        if (item.enabled && !item.property.empty()) {
          MpvCommand("set", item.property.c_str(), item.value.c_str());
          if (!item.toast.empty()) ShowToast(item.toast);
          ShowWindow(window, SW_HIDE);
          SetFocus(g_window);
          ShowControls();
        }
      }
      return 0;
    }
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        ShowWindow(window, SW_HIDE);
        SetFocus(g_window);
        return 0;
      }
      return DefWindowProcW(window, message, wparam, lparam);
    case WM_KILLFOCUS:
      ShowWindow(window, SW_HIDE);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

void OpenPanel(std::vector<PanelItem> items, int anchor_x, int anchor_y) {
  if (!g_panel) return;
  g_panel_items = std::move(items);
  g_panel_hover = -1;
  const int width = 260;
  const int height = 16 + static_cast<int>(g_panel_items.size()) * 40;
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int x = std::clamp(anchor_x - width,
                           static_cast<int>(work_area.left) + 8,
                           static_cast<int>(work_area.right) - width - 8);
  const int y = std::max(static_cast<int>(work_area.top) + 8,
                         anchor_y - height - 8);
  SetWindowPos(g_panel, HWND_TOP, x, y, width, height,
               SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
  SetWindowRgn(g_panel,
               CreateRoundRectRgn(0, 0, width + 1, height + 1, 28, 28), TRUE);
  InvalidateRect(g_panel, nullptr, FALSE);
  SetForegroundWindow(g_panel);
  SetFocus(g_panel);
}

int g_top_hover = 0;

int TopHit(int x, int width) {
  if (x >= width - 52) return 3;
  if (x >= width - 104) return 2;
  if (x >= width - 156) return 1;
  return 0;
}

LRESULT CALLBACK TopBarProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      HDC buffer_dc = CreateCompatibleDC(dc);
      HBITMAP bitmap = CreateCompatibleBitmap(dc, rect.right, rect.bottom);
      HGDIOBJ old_bitmap = SelectObject(buffer_dc, bitmap);
      {
        Gdiplus::Graphics graphics(buffer_dc);
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        Gdiplus::LinearGradientBrush surface(
            Gdiplus::Point(0, 0), Gdiplus::Point(0, rect.bottom),
            Gdiplus::Color(235, 42, 43, 49),
            Gdiplus::Color(242, 18, 19, 23));
        graphics.FillRectangle(&surface, 0, 0, rect.right, rect.bottom);
        Gdiplus::SolidBrush title_brush(Gdiplus::Color(235, 244, 244, 247));
        Gdiplus::Font title_font(L"Segoe UI Variable", 14,
                                 Gdiplus::FontStyleRegular,
                                 Gdiplus::UnitPixel);
        Gdiplus::StringFormat title_format;
        title_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        title_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
        graphics.DrawString(g_media_title.c_str(), -1, &title_font,
                            Gdiplus::RectF(22, 0, rect.right - 200.0f,
                                           static_cast<float>(rect.bottom)),
                            &title_format, &title_brush);
        Gdiplus::Pen icon(Gdiplus::Color(235, 244, 244, 247), 1.6f);
        for (int button = 1; button <= 3; ++button) {
          const float x = rect.right - (3 - button) * 52.0f - 26.0f;
          if (g_top_hover == button) {
            Gdiplus::SolidBrush hover(
                button == 3 ? Gdiplus::Color(210, 255, 69, 58)
                            : Gdiplus::Color(42, 255, 255, 255));
            graphics.FillEllipse(&hover, Gdiplus::RectF(x - 18, 11, 36, 36));
          }
          if (button == 1) {
            graphics.DrawLine(&icon, x - 7.0f, 29.0f, x + 7.0f, 29.0f);
          } else if (button == 2) {
            graphics.DrawRectangle(&icon,
                                   Gdiplus::RectF(x - 7.0f, 21.0f, 14.0f,
                                                  14.0f));
          } else {
            graphics.DrawLine(&icon, x - 6.0f, 23.0f, x + 6.0f, 35.0f);
            graphics.DrawLine(&icon, x + 6.0f, 23.0f, x - 6.0f, 35.0f);
          }
        }
        graphics.Flush(Gdiplus::FlushIntentionSync);
      }
      BitBlt(dc, 0, 0, rect.right, rect.bottom, buffer_dc, 0, 0, SRCCOPY);
      SelectObject(buffer_dc, old_bitmap);
      DeleteObject(bitmap);
      DeleteDC(buffer_dc);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_MOUSEMOVE: {
      ShowControls();
      RECT rect{};
      GetClientRect(window, &rect);
      const int hover = TopHit(GET_X_LPARAM(lparam), rect.right);
      if (g_top_hover != hover) {
        g_top_hover = hover;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      RECT rect{};
      GetClientRect(window, &rect);
      const int hit = TopHit(GET_X_LPARAM(lparam), rect.right);
      if (hit == 1) {
        ShowWindow(g_window, SW_MINIMIZE);
      } else if (hit == 2) {
        ShowWindow(g_window, IsZoomed(g_window) ? SW_RESTORE : SW_MAXIMIZE);
      } else if (hit == 3) {
        SendMessageW(g_window, WM_CLOSE, 0, 0);
      } else {
        ReleaseCapture();
        SendMessageW(g_window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      }
      return 0;
    }
    case WM_LBUTTONDBLCLK:
      ShowWindow(g_window, IsZoomed(g_window) ? SW_RESTORE : SW_MAXIMIZE);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

LRESULT CALLBACK ControlsProc(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      const int pixel_width = rect.right - rect.left;
      const int pixel_height = rect.bottom - rect.top;
      HDC buffer_dc = CreateCompatibleDC(dc);
      HBITMAP buffer_bitmap =
          CreateCompatibleBitmap(dc, pixel_width, pixel_height);
      HGDIOBJ previous_bitmap = SelectObject(buffer_dc, buffer_bitmap);
      {
      Gdiplus::Graphics graphics(buffer_dc);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      Gdiplus::LinearGradientBrush surface(
          Gdiplus::Point(0, 0), Gdiplus::Point(0, rect.bottom),
          Gdiplus::Color(218, 36, 37, 43), Gdiplus::Color(232, 16, 17, 21));
      graphics.FillRectangle(&surface, 0, 0, rect.right, rect.bottom);
      const float width = static_cast<float>(rect.right);
      const double duration = g_duration.load();
      const double position = g_position.load();
      const float fraction = duration > 0
                                 ? static_cast<float>(std::min(1.0, position / duration))
                                 : 0.0f;
      Gdiplus::Pen track(Gdiplus::Color(110, 138, 141, 148), 4);
      track.SetStartCap(Gdiplus::LineCapRound);
      track.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&track, 24.0f, 19.0f, width - 24.0f, 19.0f);
      const float cached = static_cast<float>(
          std::clamp(g_cache_fraction.load(), 0.0, 1.0));
      Gdiplus::Pen cache_progress(Gdiplus::Color(190, 174, 176, 184), 4);
      cache_progress.SetStartCap(Gdiplus::LineCapRound);
      cache_progress.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&cache_progress, 24.0f, 19.0f,
                        24.0f + (width - 48.0f) * cached, 19.0f);
      Gdiplus::Pen progress(Gdiplus::Color(255, 255, 255, 255), 4);
      progress.SetStartCap(Gdiplus::LineCapRound);
      progress.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&progress, 24.0f, 19.0f,
                        24.0f + (width - 48.0f) * fraction, 19.0f);
      const float played_x = 24.0f + (width - 48.0f) * fraction;
      const double hover_fraction = g_seek_hover.load();
      const bool hovering_seek = hover_fraction >= 0;
      Gdiplus::SolidBrush thumb(Gdiplus::Color(255, 255, 255, 255));
      const float thumb_size = hovering_seek ? 10.0f : 7.0f;
      graphics.FillEllipse(
          &thumb, Gdiplus::RectF(played_x - thumb_size / 2,
                                 19.0f - thumb_size / 2, thumb_size,
                                 thumb_size));
      if (hovering_seek && duration > 0) {
        const float hover_x =
            24.0f + (width - 48.0f) * static_cast<float>(hover_fraction);
        Gdiplus::Pen marker(Gdiplus::Color(190, 255, 255, 255), 1.0f);
        graphics.DrawLine(&marker, hover_x, 15.0f, hover_x, 23.0f);
        const int preview_seconds =
            static_cast<int>(duration * hover_fraction);
        wchar_t preview[24]{};
        swprintf_s(preview, L"%02d:%02d", preview_seconds / 60,
                   preview_seconds % 60);
        const float bubble_x = std::clamp(hover_x - 25.0f, 2.0f, width - 52.0f);
        Gdiplus::SolidBrush bubble(Gdiplus::Color(245, 55, 57, 64));
        FillPill(graphics, bubble, bubble_x, 0, 50, 16);
        Gdiplus::Font preview_font(L"Segoe UI Variable", 9,
                                   Gdiplus::FontStyleRegular,
                                   Gdiplus::UnitPixel);
        Gdiplus::StringFormat preview_format;
        preview_format.SetAlignment(Gdiplus::StringAlignmentCenter);
        preview_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        graphics.DrawString(preview, -1, &preview_font,
                            Gdiplus::RectF(bubble_x, 0, 50, 16),
                            &preview_format, &thumb);
      }

      const float center = width / 2;
      Gdiplus::SolidBrush white(Gdiplus::Color(255, 248, 248, 250));
      Gdiplus::SolidBrush quiet(Gdiplus::Color(255, 174, 176, 184));
      const float controls_y = 64.0f;
      const bool compact = width < 780;
      DrawHover(graphics, kBackTen, center - 76, controls_y);
      DrawHover(graphics, kForwardTen, center + 76, controls_y);
      if (!compact) {
        DrawHover(graphics, kPreviousEpisode, center - 140, controls_y);
        DrawHover(graphics, kNextEpisode, center + 140, controls_y);
      }
      graphics.FillEllipse(&white,
                           Gdiplus::RectF(center - 23, controls_y - 23, 46, 46));
      DrawPlayIcon(graphics, center, controls_y, g_paused.load());
      Gdiplus::Font font(L"Segoe UI Variable", 13, Gdiplus::FontStyleRegular,
                         Gdiplus::UnitPixel);
      Gdiplus::StringFormat centered;
      centered.SetAlignment(Gdiplus::StringAlignmentCenter);
      centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      DrawSeekIcon(graphics, center - 76, controls_y, false);
      DrawSeekIcon(graphics, center + 76, controls_y, true);
      if (!compact) {
        DrawSkipIcon(graphics, center - 140, controls_y, false);
        DrawSkipIcon(graphics, center + 140, controls_y, true);
      }
      wchar_t time[64]{};
      const auto seconds = static_cast<int>(position);
      const auto total = static_cast<int>(duration);
      swprintf_s(time, L"%02d:%02d  /  %02d:%02d", seconds / 60,
                 seconds % 60, total / 60, total % 60);
      if (g_buffering.load()) {
        Gdiplus::SolidBrush accent(Gdiplus::Color(255, 110, 168, 255));
        graphics.FillEllipse(&accent, Gdiplus::RectF(25, 61, 6, 6));
        Gdiplus::Font status_font(L"Segoe UI Variable", 11,
                                  Gdiplus::FontStyleRegular,
                                  Gdiplus::UnitPixel);
        graphics.DrawString(L"缓冲中", -1, &status_font,
                            Gdiplus::PointF(37, 55), &accent);
      } else {
        graphics.DrawString(time, -1, &font, Gdiplus::PointF(24, 56), &quiet);
      }
      DrawHover(graphics, kMute, width - 287, controls_y);
      DrawSpeaker(graphics, width - 289, controls_y, g_muted.load());
      Gdiplus::Pen volume_track(Gdiplus::Color(120, 174, 176, 184), 3);
      volume_track.SetStartCap(Gdiplus::LineCapRound);
      volume_track.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&volume_track, width - 265.0f, controls_y,
                        width - 207.0f, controls_y);
      const float volume_fraction = static_cast<float>(
          std::clamp(g_volume.load() / 100.0, 0.0, 1.0));
      Gdiplus::Pen volume_value(Gdiplus::Color(255, 245, 245, 247), 3);
      volume_value.SetStartCap(Gdiplus::LineCapRound);
      volume_value.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&volume_value, width - 265.0f, controls_y,
                        width - 265.0f + 58.0f * volume_fraction, controls_y);
      graphics.FillEllipse(&white,
                           Gdiplus::RectF(width - 268 + 58 * volume_fraction,
                                          controls_y - 3, 6, 6));
      if (!compact) {
        DrawHover(graphics, kAudio, width - 176, controls_y);
        DrawAudioIcon(graphics, width - 176, controls_y);
        DrawHover(graphics, kPlaylist, width - 100, controls_y);
        DrawPlaylistIcon(graphics, width - 100, controls_y);
      }
      DrawHover(graphics, kSubtitle, width - 138, controls_y);
      DrawSubtitleIcon(graphics, width - 138, controls_y);
      DrawHover(graphics, kPlaybackSettings, width - 62, controls_y);
      DrawSettingsIcon(graphics, width - 62, controls_y);
      DrawHover(graphics, kFullscreen, width - 24, controls_y);
      DrawFullscreen(graphics, width - 24, controls_y);
      graphics.Flush(Gdiplus::FlushIntentionSync);
      }
      BitBlt(dc, 0, 0, pixel_width, pixel_height, buffer_dc, 0, 0, SRCCOPY);
      SelectObject(buffer_dc, previous_bitmap);
      DeleteObject(buffer_bitmap);
      DeleteDC(buffer_dc);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_LBUTTONDOWN: {
      ShowControls();
      RECT rect{};
      GetClientRect(window, &rect);
      const int x = GET_X_LPARAM(lparam);
      const int y = GET_Y_LPARAM(lparam);
      const int center = rect.right / 2;
      if (y <= 34 && g_duration.load() > 0) {
        const double fraction = std::max(
            0.0, std::min(1.0, (x - 24.0) / (rect.right - 48.0)));
        const std::string target = std::to_string(fraction * 100.0);
        MpvCommand("seek", target.c_str(), "absolute-percent");
      } else if (HitControl(x, y, rect.right) == kPlaybackSettings) {
        POINT anchor{rect.right - 44, 40};
        ClientToScreen(window, &anchor);
        ShowPlaybackMenu(window, anchor.x, anchor.y);
      } else if (HitControl(x, y, rect.right) == kPlaylist) {
        POINT anchor{rect.right - 82, 40};
        ClientToScreen(window, &anchor);
        ShowPlaylistMenu(anchor.x, anchor.y);
      } else if (x >= center - 28 && x <= center + 28) {
        MpvCommand("cycle", "pause");
      } else if (x >= center - 166 && x < center - 116) {
        MpvCommand("playlist-prev", "weak");
        ShowToast("上一集");
      } else if (x >= center - 104 && x < center - 48) {
        MpvCommand("seek", "-10", "relative");
        ShowToast("后退 10 秒");
      } else if (x > center + 48 && x <= center + 104) {
        MpvCommand("seek", "10", "relative");
        ShowToast("前进 10 秒");
      } else if (x > center + 116 && x <= center + 166) {
        MpvCommand("playlist-next", "weak");
        ShowToast("下一集");
      } else {
        switch (HitControl(x, y, rect.right)) {
          case kMute:
            MpvCommand("cycle", "mute");
            break;
          case kVolume: {
            const double volume = std::clamp(
                (x - (rect.right - 265.0)) / 58.0 * 100.0, 0.0, 100.0);
            const std::string value = std::to_string(volume);
            MpvCommand("set", "volume", value.c_str());
            break;
          }
          case kAudio:
            {
              POINT anchor{rect.right - 158, 40};
              ClientToScreen(window, &anchor);
              ShowTrackMenu(window, true, anchor.x, anchor.y);
            }
            break;
          case kSubtitle:
            {
              POINT anchor{rect.right - 120, 40};
              ClientToScreen(window, &anchor);
              ShowTrackMenu(window, false, anchor.x, anchor.y);
            }
            break;
          case kFullscreen:
            ToggleFullscreen();
            break;
          case kPlaybackSettings: {
            POINT anchor{rect.right - 44, 40};
            ClientToScreen(window, &anchor);
            ShowPlaybackMenu(window, anchor.x, anchor.y);
            break;
          }
          case kPlaylist: {
            POINT anchor{rect.right - 82, 40};
            ClientToScreen(window, &anchor);
            ShowPlaylistMenu(anchor.x, anchor.y);
            break;
          }
          default:
            break;
        }
      }
      return 0;
    }
    case WM_MOUSEWHEEL:
      ShowControls();
      MpvCommand("add", "volume",
                 GET_WHEEL_DELTA_WPARAM(wparam) > 0 ? "5" : "-5");
      return 0;
    case WM_MOUSEMOVE: {
      ShowControls();
      RECT rect{};
      GetClientRect(window, &rect);
      TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT), TME_LEAVE, window, 0};
      TrackMouseEvent(&tracking);
      const int mouse_x = GET_X_LPARAM(lparam);
      const int mouse_y = GET_Y_LPARAM(lparam);
      if (mouse_y <= 32) {
        const double fraction = std::clamp(
            (mouse_x - 24.0) / (rect.right - 48.0), 0.0, 1.0);
        g_seek_hover = fraction;
        if ((wparam & MK_LBUTTON) != 0 && g_duration.load() > 0) {
          const std::string target = std::to_string(fraction * 100.0);
          MpvCommand("seek", target.c_str(), "absolute-percent");
        }
      } else {
        g_seek_hover = -1;
      }
      if ((wparam & MK_LBUTTON) != 0 &&
          HitControl(mouse_x, mouse_y, rect.right) ==
              kVolume) {
        const double volume = std::clamp(
            (mouse_x - (rect.right - 265.0)) / 58.0 * 100.0,
            0.0, 100.0);
        const std::string value = std::to_string(volume);
        MpvCommand("set", "volume", value.c_str());
      }
      const int hovered = HitControl(mouse_x, mouse_y, rect.right);
      if (g_hover_control.exchange(hovered) != hovered) {
        InvalidateRect(window, nullptr, FALSE);
      }
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    }
    case WM_MOUSELEAVE:
      g_seek_hover = -1;
      g_hover_control = kNone;
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()), nullptr,
                                         0, nullptr, nullptr);
  std::string output(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      output.data(), length, nullptr, nullptr);
  return output;
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  switch (message) {
    case WM_DROPFILES: {
      const HDROP drop = reinterpret_cast<HDROP>(wparam);
      wchar_t path[MAX_PATH]{};
      const bool has_file = DragQueryFileW(drop, 0, path, MAX_PATH) > 0;
      DragFinish(drop);
      if (!has_file) return 0;
      std::filesystem::path subtitle(path);
      std::wstring extension = subtitle.extension().wstring();
      std::transform(extension.begin(), extension.end(), extension.begin(),
                     ::towlower);
      if (extension != L".srt" && extension != L".ass" &&
          extension != L".ssa" && extension != L".vtt") {
        ShowToast("请拖入 SRT、ASS、SSA 或 VTT 字幕文件");
        return 0;
      }
      const std::string utf8_path = Utf8(subtitle.wstring());
      if (MpvCommand("sub-add", utf8_path.c_str(), "select")) {
        ShowToast("已加载外部字幕：" + Utf8(subtitle.filename().wstring()));
      } else {
        ShowToast("外部字幕加载失败");
      }
      ShowControls();
      return 0;
    }
    case WM_CLOSE: {
      if (g_handle) {
        const char* command[] = {"quit", nullptr};
        g_mpv.command(g_handle, command);
      } else {
        DestroyWindow(window);
      }
      return 0;
    }
    case kMpvShutdown:
      DestroyWindow(window);
      return 0;
    case kPlayerStateChanged:
      if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
      if (g_top_bar) {
        const int64_t index = g_playlist_position.load();
        if (index >= 0 &&
            index < static_cast<int64_t>(g_playlist_titles.size())) {
          g_media_title = g_playlist_titles[static_cast<size_t>(index)];
        }
        InvalidateRect(g_top_bar, nullptr, FALSE);
      }
      return 0;
    case WM_MOVE:
    case WM_SIZE:
      PositionControls();
      return DefWindowProcW(window, message, wparam, lparam);
    case WM_MOUSEMOVE:
      ShowControls();
      return 0;
    case WM_LBUTTONDBLCLK:
      ToggleFullscreen();
      return 0;
    case WM_KEYDOWN:
      ShowControls();
      switch (wparam) {
        case VK_SPACE:
          MpvCommand("cycle", "pause");
          return 0;
        case VK_LEFT:
          MpvCommand("seek", "-10", "relative");
          return 0;
        case VK_RIGHT:
          MpvCommand("seek", "10", "relative");
          return 0;
        case VK_UP:
          MpvCommand("add", "volume", "5");
          return 0;
        case VK_DOWN:
          MpvCommand("add", "volume", "-5");
          return 0;
        case 'M':
          MpvCommand("cycle", "mute");
          return 0;
        case 'F':
          ToggleFullscreen();
          return 0;
        case VK_ESCAPE:
          if (g_fullscreen) ToggleFullscreen();
          return 0;
        default:
          return DefWindowProcW(window, message, wparam, lparam);
      }
    case WM_TIMER: {
      const bool should_hide = GetTickCount64() - g_last_interaction > 2600 &&
                               !g_paused.load() &&
                               !(g_panel && IsWindowVisible(g_panel));
      const BYTE target = should_hide ? 0 : 232;
      if (g_controls_alpha != target) {
        const int step = should_hide ? -24 : 32;
        const int next = std::clamp(static_cast<int>(g_controls_alpha) + step,
                                    0, 232);
        g_controls_alpha = static_cast<BYTE>(next);
        SetLayeredWindowAttributes(g_controls, 0, g_controls_alpha, LWA_ALPHA);
        if (g_top_bar) {
          SetLayeredWindowAttributes(g_top_bar, 0, g_controls_alpha, LWA_ALPHA);
        }
        if (g_controls_alpha == 0) SetCursor(nullptr);
      }
      return 0;
    }
    case WM_DESTROY:
      g_running = false;
      PostQuitMessage(0);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

bool SetOption(mpv_handle* handle, const std::string& name,
               const std::string& value) {
  return g_mpv.set_option_string(handle, name.c_str(), value.c_str()) >= 0;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int show_command) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (!g_mpv.Load()) {
    MessageBoxW(nullptr, L"无法加载 libmpv-2.dll。", L"Mova 原生播放器",
                MB_ICONERROR);
    return 2;
  }

  WNDCLASSW window_class{};
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  window_class.lpfnWndProc = WindowProc;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.style = CS_DBLCLKS;
  RegisterClassW(&window_class);
  WNDCLASSW controls_class{};
  controls_class.hInstance = instance;
  controls_class.lpszClassName = kControlsClass;
  controls_class.lpfnWndProc = ControlsProc;
  controls_class.hCursor = LoadCursor(nullptr, IDC_HAND);
  RegisterClassW(&controls_class);
  WNDCLASSW panel_class{};
  panel_class.hInstance = instance;
  panel_class.lpszClassName = kPanelClass;
  panel_class.lpfnWndProc = PanelProc;
  panel_class.hCursor = LoadCursor(nullptr, IDC_HAND);
  RegisterClassW(&panel_class);
  WNDCLASSW top_bar_class{};
  top_bar_class.hInstance = instance;
  top_bar_class.lpszClassName = kTopBarClass;
  top_bar_class.lpfnWndProc = TopBarProc;
  top_bar_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  top_bar_class.style = CS_DBLCLKS;
  RegisterClassW(&top_bar_class);

  Gdiplus::GdiplusStartupInput gdiplus_input;
  Gdiplus::GdiplusStartup(&g_gdiplus_token, &gdiplus_input, nullptr);

  HWND window = CreateWindowExW(
      0, kWindowClass, L"Mova",
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
          WS_CLIPCHILDREN,
      CW_USEDEFAULT, CW_USEDEFAULT, 1280, 760, nullptr, nullptr, instance,
      nullptr);
  if (!window) return 3;
  g_window = window;
  DragAcceptFiles(window, TRUE);
  g_windowed_style = GetWindowLongPtrW(window, GWL_STYLE);
  g_controls = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kControlsClass,
                               L"", WS_POPUP, 0, 0, 1, 1, window, nullptr,
                               instance, nullptr);
  SetLayeredWindowAttributes(g_controls, 0, 232, LWA_ALPHA);
  g_top_bar = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kTopBarClass,
                              L"", WS_POPUP, 0, 0, 1, 1, window, nullptr,
                              instance, nullptr);
  SetLayeredWindowAttributes(g_top_bar, 0, 232, LWA_ALPHA);
  g_panel = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kPanelClass, L"",
                            WS_POPUP, 0, 0, 1, 1, window, nullptr, instance,
                            nullptr);
  SetLayeredWindowAttributes(g_panel, 0, 242, LWA_ALPHA);

  g_handle = g_mpv.create();
  if (!g_handle) return 4;

  SetOption(g_handle, "wid", std::to_string(
                                 static_cast<uint32_t>(reinterpret_cast<uintptr_t>(window))));
  SetOption(g_handle, "vo", "gpu-next");
  SetOption(g_handle, "gpu-api", "d3d11");
  SetOption(g_handle, "gpu-context", "d3d11");
  SetOption(g_handle, "osc", "no");
  SetOption(g_handle, "input-default-bindings", "yes");
  SetOption(g_handle, "input-vo-keyboard", "yes");
  SetOption(g_handle, "keep-open", "no");
  SetOption(g_handle, "vid", "auto");

  std::vector<std::string> media_urls;
  int playlist_start = 0;
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  for (int index = 1; index < argc; ++index) {
    std::wstring argument = argv[index];
    if (argument.rfind(L"--", 0) == 0) {
      const auto equals = argument.find(L'=');
      if (equals != std::wstring::npos) {
        const auto name = Utf8(argument.substr(2, equals - 2));
        if (name == "mova-playlist-start") {
          playlist_start = std::max(0, std::atoi(
              Utf8(argument.substr(equals + 1)).c_str()));
        } else if (name == "mova-playlist-title") {
          g_playlist_titles.push_back(argument.substr(equals + 1));
        } else if (name != "script" && name != "terminal" &&
            name != "term-status-msg" && name != "force-window" &&
            name != "config") {
          SetOption(g_handle, name, Utf8(argument.substr(equals + 1)));
        }
        if (name == "force-media-title") {
          g_media_title = argument.substr(equals + 1);
        }
      }
    } else {
      media_urls.push_back(Utf8(argument));
    }
  }
  LocalFree(argv);
  while (g_playlist_titles.size() < media_urls.size()) {
    g_playlist_titles.push_back(g_media_title);
  }

  if (g_mpv.initialize(g_handle) < 0 || media_urls.empty()) {
    MessageBoxW(window, L"播放器初始化失败或没有可播放的地址。",
                L"Mova 原生播放器", MB_ICONERROR);
    g_mpv.terminate_destroy(g_handle);
    g_handle = nullptr;
    return 5;
  }

  g_mpv.observe_property(g_handle, 1, "time-pos", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 2, "duration", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 3, "pause", MPV_FORMAT_FLAG);
  g_mpv.observe_property(g_handle, 4, "volume", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 5, "mute", MPV_FORMAT_FLAG);
  g_mpv.observe_property(g_handle, 6, "speed", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 7, "paused-for-cache", MPV_FORMAT_FLAG);
  g_mpv.observe_property(g_handle, 8, "playlist-pos", MPV_FORMAT_INT64);
  const char* load[] = {"loadfile", media_urls.front().c_str(), "replace", nullptr};
  g_mpv.command(g_handle, load);
  for (size_t index = 1; index < media_urls.size(); ++index) {
    const char* append[] = {"loadfile", media_urls[index].c_str(), "append",
                            nullptr};
    g_mpv.command(g_handle, append);
  }
  if (playlist_start > 0 &&
      playlist_start < static_cast<int>(media_urls.size())) {
    const std::string start = std::to_string(playlist_start);
    MpvCommand("set", "playlist-pos", start.c_str());
  }
  ShowWindow(window, show_command);
  UpdateWindow(window);
  g_last_interaction = GetTickCount64();
  SetTimer(window, 1, 50, nullptr);
  PositionControls();

  std::thread([] {
    const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    if (!input || input == INVALID_HANDLE_VALUE) return;
    std::string pending;
    char buffer[256]{};
    DWORD read = 0;
    while (g_running && ReadFile(input, buffer, sizeof(buffer), &read, nullptr) &&
           read > 0) {
      pending.append(buffer, read);
      size_t newline = 0;
      while ((newline = pending.find('\n')) != std::string::npos) {
        const std::string line = pending.substr(0, newline);
        pending.erase(0, newline + 1);
        if (line.rfind("MOVA_CACHE=", 0) == 0) {
          const auto divider = line.find('|', 11);
          if (divider != std::string::npos) {
            const double received = std::strtod(line.c_str() + 11, nullptr);
            const double total = std::strtod(line.c_str() + divider + 1, nullptr);
            g_cache_fraction = total > 0 ? received / total : 0;
            PostMessageW(g_window, kPlayerStateChanged, 0, 0);
          }
        }
      }
    }
  }).detach();

  std::thread events([window] {
    while (g_running) {
      mpv_event* event = g_mpv.wait_event(g_handle, 0.1);
      if (!event) continue;
      if (event->event_id == MPV_EVENT_SHUTDOWN) {
        EmitProgress(g_position.load(), g_duration.load());
        PostMessageW(window, kMpvShutdown, 0, 0);
        break;
      }
      if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->data) {
        auto* property = static_cast<mpv_event_property*>(event->data);
        if (property->format == MPV_FORMAT_DOUBLE && property->data) {
          const double value = *static_cast<double*>(property->data);
          if (property->name && std::string(property->name) == "time-pos") {
            g_position = value;
          } else if (property->name && std::string(property->name) == "duration") {
            g_duration = value;
          } else if (property->name && std::string(property->name) == "volume") {
            g_volume = value;
          } else if (property->name && std::string(property->name) == "speed") {
            g_speed = value;
          }
          EmitProgress(g_position.load(), g_duration.load());
          PostMessageW(window, kPlayerStateChanged, 0, 0);
        } else if (property->format == MPV_FORMAT_FLAG && property->data &&
                   property->name) {
          const bool value = *static_cast<int*>(property->data) != 0;
          const std::string name(property->name);
          if (name == "pause") g_paused = value;
          if (name == "mute") g_muted = value;
          if (name == "paused-for-cache") g_buffering = value;
          PostMessageW(window, kPlayerStateChanged, 0, 0);
        } else if (property->format == MPV_FORMAT_INT64 && property->data &&
                   property->name &&
                   std::string(property->name) == "playlist-pos") {
          const int64_t next = *static_cast<int64_t*>(property->data);
          if (g_playlist_position.exchange(next) != next) {
            g_cache_fraction = 0;
          }
          PostMessageW(window, kPlayerStateChanged, 0, 0);
        }
      }
    }
  });

  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  g_running = false;
  if (events.joinable()) events.join();
  if (g_handle) {
    g_mpv.terminate_destroy(g_handle);
    g_handle = nullptr;
  }
  if (g_gdiplus_token) Gdiplus::GdiplusShutdown(g_gdiplus_token);
  return 0;
}
