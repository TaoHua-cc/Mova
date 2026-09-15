#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <gdiplus.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cwctype>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <thread>
#include <unordered_map>
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
enum mpv_end_file_reason {
  MPV_END_FILE_REASON_EOF = 0,
  MPV_END_FILE_REASON_STOP = 2,
  MPV_END_FILE_REASON_QUIT = 3,
  MPV_END_FILE_REASON_ERROR = 4,
  MPV_END_FILE_REASON_REDIRECT = 5,
};
struct mpv_event_end_file {
  mpv_end_file_reason reason;
  int error;
  int64_t playlist_entry_id;
  int64_t playlist_insert_id;
  int playlist_insert_num_entries;
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
constexpr COLORREF kOverlayColorKey = RGB(1, 2, 3);
constexpr wchar_t kInterfaceFont[] = L"Alimama FangYuanTi VF";

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
std::atomic<bool> g_playback_error{false};
std::atomic<double> g_cache_fraction{0};
std::atomic<double> g_network_bytes_per_second{0};
std::atomic<int64_t> g_playlist_position{0};
std::atomic<int> g_hover_control{0};
std::atomic<double> g_seek_hover{-1};
HWND g_window = nullptr;
HWND g_controls = nullptr;
HWND g_panel = nullptr;
HWND g_top_bar = nullptr;
ULONG_PTR g_gdiplus_token = 0;
std::unique_ptr<Gdiplus::PrivateFontCollection> g_interface_font_collection;
std::unique_ptr<Gdiplus::FontFamily> g_interface_font_family;
BYTE g_controls_alpha = 232;
ULONGLONG g_last_interaction = 0;
bool g_fullscreen = false;
LONG_PTR g_windowed_style = 0;
WINDOWPLACEMENT g_window_placement{sizeof(WINDOWPLACEMENT)};
std::wstring g_media_title = L"Mova";
std::wstring g_series_logo_path;
std::unique_ptr<Gdiplus::Bitmap> g_series_logo;
std::vector<std::wstring> g_playlist_titles;
std::vector<std::wstring> g_playlist_details;
int g_panel_hover = -1;
float g_play_state_mix = 0.0f;
float g_buffer_phase = 0.0f;
double g_seek_seconds = 10.0;
double g_volume_step = 5.0;
std::unordered_map<int, std::string> g_shortcuts;
bool g_danmaku_enabled = false;
bool g_auto_skip_segments = true;

struct PanelItem {
  std::wstring label;
  std::string property;
  std::string value;
  std::string toast;
  bool selected = false;
  bool enabled = true;
};
std::vector<PanelItem> g_panel_items;
int g_panel_scroll = 0;
int g_panel_viewport_height = 0;

constexpr int kPanelRowHeight = 40;
constexpr int kPanelPadding = 8;
constexpr int kPanelMaxHeight = 360;

int PanelContentHeight() {
  return kPanelPadding * 2 +
         static_cast<int>(g_panel_items.size()) * kPanelRowHeight;
}

int PanelMaxScroll() {
  return std::max(0, PanelContentHeight() - g_panel_viewport_height);
}

void ScrollPanel(int delta) {
  const int next = std::clamp(g_panel_scroll + delta, 0, PanelMaxScroll());
  if (next == g_panel_scroll) return;
  g_panel_scroll = next;
  if (g_panel) InvalidateRect(g_panel, nullptr, FALSE);
}

int PanelIndexAt(int y) {
  if (y < kPanelPadding || y >= g_panel_viewport_height - kPanelPadding) {
    return -1;
  }
  const int index = (y - kPanelPadding + g_panel_scroll) / kPanelRowHeight;
  return index >= 0 && index < static_cast<int>(g_panel_items.size())
             ? index
             : -1;
}

void ShowControls();
std::string Utf8(const std::wstring& value);
void OpenPanel(std::vector<PanelItem> items, int anchor_x, int anchor_y);

Gdiplus::Font MakeInterfaceFont(float size, int style) {
  const Gdiplus::FontFamily* family =
      g_interface_font_family && g_interface_font_family->IsAvailable()
          ? g_interface_font_family.get()
          : Gdiplus::FontFamily::GenericSansSerif();
  return Gdiplus::Font(family, size, style, Gdiplus::UnitPixel);
}

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
  const std::string current_aspect = MpvString("video-aspect-override");
  const double speeds[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0};
  const wchar_t* speed_labels[] = {L"0.5×", L"0.75×", L"正常速度",
                                   L"1.25×", L"1.5×", L"2.0×"};
  for (int index = 0; index < 6; ++index) {
    const bool selected = std::abs(g_speed.load() - speeds[index]) < 0.01;
    const std::string value = std::to_string(speeds[index]);
    items.push_back({speed_labels[index], "speed", value,
                     "播放速度 " + value + "×", selected, true});
  }
  const auto aspect_selected = [&current_aspect](const char* value) {
    if (std::string(value) == "0") {
      return current_aspect.empty() || current_aspect == "0" ||
             current_aspect == "no";
    }
    return current_aspect == value;
  };
  items.push_back({L"画面比例 · 自动", "video-aspect-override", "0",
                   "画面比例 自动", aspect_selected("0")});
  items.push_back({L"画面比例 · 16:9", "video-aspect-override", "1.7777778",
                   "画面比例 16:9", aspect_selected("1.7777778")});
  items.push_back({L"画面比例 · 4:3", "video-aspect-override", "1.3333333",
                   "画面比例 4:3", aspect_selected("1.3333333")});
  items.push_back({L"画面比例 · 21:9", "video-aspect-override", "2.3333333",
                   "画面比例 21:9", aspect_selected("2.3333333")});
  items.push_back({g_danmaku_enabled
                       ? L"弹幕 · 已在设置中开启（原生窗口暂不显示）"
                       : L"弹幕 · 未开启",
                   "", "", "", false, false});
  items.push_back({g_auto_skip_segments
                       ? L"片头片尾 · 自动跳过已开启（等待片段数据）"
                       : L"片头片尾 · 自动跳过未开启",
                   "", "", "", false, false});
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
  const int available_width = std::max(240, client_width - 32);
  const int width = std::min(1040, available_width);
  const int height = 112;
  SetWindowPos(g_controls, HWND_TOP, origin.x + (client.right - width) / 2,
               origin.y + client.bottom - height - 20, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  SetWindowRgn(g_controls, CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                              28, 28), TRUE);
  InvalidateRect(g_controls, nullptr, FALSE);
  if (g_top_bar) {
    // The title bar belongs to the window edges, unlike the deliberately
    // compact transport dock.  Keeping it full-width means its two groups
    // remain anchored correctly while the window is resized.
    const int top_width = std::max(240, client_width - 32);
    const int top_height = 58;
    SetWindowPos(g_top_bar, HWND_TOP, origin.x + 16, origin.y + 14,
                 top_width, top_height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowRgn(g_top_bar, nullptr, TRUE);
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

void ConfigureControlPen(Gdiplus::Pen& pen) {
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
  pen.SetLineJoin(Gdiplus::LineJoinRound);
}

Gdiplus::Color IconInk(float emphasis = 0.0f, BYTE alpha = 242) {
  const BYTE red = static_cast<BYTE>(245 - emphasis * 18.0f);
  const BYTE green = static_cast<BYTE>(245 - emphasis * 5.0f);
  const BYTE blue = static_cast<BYTE>(247 + emphasis * 8.0f);
  return Gdiplus::Color(alpha, red, green, blue);
}

void DrawRoundedRect(Gdiplus::Graphics& graphics, Gdiplus::Pen& pen,
                     const Gdiplus::RectF& rect, float radius) {
  Gdiplus::GraphicsPath path;
  const float diameter = radius * 2.0f;
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270, 90);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter,
              diameter, diameter, 0, 90);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90, 90);
  path.CloseFigure();
  graphics.DrawPath(&pen, &path);
}

void DrawPlayIcon(Gdiplus::Graphics& graphics, float x, float y,
                  float play_amount, float emphasis) {
  if (play_amount > 0.001f) {
    Gdiplus::SolidBrush play_ink(Gdiplus::Color(
        static_cast<BYTE>(play_amount * 255.0f), 18, 18, 20));
    Gdiplus::GraphicsPath play;
    play.AddBezier(x - 5.5f, y - 10.5f, x - 7.0f, y - 11.5f,
                   x - 7.0f, y + 11.5f, x - 5.5f, y + 10.5f);
    play.AddLine(Gdiplus::PointF(x - 5.5f, y + 10.5f),
                 Gdiplus::PointF(x + 10.5f, y + 1.8f));
    play.AddBezier(x + 10.5f, y + 1.8f, x + 12.0f, y + 1.0f,
                   x + 12.0f, y - 1.0f, x + 10.5f, y - 1.8f);
    play.CloseFigure();
    graphics.FillPath(&play_ink, &play);
  }
  const float pause_amount = 1.0f - play_amount;
  if (pause_amount > 0.001f) {
    Gdiplus::SolidBrush pause_ink(Gdiplus::Color(
        static_cast<BYTE>(pause_amount * 255.0f), 18, 18, 20));
    const float spread = 5.0f + emphasis;
    graphics.FillRectangle(&pause_ink,
                           Gdiplus::RectF(x - spread - 2.5f, y - 10.5f,
                                          5.0f, 21.0f));
    graphics.FillRectangle(&pause_ink,
                           Gdiplus::RectF(x + spread - 2.5f, y - 10.5f,
                                          5.0f, 21.0f));
  }
}

void DrawSpeaker(Gdiplus::Graphics& graphics, float x, float y, bool muted,
                 float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 1.9f);
  ConfigureControlPen(pen);
  Gdiplus::GraphicsPath body;
  body.AddLine(Gdiplus::PointF(x - 10.0f, y - 4.0f),
               Gdiplus::PointF(x - 5.5f, y - 4.0f));
  body.AddLine(Gdiplus::PointF(x - 5.5f, y - 4.0f),
               Gdiplus::PointF(x + 0.8f, y - 9.5f));
  body.AddBezier(x + 0.8f, y - 9.5f, x + 2.0f, y - 10.4f,
                 x + 3.0f, y - 9.0f, x + 3.0f, y - 7.5f);
  body.AddLine(Gdiplus::PointF(x + 3.0f, y - 7.5f),
               Gdiplus::PointF(x + 3.0f, y + 7.5f));
  body.AddBezier(x + 3.0f, y + 7.5f, x + 3.0f, y + 9.0f,
                 x + 2.0f, y + 10.4f, x + 0.8f, y + 9.5f);
  body.AddLine(Gdiplus::PointF(x + 0.8f, y + 9.5f),
               Gdiplus::PointF(x - 5.5f, y + 4.0f));
  body.AddLine(Gdiplus::PointF(x - 5.5f, y + 4.0f),
               Gdiplus::PointF(x - 10.0f, y + 4.0f));
  body.CloseFigure();
  graphics.DrawPath(&pen, &body);
  if (muted) {
    graphics.DrawLine(&pen, x + 8.0f, y - 5.0f, x + 16.0f, y + 5.0f);
    graphics.DrawLine(&pen, x + 16.0f, y - 5.0f, x + 8.0f, y + 5.0f);
  } else {
    graphics.DrawArc(&pen, Gdiplus::RectF(x + 1, y - 8, 13, 16), -58, 116);
    graphics.DrawArc(&pen, Gdiplus::RectF(x - 1, y - 11, 21, 22), -50, 100);
  }
}

void DrawFullscreen(Gdiplus::Graphics& graphics, float x, float y,
                    bool fullscreen, float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 1.9f);
  ConfigureControlPen(pen);
  const float corner_distance = fullscreen ? 3.5f : 10.0f;
  const float arm_distance = fullscreen ? 10.0f : 4.0f;
  for (int horizontal : {-1, 1}) {
    for (int vertical : {-1, 1}) {
      const float corner_x = x + horizontal * corner_distance;
      const float corner_y = y + vertical * corner_distance;
      graphics.DrawLine(&pen, corner_x, corner_y, x + horizontal * arm_distance,
                        corner_y);
      graphics.DrawLine(&pen, corner_x, corner_y, corner_x,
                        y + vertical * arm_distance);
    }
  }
}

void DrawSkipIcon(Gdiplus::Graphics& graphics, float x, float y, bool next,
                  float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 3.0f);
  ConfigureControlPen(pen);
  const float direction = next ? 1.0f : -1.0f;
  const float motion = emphasis * direction;
  Gdiplus::PointF triangle[] = {
      {x - direction * 6.5f + motion, y - 7.5f},
      {x + direction * 5.5f + motion, y},
      {x - direction * 6.5f + motion, y + 7.5f}};
  Gdiplus::SolidBrush fill(IconInk(emphasis));
  graphics.FillPolygon(&fill, triangle, 3);
  graphics.DrawLine(&pen, x + direction * 8.5f, y - 7.5f,
                    x + direction * 8.5f, y + 7.5f);
}

void DrawSeekIcon(Gdiplus::Graphics& graphics, float x, float y, bool forward,
                  float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 2.0f);
  ConfigureControlPen(pen);
  const float turn = (forward ? 1.0f : -1.0f) * emphasis;
  graphics.DrawArc(&pen,
                   Gdiplus::RectF(x - 10.25f + turn, y - 10.25f, 20.5f, 20.5f),
                   forward ? -42.0f : -138.0f, forward ? 278.0f : -278.0f);
  if (forward) {
    graphics.DrawLine(&pen, x + 5.0f + turn, y - 9.0f,
                      x + 10.5f + turn, y - 7.5f);
    graphics.DrawLine(&pen, x + 10.5f + turn, y - 7.5f,
                      x + 9.0f + turn, y - 2.0f);
  } else {
    graphics.DrawLine(&pen, x - 5.0f + turn, y - 9.0f,
                      x - 10.5f + turn, y - 7.5f);
    graphics.DrawLine(&pen, x - 10.5f + turn, y - 7.5f,
                      x - 9.0f + turn, y - 2.0f);
  }
  Gdiplus::SolidBrush brush(IconInk(emphasis));
  auto number = MakeInterfaceFont(8.5f, Gdiplus::FontStyleBold);
  Gdiplus::StringFormat centered;
  centered.SetAlignment(Gdiplus::StringAlignmentCenter);
  centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  graphics.DrawString(L"10", -1, &number, Gdiplus::RectF(x - 8, y - 7, 16, 14),
                      &centered, &brush);
}

void DrawAudioIcon(Gdiplus::Graphics& graphics, float x, float y,
                   float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 2.1f);
  ConfigureControlPen(pen);
  const float phase = emphasis * 2.0f;
  const float heights[] = {7.0f + phase, 15.0f - phase, 20.0f,
                           11.0f + phase};
  for (int i = 0; i < 4; ++i) {
    const float px = x - 9.0f + static_cast<float>(i) * 6.0f;
    graphics.DrawLine(&pen, px, y - heights[i] / 2, px, y + heights[i] / 2);
  }
}

void DrawSubtitleIcon(Gdiplus::Graphics& graphics, float x, float y,
                      float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 2.0f);
  ConfigureControlPen(pen);
  DrawRoundedRect(graphics, pen, Gdiplus::RectF(x - 11, y - 8.5f, 22, 17),
                  5.0f);
  graphics.DrawLine(&pen, x - 6.5f, y + 2.0f, x - 1.0f, y + 2.0f);
  graphics.DrawLine(&pen, x + 2.0f, y + 2.0f, x + 7.0f, y + 2.0f);
  graphics.DrawLine(&pen, x - 6.5f, y - 2.5f, x + 4.0f, y - 2.5f);
}

void DrawPlaylistIcon(Gdiplus::Graphics& graphics, float x, float y,
                      float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 2.0f);
  ConfigureControlPen(pen);
  DrawRoundedRect(graphics, pen, Gdiplus::RectF(x - 10, y - 9, 20, 18), 5);
  graphics.DrawLine(&pen, x - 5.5f, y - 3.5f, x + 5.5f, y - 3.5f);
  graphics.DrawLine(&pen, x - 5.5f, y + 1.0f, x + 2.5f, y + 1.0f);
  Gdiplus::SolidBrush accent(IconInk(emphasis));
  Gdiplus::PointF play[] = {{x + 1.5f, y + 3.5f},
                            {x + 6.0f, y + 6.0f},
                            {x + 1.5f, y + 8.0f}};
  graphics.FillPolygon(&accent, play, 3);
}

void DrawSettingsIcon(Gdiplus::Graphics& graphics, float x, float y,
                      float emphasis) {
  Gdiplus::Pen pen(IconInk(emphasis), 1.9f);
  ConfigureControlPen(pen);
  graphics.DrawLine(&pen, x - 10, y - 6, x + 10, y - 6);
  graphics.DrawLine(&pen, x - 10, y, x + 10, y);
  graphics.DrawLine(&pen, x - 10, y + 6, x + 10, y + 6);
  Gdiplus::SolidBrush surface(Gdiplus::Color(255, 22, 23, 28));
  Gdiplus::Pen knob_pen(IconInk(emphasis), 1.9f);
  const float shift = emphasis * 1.5f;
  const float knobs[] = {x - 3.0f - shift, x + 5.0f + shift,
                         x + 1.0f - shift};
  for (int i = 0; i < 3; ++i) {
    const float knob_y = y - 6.0f + static_cast<float>(i) * 6.0f;
    graphics.FillEllipse(&surface,
                         Gdiplus::RectF(knobs[i] - 3, knob_y - 3, 6, 6));
    graphics.DrawEllipse(&knob_pen,
                         Gdiplus::RectF(knobs[i] - 3, knob_y - 3, 6, 6));
  }
}

void FillPill(Gdiplus::Graphics& graphics, Gdiplus::Brush& brush, float x,
              float y, float width, float height) {
  const float radius = height / 2.0f;
  const float diameter = radius * 2.0f;
  Gdiplus::GraphicsPath path;
  path.AddArc(x, y, diameter, diameter, 90, 180);
  path.AddLine(Gdiplus::PointF(x + radius, y),
               Gdiplus::PointF(x + width - radius, y));
  path.AddArc(x + width - diameter, y, diameter, diameter, 270, 180);
  path.AddLine(Gdiplus::PointF(x + width - radius, y + height),
               Gdiplus::PointF(x + radius, y + height));
  path.CloseFigure();
  graphics.FillPath(&brush, &path);
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

constexpr size_t kControlCount = static_cast<size_t>(kPlaylist) + 1;
std::array<float, kControlCount> g_control_hover{};

float HoverAmount(ControlId id) {
  const float value = g_control_hover[static_cast<size_t>(id)];
  return value * value * (3.0f - 2.0f * value);
}

bool AnimateControlHover() {
  const ControlId hovered = static_cast<ControlId>(g_hover_control.load());
  bool changed = false;
  for (size_t index = 1; index < g_control_hover.size(); ++index) {
    const float target = index == static_cast<size_t>(hovered) ? 1.0f : 0.0f;
    const float current = g_control_hover[index];
    const float next = target > current ? std::min(target, current + 0.28f)
                                        : std::max(target, current - 0.22f);
    if (std::abs(next - current) > 0.001f) {
      g_control_hover[index] = next;
      changed = true;
    }
  }
  return changed;
}

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
  if (compact) {
    if (x >= width - 138 && x < width - 98) return kSubtitle;
    if (x >= width - 96 && x < width - 54) return kPlaybackSettings;
    if (x >= width - 52) return kFullscreen;
    return kNone;
  }
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
  const float amount = HoverAmount(id);
  Gdiplus::SolidBrush base(Gdiplus::Color(205, 24, 27, 33));
  Gdiplus::Pen edge(Gdiplus::Color(72, 104, 112, 128), 1.0f);
  graphics.FillEllipse(&base, Gdiplus::RectF(x - size / 2, y - size / 2,
                                              size, size));
  graphics.DrawEllipse(&edge, Gdiplus::RectF(x - size / 2, y - size / 2,
                                              size, size));
  if (amount > 0.001f) {
    const BYTE alpha = static_cast<BYTE>(amount * 54.0f);
    Gdiplus::SolidBrush hover(Gdiplus::Color(alpha, 110, 168, 255));
    const float inset = (1.0f - amount) * 2.0f;
    graphics.FillEllipse(&hover,
                         Gdiplus::RectF(x - size / 2 + inset,
                                        y - size / 2 + inset, size - inset * 2,
                                        size - inset * 2));
  }
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
        graphics.Clear(Gdiplus::Color(255, 18, 20, 25));
        Gdiplus::LinearGradientBrush surface(
            Gdiplus::Point(0, 0), Gdiplus::Point(0, rect.bottom),
            Gdiplus::Color(255, 31, 34, 42),
            Gdiplus::Color(255, 17, 19, 24));
        graphics.FillRectangle(&surface,
                               Gdiplus::Rect(0, 0, rect.right, rect.bottom));
        Gdiplus::Pen edge(Gdiplus::Color(86, 157, 171, 194), 1.0f);
        graphics.DrawRectangle(&edge,
                               Gdiplus::Rect(0, 0, rect.right - 1,
                                              rect.bottom - 1));
        auto font = MakeInterfaceFont(13, Gdiplus::FontStyleRegular);
        Gdiplus::SolidBrush text(Gdiplus::Color(255, 244, 244, 247));
        Gdiplus::SolidBrush disabled(Gdiplus::Color(120, 174, 176, 184));
        Gdiplus::SolidBrush hover(Gdiplus::Color(50, 255, 255, 255));
        Gdiplus::SolidBrush selected_fill(Gdiplus::Color(60, 92, 148, 239));
        Gdiplus::SolidBrush accent(Gdiplus::Color(255, 117, 171, 255));
        Gdiplus::StringFormat format;
        format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        for (size_t index = 0; index < g_panel_items.size(); ++index) {
          const float top = static_cast<float>(kPanelPadding +
              static_cast<int>(index) * kPanelRowHeight - g_panel_scroll);
          if (top + 36.0f < 0 || top > rect.bottom) continue;
          if (g_panel_items[index].selected) {
            FillPill(graphics, selected_fill, 8, top, rect.right - 16.0f, 36);
          } else if (g_panel_hover == static_cast<int>(index) &&
                     g_panel_items[index].enabled) {
            FillPill(graphics, hover, 8, top, rect.right - 16.0f, 36);
          }
          if (g_panel_items[index].selected) {
            graphics.FillEllipse(&accent, Gdiplus::RectF(19, top + 12, 12, 12));
            Gdiplus::Pen check(Gdiplus::Color(255, 12, 18, 30), 1.5f);
            ConfigureControlPen(check);
            graphics.DrawLine(&check, 22.0f, top + 18.0f, 24.5f,
                              top + 20.5f);
            graphics.DrawLine(&check, 24.5f, top + 20.5f, 28.5f, top + 15.5f);
          }
          graphics.DrawString(
              g_panel_items[index].label.c_str(), -1, &font,
              Gdiplus::RectF(40, top, rect.right - 54.0f, 36), &format,
              g_panel_items[index].enabled ? &text : &disabled);
        }
        if (PanelMaxScroll() > 0) {
          const float content = static_cast<float>(PanelContentHeight());
          const float viewport = static_cast<float>(rect.bottom);
          const float track_top = 10.0f;
          const float track_height = std::max(20.0f, viewport - 20.0f);
          const float thumb_height = std::max(28.0f, track_height * viewport / content);
          const float travel = track_height - thumb_height;
          const float fraction = PanelMaxScroll() == 0 ? 0.0f :
              static_cast<float>(g_panel_scroll) / PanelMaxScroll();
          Gdiplus::SolidBrush track(Gdiplus::Color(42, 255, 255, 255));
          Gdiplus::SolidBrush thumb(Gdiplus::Color(150, 139, 185, 255));
          FillPill(graphics, track, rect.right - 8.0f, track_top, 3.0f, track_height);
          FillPill(graphics, thumb, rect.right - 8.0f,
                   track_top + travel * fraction, 3.0f, thumb_height);
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
      const int next = PanelIndexAt(GET_Y_LPARAM(lparam));
      if (g_panel_hover != next) {
        g_panel_hover = next;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const int index = PanelIndexAt(GET_Y_LPARAM(lparam));
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
    case WM_MOUSEWHEEL:
      ScrollPanel(GET_WHEEL_DELTA_WPARAM(wparam) > 0 ? -80 : 80);
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        ShowWindow(window, SW_HIDE);
        SetFocus(g_window);
        return 0;
      }
      if (wparam == VK_UP) {
        ScrollPanel(-kPanelRowHeight);
        return 0;
      }
      if (wparam == VK_DOWN) {
        ScrollPanel(kPanelRowHeight);
        return 0;
      }
      if (wparam == VK_PRIOR) {
        ScrollPanel(-g_panel_viewport_height + kPanelRowHeight);
        return 0;
      }
      if (wparam == VK_NEXT) {
        ScrollPanel(g_panel_viewport_height - kPanelRowHeight);
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
  g_panel_scroll = 0;
  const int width = 280;
  const int height = std::min(kPanelMaxHeight, PanelContentHeight());
  g_panel_viewport_height = height;
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
               CreateRoundRectRgn(0, 0, width + 1, height + 1, 32, 32), TRUE);
  InvalidateRect(g_panel, nullptr, FALSE);
  SetForegroundWindow(g_panel);
  SetFocus(g_panel);
}

int g_top_hover = 0;
std::array<float, 4> g_top_hover_mix{};

bool AnimateTopHover() {
  bool changed = false;
  for (size_t index = 1; index < g_top_hover_mix.size(); ++index) {
    const float target = index == static_cast<size_t>(g_top_hover) ? 1.0f : 0.0f;
    const float current = g_top_hover_mix[index];
    const float next = target > current ? std::min(target, current + 0.3f)
                                        : std::max(target, current - 0.24f);
    if (std::abs(next - current) > 0.001f) {
      g_top_hover_mix[index] = next;
      changed = true;
    }
  }
  return changed;
}

int TopHit(int x, int width) {
  if (x >= width - 52) return 3;
  if (x >= width - 104) return 2;
  if (x >= width - 156) return 1;
  return 0;
}

std::wstring NetworkSpeedLabel() {
  const double bytes_per_second = g_network_bytes_per_second.load();
  if (bytes_per_second < 1.0) return L"网络  —";
  wchar_t text[48]{};
  if (bytes_per_second >= 1024.0 * 1024.0) {
    swprintf_s(text, L"网络  %.1f MB/s", bytes_per_second / (1024.0 * 1024.0));
  } else {
    swprintf_s(text, L"网络  %.0f KB/s", bytes_per_second / 1024.0);
  }
  return text;
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
        graphics.Clear(Gdiplus::Color(255, 1, 2, 3));
        Gdiplus::SolidBrush title_brush(Gdiplus::Color(235, 244, 244, 247));
        Gdiplus::SolidBrush title_shadow(Gdiplus::Color(180, 0, 0, 0));
        auto title_font = MakeInterfaceFont(15, Gdiplus::FontStyleBold);
        auto network_font = MakeInterfaceFont(12, Gdiplus::FontStyleRegular);
        Gdiplus::StringFormat title_format;
        title_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        title_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
        if (g_series_logo && g_series_logo->GetLastStatus() == Gdiplus::Ok &&
            g_series_logo->GetWidth() > 0 && g_series_logo->GetHeight() > 0) {
          const float max_width = std::min(220.0f, rect.right - 300.0f);
          const float max_height = 44.0f;
          const float scale =
              std::min(max_width / g_series_logo->GetWidth(),
                       max_height / g_series_logo->GetHeight());
          const float logo_width = g_series_logo->GetWidth() * scale;
          const float logo_height = g_series_logo->GetHeight() * scale;
          graphics.DrawImage(g_series_logo.get(),
                             Gdiplus::RectF(8, (rect.bottom - logo_height) / 2,
                                            logo_width, logo_height));
          const int64_t index = g_playlist_position.load();
          if (index >= 0 &&
              index < static_cast<int64_t>(g_playlist_details.size()) &&
              !g_playlist_details[static_cast<size_t>(index)].empty()) {
            const float detail_x = 8.0f + logo_width + 18.0f;
            const float detail_width =
                std::max(0.0f, rect.right - detail_x - 286.0f);
            graphics.DrawString(
                g_playlist_details[static_cast<size_t>(index)].c_str(), -1,
                &title_font,
                Gdiplus::RectF(detail_x + 1, 2, detail_width,
                               static_cast<float>(rect.bottom)),
                &title_format, &title_shadow);
            graphics.DrawString(
                g_playlist_details[static_cast<size_t>(index)].c_str(), -1,
                &title_font,
                Gdiplus::RectF(detail_x, 0, detail_width,
                               static_cast<float>(rect.bottom)),
                &title_format, &title_brush);
          }
        } else {
          graphics.DrawString(g_media_title.c_str(), -1, &title_font,
                              Gdiplus::RectF(9, 2, rect.right - 297.0f,
                                             static_cast<float>(rect.bottom)),
                              &title_format, &title_shadow);
          graphics.DrawString(g_media_title.c_str(), -1, &title_font,
                              Gdiplus::RectF(8, 0, rect.right - 297.0f,
                                             static_cast<float>(rect.bottom)),
                              &title_format, &title_brush);
        }
        const std::wstring network = NetworkSpeedLabel();
        Gdiplus::SolidBrush network_brush(Gdiplus::Color(210, 175, 196, 222));
        Gdiplus::SolidBrush network_dot(Gdiplus::Color(255, 112, 168, 255));
        graphics.FillEllipse(&network_dot, Gdiplus::RectF(rect.right - 286.0f,
                                                           26.0f, 5.0f, 5.0f));
        graphics.DrawString(network.c_str(), -1, &network_font,
                            Gdiplus::RectF(rect.right - 274.0f, 0, 106.0f,
                                           static_cast<float>(rect.bottom)),
                            &title_format, &network_brush);
        Gdiplus::Pen icon(Gdiplus::Color(235, 244, 244, 247), 1.7f);
        ConfigureControlPen(icon);
        for (int button = 1; button <= 3; ++button) {
          const float x = rect.right - (3 - button) * 52.0f - 26.0f;
          const float hover_amount = g_top_hover_mix[button];
          Gdiplus::SolidBrush button_base(Gdiplus::Color(188, 22, 25, 31));
          Gdiplus::Pen button_edge(Gdiplus::Color(64, 116, 126, 144), 1.0f);
          graphics.FillEllipse(&button_base,
                               Gdiplus::RectF(x - 18, 11, 36, 36));
          graphics.DrawEllipse(&button_edge,
                               Gdiplus::RectF(x - 18, 11, 36, 36));
          if (hover_amount > 0.001f) {
            const BYTE alpha = static_cast<BYTE>(hover_amount *
                                                 (button == 3 ? 210 : 54));
            Gdiplus::SolidBrush hover(button == 3
                                          ? Gdiplus::Color(alpha, 255, 69, 58)
                                          : Gdiplus::Color(alpha, 126, 174, 255));
            const float inset = (1.0f - hover_amount) * 3.0f;
            FillPill(graphics, hover, x - 20 + inset, 9 + inset,
                     40 - inset * 2, 40 - inset * 2);
          }
          if (button == 1) {
            graphics.DrawLine(&icon, x - 7.0f, 29.0f, x + 7.0f, 29.0f);
          } else if (button == 2) {
            if (IsZoomed(g_window)) {
              DrawRoundedRect(graphics, icon,
                              Gdiplus::RectF(x - 5.0f, 22.0f, 11.0f, 11.0f),
                              1.5f);
              graphics.DrawLine(&icon, x - 3.0f, 20.0f, x + 8.0f, 20.0f);
              graphics.DrawLine(&icon, x + 8.0f, 20.0f, x + 8.0f, 31.0f);
            } else {
              DrawRoundedRect(graphics, icon,
                              Gdiplus::RectF(x - 7.0f, 21.0f, 14.0f, 14.0f),
                              2.0f);
            }
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
      TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT), TME_LEAVE, window, 0};
      TrackMouseEvent(&tracking);
      RECT rect{};
      GetClientRect(window, &rect);
      const int hover = TopHit(GET_X_LPARAM(lparam), rect.right);
      if (g_top_hover != hover) {
        g_top_hover = hover;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      g_top_hover = 0;
      return 0;
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
          Gdiplus::Color(224, 39, 41, 48), Gdiplus::Color(244, 14, 15, 19));
      graphics.FillRectangle(&surface, 0, 0, rect.right, rect.bottom);
      Gdiplus::Pen surface_edge(Gdiplus::Color(76, 255, 255, 255), 1.0f);
      graphics.DrawLine(&surface_edge, 18.0f, 1.0f, rect.right - 18.0f, 1.0f);
      const float width = static_cast<float>(rect.right);
      const double duration = g_duration.load();
      const double position = g_position.load();
      const float fraction = duration > 0
                                 ? static_cast<float>(std::min(1.0, position / duration))
                                 : 0.0f;
      Gdiplus::Pen track(Gdiplus::Color(105, 115, 119, 130), 4);
      track.SetStartCap(Gdiplus::LineCapRound);
      track.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&track, 24.0f, 19.0f, width - 24.0f, 19.0f);
      const float cached = static_cast<float>(
          std::clamp(g_cache_fraction.load(), 0.0, 1.0));
      Gdiplus::Pen cache_progress(Gdiplus::Color(210, 139, 174, 224), 4);
      cache_progress.SetStartCap(Gdiplus::LineCapRound);
      cache_progress.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&cache_progress, 24.0f, 19.0f,
                        24.0f + (width - 48.0f) * cached, 19.0f);
      Gdiplus::Pen progress(Gdiplus::Color(255, 110, 168, 255), 4);
      progress.SetStartCap(Gdiplus::LineCapRound);
      progress.SetEndCap(Gdiplus::LineCapRound);
      graphics.DrawLine(&progress, 24.0f, 19.0f,
                        24.0f + (width - 48.0f) * fraction, 19.0f);
      const float played_x = 24.0f + (width - 48.0f) * fraction;
      const double hover_fraction = g_seek_hover.load();
      const bool hovering_seek = hover_fraction >= 0;
      Gdiplus::SolidBrush thumb(Gdiplus::Color(255, 245, 248, 255));
      const float thumb_size = hovering_seek ? 12.0f : 8.0f;
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
        auto preview_font = MakeInterfaceFont(9, Gdiplus::FontStyleRegular);
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
      const float controls_y = 72.0f;
      const bool compact = width < 780;
      DrawHover(graphics, kBackTen, center - 76, controls_y, 42);
      DrawHover(graphics, kForwardTen, center + 76, controls_y, 42);
      if (!compact) {
        DrawHover(graphics, kPreviousEpisode, center - 140, controls_y, 42);
        DrawHover(graphics, kNextEpisode, center + 140, controls_y, 42);
      }
      const float play_hover = HoverAmount(kPlayPause);
      if (play_hover > 0.001f) {
        Gdiplus::SolidBrush play_glow(Gdiplus::Color(
            static_cast<BYTE>(24 + play_hover * 68), 110, 168, 255));
        const float glow_size = 48.0f + play_hover * 10.0f;
        graphics.FillEllipse(
            &play_glow, Gdiplus::RectF(center - glow_size / 2,
                                       controls_y - glow_size / 2, glow_size,
                                       glow_size));
      }
      graphics.FillEllipse(&white,
                           Gdiplus::RectF(center - 24 - play_hover,
                                          controls_y - 24 - play_hover,
                                          48 + play_hover * 2,
                                          48 + play_hover * 2));
      DrawPlayIcon(graphics, center, controls_y, g_play_state_mix, play_hover);
      auto font = MakeInterfaceFont(13, Gdiplus::FontStyleRegular);
      Gdiplus::StringFormat centered;
      centered.SetAlignment(Gdiplus::StringAlignmentCenter);
      centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      DrawSeekIcon(graphics, center - 76, controls_y, false,
                   HoverAmount(kBackTen));
      DrawSeekIcon(graphics, center + 76, controls_y, true,
                   HoverAmount(kForwardTen));
      if (!compact) {
        DrawSkipIcon(graphics, center - 140, controls_y, false,
                     HoverAmount(kPreviousEpisode));
        DrawSkipIcon(graphics, center + 140, controls_y, true,
                     HoverAmount(kNextEpisode));
      }
      wchar_t time[64]{};
      const auto seconds = static_cast<int>(position);
      const auto total = static_cast<int>(duration);
      swprintf_s(time, L"%02d:%02d  /  %02d:%02d", seconds / 60,
                 seconds % 60, total / 60, total % 60);
      if (g_playback_error.load()) {
        Gdiplus::SolidBrush error(Gdiplus::Color(255, 255, 132, 124));
        auto status_font = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
        graphics.DrawString(L"播放失败 · 请更换资源", -1, &status_font,
                            Gdiplus::PointF(24, 63), &error);
      } else if (g_buffering.load()) {
        Gdiplus::SolidBrush accent(Gdiplus::Color(255, 110, 168, 255));
        Gdiplus::Pen spinner(Gdiplus::Color(255, 110, 168, 255), 1.8f);
        ConfigureControlPen(spinner);
        graphics.DrawArc(&spinner, Gdiplus::RectF(23, 66, 10, 10),
                         g_buffer_phase, 245);
        auto status_font = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
        graphics.DrawString(L"缓冲中", -1, &status_font,
                            Gdiplus::PointF(37, 63), &accent);
      } else {
        graphics.DrawString(time, -1, &font, Gdiplus::PointF(24, 64), &quiet);
      }
      if (!compact) {
        DrawHover(graphics, kMute, width - 287, controls_y, 36);
        DrawSpeaker(graphics, width - 289, controls_y, g_muted.load(),
                    HoverAmount(kMute));
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
                          width - 265.0f + 58.0f * volume_fraction,
                          controls_y);
        graphics.FillEllipse(
            &white,
            Gdiplus::RectF(width - 268 + 58 * volume_fraction,
                           controls_y - 3, 6, 6));
        DrawHover(graphics, kAudio, width - 176, controls_y, 34);
        DrawAudioIcon(graphics, width - 176, controls_y, HoverAmount(kAudio));
        DrawHover(graphics, kPlaylist, width - 100, controls_y, 34);
        DrawPlaylistIcon(graphics, width - 100, controls_y,
                         HoverAmount(kPlaylist));
      }
      const float subtitle_x = compact ? width - 118.0f : width - 138.0f;
      const float settings_x = compact ? width - 76.0f : width - 62.0f;
      const float fullscreen_x = compact ? width - 30.0f : width - 24.0f;
      DrawHover(graphics, kSubtitle, subtitle_x, controls_y, 34);
      DrawSubtitleIcon(graphics, subtitle_x, controls_y,
                       HoverAmount(kSubtitle));
      DrawHover(graphics, kPlaybackSettings, settings_x, controls_y, 34);
      DrawSettingsIcon(graphics, settings_x, controls_y,
                       HoverAmount(kPlaybackSettings));
      DrawHover(graphics, kFullscreen, fullscreen_x, controls_y, 34);
      DrawFullscreen(graphics, fullscreen_x, controls_y, g_fullscreen,
                     HoverAmount(kFullscreen));
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
      const bool compact = rect.right < 780;
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
      } else if (!compact && x >= center - 166 && x < center - 116) {
        MpvCommand("playlist-prev", "weak");
        ShowToast("上一集");
      } else if (x >= center - 104 && x < center - 48) {
        MpvCommand("seek", "-10", "relative");
        ShowToast("后退 10 秒");
      } else if (x > center + 48 && x <= center + 104) {
        MpvCommand("seek", "10", "relative");
        ShowToast("前进 10 秒");
      } else if (!compact && x > center + 116 && x <= center + 166) {
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

int VirtualKeyForShortcutLabel(std::wstring label) {
  std::transform(label.begin(), label.end(), label.begin(), ::towupper);
  if (label == L"SPACE") return VK_SPACE;
  if (label == L"ARROW LEFT") return VK_LEFT;
  if (label == L"ARROW RIGHT") return VK_RIGHT;
  if (label == L"ARROW UP") return VK_UP;
  if (label == L"ARROW DOWN") return VK_DOWN;
  if (label == L"ENTER") return VK_RETURN;
  if (label == L"ESCAPE") return VK_ESCAPE;
  if (label == L"BACKSPACE") return VK_BACK;
  if (label == L"TAB") return VK_TAB;
  if (label == L"DELETE") return VK_DELETE;
  if (label == L"INSERT") return VK_INSERT;
  if (label == L"HOME") return VK_HOME;
  if (label == L"END") return VK_END;
  if (label == L"PAGE UP") return VK_PRIOR;
  if (label == L"PAGE DOWN") return VK_NEXT;
  if (label == L"SHIFT LEFT" || label == L"SHIFT RIGHT") return VK_SHIFT;
  if (label == L"CONTROL LEFT" || label == L"CONTROL RIGHT") return VK_CONTROL;
  if (label == L"ALT LEFT" || label == L"ALT RIGHT") return VK_MENU;
  if (label == L"META LEFT" || label == L"META RIGHT") return VK_LWIN;
  if (label.size() >= 2 && label[0] == L'F') {
    const int function_number = _wtoi(label.c_str() + 1);
    if (function_number >= 1 && function_number <= 24) {
      return VK_F1 + function_number - 1;
    }
  }
  if (label.size() == 1) {
    const SHORT key = VkKeyScanW(label[0]);
    return key == -1 ? 0 : LOBYTE(key);
  }
  return 0;
}

void SetShortcut(const std::string& action, const std::wstring& label) {
  const int key = VirtualKeyForShortcutLabel(label);
  if (key != 0) g_shortcuts[key] = action;
}

bool RunShortcut(int key) {
  const auto shortcut = g_shortcuts.find(key);
  if (shortcut == g_shortcuts.end()) return false;
  const std::string& action = shortcut->second;
  if (action == "playPause") {
    MpvCommand("cycle", "pause");
  } else if (action == "seekBack") {
    MpvCommand("seek", std::to_string(-g_seek_seconds).c_str(), "relative");
  } else if (action == "seekForward") {
    MpvCommand("seek", std::to_string(g_seek_seconds).c_str(), "relative");
  } else if (action == "volumeUp") {
    MpvCommand("add", "volume", std::to_string(g_volume_step).c_str());
  } else if (action == "volumeDown") {
    MpvCommand("add", "volume", std::to_string(-g_volume_step).c_str());
  } else if (action == "mute") {
    MpvCommand("cycle", "mute");
  } else if (action == "fullscreen") {
    ToggleFullscreen();
  } else if (action == "exit") {
    SendMessageW(g_window, WM_CLOSE, 0, 0);
  } else {
    return false;
  }
  return true;
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam) return 0;
      return DefWindowProcW(window, message, wparam, lparam);
    case WM_NCHITTEST: {
      const LRESULT hit = DefWindowProcW(window, message, wparam, lparam);
      if (hit != HTCLIENT) return hit;
      if (g_fullscreen) return HTCLIENT;
      RECT rect{};
      GetWindowRect(window, &rect);
      const int x = GET_X_LPARAM(lparam);
      const int y = GET_Y_LPARAM(lparam);
      constexpr int grip = 7;
      const bool left = x < rect.left + grip;
      const bool right = x >= rect.right - grip;
      const bool top = y < rect.top + grip;
      const bool bottom = y >= rect.bottom - grip;
      if (top && left) return HTTOPLEFT;
      if (top && right) return HTTOPRIGHT;
      if (bottom && left) return HTBOTTOMLEFT;
      if (bottom && right) return HTBOTTOMRIGHT;
      if (left) return HTLEFT;
      if (right) return HTRIGHT;
      if (top) return HTTOP;
      if (bottom) return HTBOTTOM;
      return HTCLIENT;
    }
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = 720;
      info->ptMinTrackSize.y = 480;
      return 0;
    }
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
      if (RunShortcut(static_cast<int>(wparam))) return 0;
      return DefWindowProcW(window, message, wparam, lparam);
    case WM_TIMER: {
      if (AnimateControlHover() && g_controls) {
        InvalidateRect(g_controls, nullptr, FALSE);
      }
      if (AnimateTopHover() && g_top_bar) {
        InvalidateRect(g_top_bar, nullptr, FALSE);
      }
      const float play_target = g_paused.load() ? 1.0f : 0.0f;
      const float play_delta = play_target - g_play_state_mix;
      if (std::abs(play_delta) > 0.001f) {
        g_play_state_mix += std::clamp(play_delta, -0.24f, 0.24f);
        if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
      }
      if (g_buffering.load()) {
        g_buffer_phase = std::fmod(g_buffer_phase + 22.0f, 360.0f);
        if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
      }
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
          SetLayeredWindowAttributes(g_top_bar, kOverlayColorKey,
                                     g_controls_alpha,
                                     LWA_ALPHA | LWA_COLORKEY);
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
  wchar_t executable_path[MAX_PATH]{};
  if (GetModuleFileNameW(nullptr, executable_path, MAX_PATH) > 0) {
    const std::filesystem::path font_path =
        std::filesystem::path(executable_path).parent_path() / L"data" /
        L"flutter_assets" / L"app" / L"fonts" /
        L"AlimamaFangYuanTi-Player.ttf";
    g_interface_font_collection =
        std::make_unique<Gdiplus::PrivateFontCollection>();
    if (g_interface_font_collection->AddFontFile(font_path.c_str()) ==
        Gdiplus::Ok) {
      Gdiplus::FontFamily families[1];
      int family_count = 0;
      if (g_interface_font_collection->GetFamilies(1, families,
                                                   &family_count) ==
              Gdiplus::Ok &&
          family_count > 0) {
        wchar_t family_name[LF_FACESIZE]{};
        if (families[0].GetFamilyName(family_name) == Gdiplus::Ok) {
          auto family = std::make_unique<Gdiplus::FontFamily>(
              family_name, g_interface_font_collection.get());
          if (family->IsAvailable()) {
            g_interface_font_family = std::move(family);
          }
        }
      }
    }
  }

  HWND window = CreateWindowExW(
      0, kWindowClass, L"Mova",
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
          WS_CLIPCHILDREN,
      CW_USEDEFAULT, CW_USEDEFAULT, 1280, 760, nullptr, nullptr, instance,
      nullptr);
  if (!window) return 3;
  g_window = window;
  const COLORREF border_color = DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border_color,
                        sizeof(border_color));
  DragAcceptFiles(window, TRUE);
  g_windowed_style = GetWindowLongPtrW(window, GWL_STYLE);
  g_controls = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kControlsClass,
                               L"", WS_POPUP, 0, 0, 1, 1, window, nullptr,
                               instance, nullptr);
  SetLayeredWindowAttributes(g_controls, 0, 232, LWA_ALPHA);
  g_top_bar = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kTopBarClass,
                              L"", WS_POPUP, 0, 0, 1, 1, window, nullptr,
                              instance, nullptr);
  SetLayeredWindowAttributes(g_top_bar, kOverlayColorKey, 232,
                             LWA_ALPHA | LWA_COLORKEY);
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
  SetShortcut("playPause", L"Space");
  SetShortcut("seekBack", L"Arrow Left");
  SetShortcut("seekForward", L"Arrow Right");
  SetShortcut("volumeUp", L"Arrow Up");
  SetShortcut("volumeDown", L"Arrow Down");
  SetShortcut("mute", L"M");
  SetShortcut("fullscreen", L"F");
  SetShortcut("exit", L"Escape");
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
        } else if (name == "mova-playlist-detail") {
          g_playlist_details.push_back(argument.substr(equals + 1));
        } else if (name == "mova-series-logo") {
          g_series_logo_path = argument.substr(equals + 1);
        } else if (name == "mova-seek-seconds") {
          g_seek_seconds = std::max(1.0, std::strtod(
              Utf8(argument.substr(equals + 1)).c_str(), nullptr));
        } else if (name == "mova-volume-step") {
          g_volume_step = std::max(1.0, std::strtod(
              Utf8(argument.substr(equals + 1)).c_str(), nullptr));
        } else if (name == "mova-danmaku-enabled") {
          g_danmaku_enabled = Utf8(argument.substr(equals + 1)) == "yes";
        } else if (name == "mova-auto-skip-segments") {
          g_auto_skip_segments = Utf8(argument.substr(equals + 1)) == "yes";
        } else if (name == "mova-shortcut") {
          const std::wstring shortcut = argument.substr(equals + 1);
          const auto divider = shortcut.find(L'|');
          if (divider != std::wstring::npos) {
            const std::string action = Utf8(shortcut.substr(0, divider));
            const std::wstring label = shortcut.substr(divider + 1);
            const int virtual_key = VirtualKeyForShortcutLabel(label);
            if (virtual_key != 0) {
              for (auto it = g_shortcuts.begin(); it != g_shortcuts.end();) {
                if (it->second == action) it = g_shortcuts.erase(it);
                else ++it;
              }
              g_shortcuts[virtual_key] = action;
            }
          }
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
  while (g_playlist_details.size() < media_urls.size()) {
    g_playlist_details.emplace_back();
  }
  if (!g_series_logo_path.empty()) {
    auto logo = std::make_unique<Gdiplus::Bitmap>(g_series_logo_path.c_str());
    if (logo->GetLastStatus() == Gdiplus::Ok) {
      g_series_logo = std::move(logo);
    }
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
        } else if (line.rfind("MOVA_NETWORK=", 0) == 0) {
          g_network_bytes_per_second = std::max(
              0.0, std::strtod(line.c_str() + 13, nullptr));
          PostMessageW(g_window, kPlayerStateChanged, 0, 0);
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
      if (event->event_id == MPV_EVENT_END_FILE && event->data) {
        const auto* end = static_cast<mpv_event_end_file*>(event->data);
        if (end->reason == MPV_END_FILE_REASON_EOF) {
          std::fprintf(stdout, "MOVA_COMPLETED=%lld\r\n",
                       static_cast<long long>(g_playlist_position.load()));
          std::fflush(stdout);
        } else if (end->reason == MPV_END_FILE_REASON_ERROR) {
          g_playback_error = true;
          PostMessageW(window, kPlayerStateChanged, 0, 0);
        }
      }
      if (event->event_id == MPV_EVENT_FILE_LOADED) {
        g_playback_error = false;
        PostMessageW(window, kPlayerStateChanged, 0, 0);
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
