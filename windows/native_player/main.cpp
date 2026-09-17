#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <gdiplus.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cwctype>
#include <cstdio>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
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
// 画面亮度（mpv 的 video equalizer，-100..100）。面板里用时读、由属性观察回填。
std::atomic<double> g_brightness{0};
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
std::unique_ptr<Gdiplus::PrivateFontCollection> g_iconsax_font_collection;
std::unique_ptr<Gdiplus::FontFamily> g_iconsax_font_family;
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
// 剧集面板需要的结构化季 / 集 / 集名，与 g_playlist_titles 同序、按项并行下发。
// 空串表示该项已知为「未知」，面板据此省略对应的那一段文案，而不是猜一个 1。
std::vector<std::wstring> g_playlist_seasons;
std::vector<std::wstring> g_playlist_episodes;
std::vector<std::wstring> g_playlist_episode_titles;
// 资源版本列表：应用已经把「所有已连接服务器」的版本聚合好，原生只负责展示与回选。
std::vector<std::wstring> g_resource_sources;
std::vector<std::wstring> g_resource_details;
// 资源版本的服务器标识：图标文件路径、来源类型、名次。图标由应用按详情页
// ServerMark 的规则取到本地缓存后只下发路径，原生不发任何网络请求，地址与
// 令牌始终留在应用侧。
std::vector<std::wstring> g_resource_icons;
std::vector<int> g_resource_marks;
std::vector<int> g_resource_ranks;
int g_resource_current = -1;
// 剧集面板的缩略图与观看进度。缩略图同样是本地文件路径；进度是 0..1 的分数，
// 时长以秒计，用来在缩略图上画进度条与「13:00 / 44:00」。
std::vector<std::wstring> g_playlist_images;
std::vector<std::wstring> g_playlist_meta;
std::vector<double> g_playlist_progress;
std::vector<double> g_playlist_durations;
std::vector<bool> g_playlist_watched;
int g_panel_hover = -1;
float g_play_state_mix = 0.0f;
float g_buffer_phase = 0.0f;
double g_seek_seconds = 10.0;
double g_volume_step = 5.0;
std::unordered_map<int, std::string> g_shortcuts;
bool g_danmaku_enabled = false;
bool g_auto_skip_segments = true;

enum class PanelRow {
  /// 可选项：图标 + 标题 + 明细 + 末尾状态图标，对齐应用内「预选音轨与字幕」。
  Option,
  /// 分组标题：图标 + 名称 + 右侧计数胶囊。
  Header,
  /// 说明文字：不可点，一个图标加一行灰字。
  Note,
  /// 剧集卡：缩略图 + 标题 + 观看进度，按列排布成网格。
  Episode,
};

struct PanelItem {
  std::wstring label;
  std::wstring detail;
  std::wstring badge;
  wchar_t icon = 0;
  std::string property;
  std::string value;
  std::string toast;
  bool selected = false;
  bool enabled = true;
  PanelRow row = PanelRow::Option;
  /// 应用下发到本地的图片路径：剧集缩略图，或服务器图标。空则由调用方画兜底。
  std::wstring image;
  /// 剧集卡的观看进度（0..1，负数表示没有观看记录）与时长（秒）。
  double progress = -1.0;
  double duration = 0.0;
  /// 已播完的集：画对勾、不画进度条。与 progress 解耦 —— 服务器上标记了
  /// 「已播放」但没有任何播放位置的集 progress 是 0，单看进度会漏。
  bool watched = false;
  /// 无图标文件时的兜底标记：1 Emby、2 Jellyfin、3 WebDAV、0 表示画普通图标。
  int mark = 0;
  /// 资源版本的名次（1..3 描一圈金属色），0 表示不描。
  int rank = 0;
};

PanelItem PanelOption(wchar_t icon, std::wstring label, std::wstring detail,
                      std::string property, std::string value,
                      std::string toast, bool selected,
                      std::wstring badge = std::wstring()) {
  PanelItem item;
  item.label = std::move(label);
  item.detail = std::move(detail);
  item.badge = std::move(badge);
  item.icon = icon;
  item.property = std::move(property);
  item.value = std::move(value);
  item.toast = std::move(toast);
  item.selected = selected;
  return item;
}

PanelItem PanelHeader(wchar_t icon, std::wstring label, std::wstring badge) {
  PanelItem item;
  item.label = std::move(label);
  item.badge = std::move(badge);
  item.icon = icon;
  item.row = PanelRow::Header;
  return item;
}

PanelItem PanelNote(wchar_t icon, std::wstring label) {
  PanelItem item;
  item.label = std::move(label);
  item.icon = icon;
  item.enabled = false;
  item.row = PanelRow::Note;
  return item;
}

// 剧集卡：缩略图 + 「第 X 集 · 集名」+ 季与日期时长 + 观看进度。选中态就是
// 正在播的那一集。
PanelItem PanelEpisode(wchar_t icon, std::wstring label, std::wstring detail,
                       std::wstring image, double progress, double duration,
                       bool selected, bool watched = false) {
  PanelItem item;
  item.label = std::move(label);
  item.detail = std::move(detail);
  item.icon = icon;
  item.image = std::move(image);
  item.progress = progress;
  item.duration = duration;
  item.selected = selected;
  item.watched = watched;
  item.row = PanelRow::Episode;
  return item;
}

// 弹出菜单的度量与 Flutter 弹窗对齐：卡片式行、12px 圆角、图标容器 34px。
constexpr int kPanelPadding = 10;
constexpr float kPanelRowGap = 6.0f;
constexpr float kPanelOptionHeight = 68.0f;
constexpr float kPanelHeaderHeight = 32.0f;
constexpr float kPanelNoteHeight = 34.0f;
constexpr int kPanelContentWidth = 344;
constexpr int kPanelMaxContentHeight = 470;
// 逐像素透明才能得到真正的圆角抗锯齿与投影，所以窗口比内容四周各多一圈。
constexpr int kPanelShadowMargin = 26;
// 玻璃表面那圈内描边的不透明度。面板与控件条共用同一个值 —— 此前控件条用的是
// 76，白线叠在深色底上算出 103 的亮度，在一片 40 左右的深灰里就是一条刺眼的
// 白条，而且和面板的 46 不同，两处描边看起来不是一套皮肤。
constexpr BYTE kSurfaceEdgeAlpha = 46;
// 剧集列表：一行一集，缩略图在左（16:9）、标题与副标题在右。此前是三列网格，
// 卡片只有 186px 宽，「第 X 集 · 集名」几乎必然截断成省略号；一行一集后
// 标题有整行可用，信息行也放得下「第 X 季 · 日期 · 时长」全串。
constexpr float kEpisodeRowInset = 8.0f;
constexpr float kEpisodeRowThumbWidth = 128.0f;
constexpr float kEpisodeRowThumbHeight = 72.0f;
constexpr float kEpisodeRowHeight =
    kEpisodeRowThumbHeight + kEpisodeRowInset * 2.0f;
constexpr int kPanelEpisodeWidth = 480;
// 资源面板的信息行是「分辨率 · 色彩范围 · 码率 · 大小」，344 的默认宽度
// 装不下，会被省略号截掉末尾的大小。
constexpr int kPanelResourceWidth = 430;

// 弹窗的锚点。此前调用方只传一个 y，且底部控件条也复用顶栏那个客户区 y=40 的
// 常量，于是「面板底边 = 锚点 y − 内容高 − 8」算出来的位置落在窗口之外，被夹到
// 工作区顶端 —— 点底部工具时菜单会跳到画面顶部。
//
// 现在锚点描述的是「控件在屏幕上的哪条边」，由 open_above 决定面板贴边方向：
// 底部控件条取控件条顶边并向上展开，顶栏取顶栏底边并向下展开。
struct PanelAnchor {
  int x = 0;
  int y = 0;
  bool open_above = true;
};

// 面板的整体度量。所有面板共用默认值，只按内容需要换宽度。
struct PanelMetrics {
  int width = kPanelContentWidth;
  int max_height = kPanelMaxContentHeight;
  /// 打开时需要滚动到可见的行下标（剧集面板用来定位正在播的那一集）。
  int reveal = -1;
};

// 一行在面板内容坐标系里的位置。每个元素独占一行 —— 剧集改为一行一集后，
// 面板里不再有网格排版，命中测试与绘制都只认盒子。
struct PanelBox {
  float x = 0.0f;
  float y = 0.0f;
  float w = 0.0f;
  float h = 0.0f;
};

PanelAnchor g_panel_anchor{};
PanelMetrics g_panel_metrics{};

int g_panel_content_height = 0;
std::vector<PanelItem> g_panel_items;
std::vector<PanelBox> g_panel_boxes;
int g_panel_scroll = 0;
int g_panel_viewport_height = 0;

float PanelRowHeight(const PanelItem& item) {
  switch (item.row) {
    case PanelRow::Header:
      return kPanelHeaderHeight;
    case PanelRow::Note:
      return kPanelNoteHeight;
    case PanelRow::Episode:
      return kEpisodeRowHeight;
    default:
      return kPanelOptionHeight;
  }
}

// 排版一遍并刷新内容高。每个元素独占一行，横跨整宽；行高由 PanelRowHeight
// 决定，季分组标题夹在剧集行中间也只是普通的一行。
void LayoutPanelRows() {
  g_panel_boxes.assign(g_panel_items.size(), PanelBox{});
  if (g_panel_items.empty()) {
    g_panel_content_height = kPanelPadding * 2;
    return;
  }
  const float left = static_cast<float>(kPanelPadding);
  const float full = static_cast<float>(g_panel_metrics.width) -
                     kPanelPadding * 2.0f;
  float y = static_cast<float>(kPanelPadding);
  for (size_t index = 0; index < g_panel_items.size(); ++index) {
    const float height = PanelRowHeight(g_panel_items[index]);
    g_panel_boxes[index] = {left, y, full, height};
    y += height + kPanelRowGap;
  }
  g_panel_content_height =
      static_cast<int>(std::max(0.0f, y - kPanelRowGap)) + kPanelPadding;
}

int PanelContentHeight() { return g_panel_content_height; }

int PanelMaxScroll() {
  return std::max(0, PanelContentHeight() - g_panel_viewport_height);
}

void ScrollPanel(int delta) {
  const int next = std::clamp(g_panel_scroll + delta, 0, PanelMaxScroll());
  if (next == g_panel_scroll) return;
  g_panel_scroll = next;
  if (g_panel) InvalidateRect(g_panel, nullptr, FALSE);
}

int PanelIndexAt(int x, int y) {
  const float local_x = static_cast<float>(x - kPanelShadowMargin);
  const float local_y = static_cast<float>(y - kPanelShadowMargin + g_panel_scroll);
  for (size_t index = 0; index < g_panel_boxes.size(); ++index) {
    const PanelBox& box = g_panel_boxes[index];
    if (local_y >= box.y && local_y < box.y + box.h && local_x >= box.x &&
        local_x < box.x + box.w) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

void ShowControls();
std::string Utf8(const std::wstring& value);
void OpenPanel(std::vector<PanelItem> items, PanelAnchor anchor,
               PanelMetrics metrics);
// 提示浮层的两种形态：贴控件上方的名称提示，和调整操作时的实时反馈。
enum class HintMode { Hidden, Tooltip, Toast };

void ShowHint(const std::wstring& text, const std::wstring& detail,
              wchar_t icon, HintMode mode, float fraction, int anchor_x);
void HideHint();
void ShowAdjustHint(const std::wstring& title, const std::wstring& detail,
                    wchar_t icon, float fraction);
std::wstring ControlTooltip(int control);

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

void ShowToast(const std::string& text);

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

// 一行反馈。以前是 mpv 的 show-text，字体、位置、配色全是 mpv 的；现在和面板
// 走同一个自绘浮层，位置也固定贴在控件条上方，不再压在画面中间。
void ShowToast(const std::string& text) {
  if (text.empty()) return;
  ShowHint(Wide(text), std::wstring(), 0, HintMode::Toast, -1.0f, 0);
}

struct MediaTrack {
  std::string id;
  std::wstring title;
  std::wstring detail;
  bool selected = false;
  bool is_default = false;
};

// 轨道用的是 mpv 的元数据，展示口径要和应用内弹窗一致：名称在上、编解码与
// 语言在下，而不是把「标题 · 语言」拼成一行塞进同一句话里。
std::wstring LanguageName(const std::string& code) {
  if (code.empty()) return {};
  std::string lowered;
  lowered.reserve(code.size());
  for (const char character : code) {
    lowered.push_back(static_cast<char>(
        std::tolower(static_cast<unsigned char>(character))));
  }
  const auto starts_with = [&lowered](const char* value) {
    return lowered.rfind(value, 0) == 0;
  };
  if (starts_with("zh") || starts_with("chi") || starts_with("zho") ||
      starts_with("cmn")) {
    if (lowered.find("hant") != std::string::npos ||
        lowered.find("tw") != std::string::npos) {
      return L"繁体中文";
    }
    return lowered.find("hans") != std::string::npos ? L"简体中文" : L"中文";
  }
  if (starts_with("en") || starts_with("eng")) return L"英语";
  if (starts_with("ja") || starts_with("jpn")) return L"日语";
  if (starts_with("ko") || starts_with("kor")) return L"韩语";
  if (starts_with("fr") || starts_with("fra") || starts_with("fre")) {
    return L"法语";
  }
  if (starts_with("de") || starts_with("deu") || starts_with("ger")) {
    return L"德语";
  }
  if (starts_with("es") || starts_with("spa")) return L"西班牙语";
  if (starts_with("ru") || starts_with("rus")) return L"俄语";
  if (starts_with("pt") || starts_with("por")) return L"葡萄牙语";
  if (starts_with("it") || starts_with("ita")) return L"意大利语";
  if (starts_with("ar") || starts_with("ara")) return L"阿拉伯语";
  if (starts_with("th") || starts_with("tha")) return L"泰语";
  return Wide(code);
}

std::wstring TrackDetail(const std::string& prefix, const std::string& language,
                         bool audio) {
  std::wstring detail;
  const auto append = [&detail](const std::wstring& part) {
    if (part.empty()) return;
    if (!detail.empty()) detail += L" · ";
    detail += part;
  };
  const std::string codec = MpvString(prefix + "codec");
  if (!codec.empty()) {
    std::string upper = codec;
    for (char& character : upper) {
      character = static_cast<char>(
          std::toupper(static_cast<unsigned char>(character)));
    }
    append(Wide(upper));
  }
  if (!language.empty()) append(LanguageName(language));
  if (audio) {
    const std::string channels = MpvString(prefix + "demux-channel-count");
    const int channel_count = std::atoi(channels.c_str());
    if (channel_count > 0) {
      append(std::to_wstring(channel_count) + L" 声道");
    }
    const std::string rate = MpvString(prefix + "samplerate");
    if (!rate.empty() && std::atoi(rate.c_str()) > 0) {
      append(Wide(rate) + L" Hz");
    }
  }
  return detail;
}

std::wstring ClockLabel(double seconds) {
  if (seconds < 0.0) return L"--:--";
  const int total = static_cast<int>(seconds + 0.5);
  wchar_t text[24]{};
  swprintf_s(text, L"%02d:%02d:%02d", total / 3600, (total / 60) % 60,
             total % 60);
  return text;
}

std::vector<MediaTrack> ReadTracks(const char* wanted_type) {
  std::vector<MediaTrack> tracks;
  const bool audio = std::string(wanted_type) == "audio";
  const int count = std::atoi(MpvString("track-list/count").c_str());
  for (int index = 0; index < count; ++index) {
    const std::string prefix = "track-list/" + std::to_string(index) + "/";
    if (MpvString(prefix + "type") != wanted_type) continue;
    const std::string language = MpvString(prefix + "lang");
    const std::string title = MpvString(prefix + "title");
    const std::string codec = MpvString(prefix + "codec");
    std::wstring label = Wide(title);
    if (label.empty()) label = LanguageName(language);
    if (label.empty() && !codec.empty()) {
      std::string upper = codec;
      for (char& character : upper) {
        character = static_cast<char>(
            std::toupper(static_cast<unsigned char>(character)));
      }
      label = Wide(upper);
    }
    if (label.empty()) {
      label = (audio ? L"音轨 " : L"字幕 ") +
              std::to_wstring(tracks.size() + 1);
    }
    tracks.push_back({MpvString(prefix + "id"), label,
                      TrackDetail(prefix, language, audio),
                      MpvString(prefix + "selected") == "yes",
                      MpvString(prefix + "default") == "yes"});
  }
  return tracks;
}

// 图标与工具栏保持同一套语义：音轨用扬声器、字幕用字幕框、自动用星标。
constexpr wchar_t kGlyphSpeaker = L'\xF08F';
constexpr wchar_t kGlyphSubtitle = L'\xEFCE';
constexpr wchar_t kGlyphSparkles = L'\xED43';
constexpr wchar_t kGlyphInfo = L'\xECDD';
// 剧集与资源面板在 ToolGlyph 之前就要用到这两个字形，所以定义在这一段。
// 二者都取自与应用 YingjiIcons 同一张表：kGlyphEpisodes = document_text（列表）、
// kGlyphServer = data（应用里 "资源" 用的就是它）。
constexpr wchar_t kGlyphEpisodes = L'\xEB73';
constexpr wchar_t kGlyphServer = L'\xEB14';
// 面板行里用到的其余字形。定义在这一段而不是面板绘制那一节，是因为「倍速」
// 「画面」这类只放自己的面板在更早的地方就要引用它们。
constexpr wchar_t kGlyphCheckCircle = L'\xF006';
constexpr wchar_t kGlyphRadio = L'\xEEA2';
constexpr wchar_t kGlyphChevronRight = L'\xE96C';
constexpr wchar_t kGlyphGauge = L'\xEFAE';
constexpr wchar_t kGlyphCrop = L'\xEB06';
constexpr wchar_t kGlyphScissors = L'\xEE3E';
constexpr wchar_t kGlyphBookmark = L'\xE9EC';
constexpr wchar_t kGlyphEpisode = L'\xF06E';
constexpr wchar_t kGlyphDanmaku = L'\xED93';
constexpr wchar_t kGlyphMore = L'\xEDDF';

void ShowTrackMenu(HWND owner, bool audio, PanelAnchor anchor) {
  (void)owner;
  const auto tracks = ReadTracks(audio ? "audio" : "sub");
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(audio ? kGlyphSpeaker : kGlyphSubtitle,
                              audio ? L"音轨" : L"字幕",
                              std::to_wstring(tracks.size()) + L" 条"));
  const std::string active = MpvString(audio ? "aid" : "sid");
  items.push_back(PanelOption(kGlyphSparkles, L"自动选择",
                              audio ? L"使用播放器的默认音轨"
                                    : L"按字幕语言偏好智能选择",
                              audio ? "aid" : "sid", "auto",
                              audio ? "音轨：自动选择" : "字幕：自动选择",
                              active == "auto"));
  if (!audio) {
    items.push_back(PanelOption(kGlyphSubtitle, L"关闭字幕",
                                L"播放时不加载字幕轨道", "sid", "no",
                                "字幕已关闭", active == "no"));
  }
  for (const auto& track : tracks) {
    items.push_back(PanelOption(audio ? kGlyphSpeaker : kGlyphSubtitle,
                                track.title, track.detail,
                                audio ? "aid" : "sid", track.id,
                                std::string(audio ? "音轨：" : "字幕：") +
                                    Utf8(track.title),
                                track.selected,
                                track.is_default ? L"默认" : std::wstring()));
  }
  if (tracks.empty()) {
    items.push_back(PanelNote(
        kGlyphInfo, audio ? L"当前片源只有这一路音轨" : L"当前片源没有内嵌字幕"));
  }
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

// 「1.0×」这种说法。整数倍去掉小数点，其余保留两位有效位。
std::wstring SpeedLabel(double speed) {
  wchar_t buffer[16]{};
  if (std::abs(speed - std::round(speed)) < 0.001) {
    swprintf_s(buffer, L"%.0f×", speed);
  } else {
    swprintf_s(buffer, L"%g×", speed);
  }
  return buffer;
}

std::wstring BrightnessLabel() {
  const double value = g_brightness.load();
  if (std::abs(value) < 1.0) return L"标准";
  if (value <= -22.0) return L"更暗";
  if (value < 0.0) return L"稍暗";
  if (value >= 22.0) return L"更亮";
  return L"稍亮";
}

// 倍速面板只放倍速。此前「倍速」和「画面」都落进同一个 ShowPlaybackMenu，
// 点哪个都看到「播放速度 + 画面比例 + 弹幕说明 + 片头片尾说明」四段混装，
// 面板里全是跟自己无关的条目。
void ShowSpeedMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  const double current = g_speed.load();
  const double speeds[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0};
  const wchar_t* speed_labels[] = {L"0.5×", L"0.75×", L"正常速度",
                                   L"1.25×", L"1.5×", L"2.0×"};
  const wchar_t* speed_details[] = {L"半速", L"四分之三速", L"按原速播放",
                                    L"一点二五倍", L"一点五倍", L"两倍速"};
  std::wstring badge;
  for (int index = 0; index < 6; ++index) {
    if (std::abs(current - speeds[index]) < 0.01) badge = speed_labels[index];
  }
  if (badge.empty()) badge = SpeedLabel(current);
  items.push_back(PanelHeader(kGlyphGauge, L"倍速", badge));
  for (int index = 0; index < 6; ++index) {
    const bool selected = std::abs(current - speeds[index]) < 0.01;
    const std::string value = std::to_string(speeds[index]);
    items.push_back(PanelOption(kGlyphGauge, speed_labels[index],
                                speed_details[index], "speed", value,
                                "播放速度 " + Utf8(SpeedLabel(speeds[index])),
                                selected));
  }
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

// 画面面板只放画面：比例与亮度。亮度走 mpv 的 video equalizer，改完立刻生效，
// 面板收起时由提示浮层给出「亮度 稍亮」这样的实时反馈。
void ShowPictureMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  const std::string current_aspect = MpvString("video-aspect-override");
  const auto aspect_selected = [&current_aspect](const char* value) {
    if (std::string(value) == "0") {
      return current_aspect.empty() || current_aspect == "0" ||
             current_aspect == "no";
    }
    return current_aspect == value;
  };
  const wchar_t* aspect_labels[] = {L"自动", L"16:9", L"4:3", L"21:9"};
  const wchar_t* aspect_details[] = {L"跟随片源自带的画面比例", L"宽屏拉伸",
                                     L"传统电视比例", L"宽银幕比例"};
  const char* aspect_values[] = {"0", "1.7777778", "1.3333333", "2.3333333"};
  std::wstring aspect_badge;
  for (int index = 0; index < 4; ++index) {
    if (aspect_selected(aspect_values[index])) aspect_badge = aspect_labels[index];
  }
  items.push_back(PanelHeader(kGlyphCrop, L"画面比例", aspect_badge));
  for (int index = 0; index < 4; ++index) {
    items.push_back(PanelOption(kGlyphCrop, aspect_labels[index],
                                aspect_details[index], "video-aspect-override",
                                aspect_values[index],
                                std::string("画面比例 ") +
                                    Utf8(aspect_labels[index]),
                                aspect_selected(aspect_values[index])));
  }
  items.push_back(PanelHeader(kGlyphSparkles, L"亮度", BrightnessLabel()));
  const int levels[] = {-30, -15, 0, 15, 30};
  const wchar_t* brightness_labels[] = {L"更暗", L"稍暗", L"标准", L"稍亮",
                                        L"更亮"};
  const wchar_t* brightness_details[] = {L"压低整体亮度", L"轻度压暗",
                                         L"不额外调整", L"轻度提亮",
                                         L"拉高整体亮度"};
  const double brightness = g_brightness.load();
  for (int index = 0; index < 5; ++index) {
    items.push_back(PanelOption(
        kGlyphSparkles, brightness_labels[index], brightness_details[index],
        "brightness", std::to_string(levels[index]),
        "亮度 " + Utf8(brightness_labels[index]),
        std::abs(brightness - levels[index]) < 1.0));
  }
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

void ShowDanmakuMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(L'\xED93', L"弹幕", std::wstring()));
  items.push_back(PanelNote(kGlyphInfo, g_danmaku_enabled
                                          ? L"弹幕已在设置中开启"
                                          : L"弹幕未开启"));
  items.push_back(PanelNote(kGlyphInfo, L"Windows 原生窗口暂不渲染弹幕"));
  items.push_back(PanelNote(kGlyphInfo, L"请使用应用内播放器查看弹幕"));
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

void ShowSegmentMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(L'\xEE3E', L"片头片尾", std::wstring()));
  items.push_back(PanelNote(kGlyphInfo, g_auto_skip_segments
                                          ? L"自动跳过已开启"
                                          : L"自动跳过未开启"));
  items.push_back(PanelNote(kGlyphInfo, L"当前片源未传入片头片尾时间点"));
  items.push_back(PanelNote(kGlyphInfo, L"可在应用内播放器中使用片段跳转"));
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

void ShowChapterMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  const int count = std::atoi(MpvString("chapter-list/count").c_str());
  const int current = std::atoi(MpvString("chapter").c_str());
  std::wstring header = L"章节";
  if (count > 0) {
    header = std::to_wstring(current >= 0 ? current + 1 : 1) + L" / " +
             std::to_wstring(count);
  }
  items.push_back(PanelHeader(L'\xE9EC', L"章节", header));
  for (int index = 0; index < count; ++index) {
    const std::string prefix = "chapter-list/" + std::to_string(index) + "/";
    std::wstring title = Wide(MpvString(prefix + "title"));
    if (title.empty()) title = L"章节 " + std::to_wstring(index + 1);
    const double start = std::atof(MpvString(prefix + "time").c_str());
    items.push_back(PanelOption(L'\xE9EC', title, ClockLabel(start), "chapter",
                                std::to_string(index), "跳转到 " + Utf8(title),
                                current == index));
  }
  if (count == 0) {
    items.push_back(PanelNote(kGlyphInfo, L"当前片源没有章节信息"));
  }
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

// 播放列表里出现过的不同季数个数。用来决定剧集面板要不要插分组标题 ——
// 单季作品再插一行「第 1 季」只是噪音。
int PlaylistSeasonCount() {
  std::vector<std::wstring> seen;
  for (const auto& season : g_playlist_seasons) {
    if (season.empty()) continue;
    if (std::find(seen.begin(), seen.end(), season) == seen.end()) {
      seen.push_back(season);
    }
  }
  return static_cast<int>(seen.size());
}

void ShowEpisodeMenu(PanelAnchor anchor) {
  const size_t count = g_playlist_titles.size();
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(kGlyphEpisodes, L"剧集",
                              std::to_wstring(count) + L" 集"));
  const bool grouped = count > 1 && PlaylistSeasonCount() > 1;
  const int64_t playing = g_playlist_position.load();
  int reveal = -1;
  std::wstring current_season;
  for (size_t index = 0; index < count; ++index) {
    if (grouped) {
      const std::wstring season = index < g_playlist_seasons.size()
                                      ? g_playlist_seasons[index]
                                      : std::wstring();
      if (index == 0 || season != current_season) {
        current_season = season;
        items.push_back(PanelHeader(
            kGlyphEpisodes,
            season.empty() ? L"季信息缺失" : L"第 " + season + L" 季",
            std::wstring()));
      }
    }
    const bool selected = static_cast<int64_t>(index) == playing;
    if (selected) reveal = static_cast<int>(items.size());
    const std::wstring named = index < g_playlist_episode_titles.size()
                                   ? g_playlist_episode_titles[index]
                                   : std::wstring();
    const std::wstring number = index < g_playlist_episodes.size()
                                    ? g_playlist_episodes[index]
                                    : std::wstring();
    // 卡片标题是「第 X 集 · 集名」；没有集名时退回作品名（单集）或只留集号。
    std::wstring label;
    if (!number.empty()) label = L"第 " + number + L" 集";
    if (!named.empty()) {
      if (!label.empty()) label += L" · ";
      label += named;
    } else if (label.empty()) {
      label = count > 1 ? L"第 " + std::to_wstring(index + 1) + L" 集"
                        : g_playlist_titles[index];
    }
    // 副标题是「第 X 季 · 日期 · 时长」，季信息单独拎出来，免得只剩集号时
    // 观众不知道这是哪一季。
    const std::wstring season = index < g_playlist_seasons.size()
                                    ? g_playlist_seasons[index]
                                    : std::wstring();
    std::wstring detail;
    if (!season.empty()) detail = L"第 " + season + L" 季";
    if (index < g_playlist_meta.size() && !g_playlist_meta[index].empty()) {
      if (!detail.empty()) detail += L" · ";
      detail += g_playlist_meta[index];
    }
    if (detail.empty() && count == 1) detail.clear();
    PanelItem card = PanelEpisode(
        kGlyphEpisodes, label, detail,
        index < g_playlist_images.size() ? g_playlist_images[index]
                                         : std::wstring(),
        index < g_playlist_progress.size() ? g_playlist_progress[index] : -1.0,
        index < g_playlist_durations.size() ? g_playlist_durations[index] : 0.0,
        selected,
        index < g_playlist_watched.size() ? g_playlist_watched[index] : false);
    card.property = "playlist-pos";
    card.value = std::to_string(index);
    card.toast = "正在播放 " + Utf8(label);
    items.push_back(std::move(card));
  }
  if (count == 0) {
    items.push_back(PanelNote(kGlyphInfo, L"当前内容没有剧集列表"));
  }
  PanelMetrics metrics;
  metrics.width = kPanelEpisodeWidth;
  // 定位到正在播的那一集：以前 OpenPanel 一律把滚动位置归零，集数一多，
  // 打开面板永远停在第一集。
  metrics.reveal = reveal;
  OpenPanel(std::move(items), anchor, metrics);
}

// 「资源」列出的是当前剧集在全部已连接服务器上的所有资源版本：应用已经把
// 各服务器的版本聚合好下发，原生这边只负责展示与回选，自身不持有任何服务器信息。
//
// 图标和应用详情页的 ServerMark 是同一套：应用有自定义图标时把图取到本地缓存
// 只下发路径，原生画图；没有图标时按来源类型画兜底标记。
void ShowResourceMenu(PanelAnchor anchor) {
  const size_t count = g_resource_sources.size();
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(kGlyphServer, L"资源",
                              std::to_wstring(count) + L" 个"));
  for (size_t index = 0; index < count; ++index) {
    const std::wstring source = g_resource_sources[index];
    const std::wstring detail = index < g_resource_details.size()
                                    ? g_resource_details[index]
                                    : std::wstring();
    const std::wstring label =
        source.empty() ? L"资源 " + std::to_wstring(index + 1) : source;
    PanelItem row = PanelOption(
        kGlyphServer, label, detail, "mova-resource", std::to_string(index),
        "切换到 " + Utf8(label), static_cast<int>(index) == g_resource_current);
    if (index < g_resource_icons.size()) row.image = g_resource_icons[index];
    if (index < g_resource_marks.size()) row.mark = g_resource_marks[index];
    if (index < g_resource_ranks.size()) row.rank = g_resource_ranks[index];
    items.push_back(std::move(row));
  }
  if (count == 0) {
    items.push_back(PanelNote(kGlyphInfo, L"没有其它可切换的资源版本"));
  }
  PanelMetrics metrics;
  metrics.width = kPanelResourceWidth;
  OpenPanel(std::move(items), anchor, metrics);
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

// 换资源只能由应用重建播放：原生的播放列表、http headers 与 hwdec 选择都绑在
// 起播时那个服务器上，本地换个地址会静默播错甚至失败。所以这里只把用户选中的
// 下标回传（应用自己持有完整资源表），然后干净退出，让应用用新资源重新起播。
//
// 顺带带上当前播放位置：应用拿它当新资源的起播点，否则换一次资源就要从头看。
void EmitResourceChoice(int index) {
  const double position = std::atof(MpvString("time-pos").c_str());
  char text[96]{};
  const int length = std::snprintf(text, sizeof(text),
                                   "MOVA_RESOURCE=%d|%.3f\r\n", index, position);
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE && length > 0) {
    DWORD written = 0;
    WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
  }
}

// 控件条尺寸与贴边距离。抽成常量是因为弹窗锚点也要用：面板向上展开时贴的正是
// 控件条的顶边，两处分别硬编码迟早会对不上。
constexpr int kControlsHeight = 112;
constexpr int kControlsBottomMargin = 20;
constexpr int kTopBarHeight = 58;
constexpr int kTopBarTopMargin = 14;

void PositionControls() {
  if (!g_window || !g_controls) return;
  RECT client{};
  GetClientRect(g_window, &client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  const int client_width = static_cast<int>(client.right - client.left);
  const int available_width = std::max(240, client_width - 32);
  const int width = std::min(1040, available_width);
  const int height = kControlsHeight;
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
    const int top_height = kTopBarHeight;
    SetWindowPos(g_top_bar, HWND_TOP, origin.x + 16,
                 origin.y + kTopBarTopMargin, top_width, top_height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowRgn(g_top_bar, nullptr, TRUE);
    InvalidateRect(g_top_bar, nullptr, FALSE);
  }
  // The menu is a sibling popup: re-positioning the dock would otherwise push
  // it behind the transport bar even though it was opened last.
  if (g_panel && IsWindowVisible(g_panel)) {
    SetWindowPos(g_panel, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

// 控件条顶边的屏幕 y。底部工具的面板挂在它上方，而不是挂在被点击的像素上 ——
// 控件条本身有 112 px，贴着点的位置展开会让面板盖住同一排的其它按钮。
int DockTopScreen() {
  if (!g_window) return 0;
  RECT client{};
  GetClientRect(g_window, &client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  return origin.y + static_cast<int>(client.bottom) - kControlsHeight -
         kControlsBottomMargin;
}

// 控件条上某个控件的锚点：横向对准被点的那个按钮，纵向贴控件条顶边并向上展开。
//
// x 必须用控件条自己的窗口换算：控件条是居中的，比主窗口窄一圈（1280 宽的窗口里
// 它从 x=120 起），拿主窗口换算会把面板整体左移那半个内边距，鼠标点着 A 按钮、
// 面板却挂在 A 左边一段。
PanelAnchor DockAnchor(int client_x) {
  POINT point{client_x, 0};
  if (g_controls) ClientToScreen(g_controls, &point);
  PanelAnchor anchor;
  anchor.x = point.x;
  anchor.y = DockTopScreen();
  anchor.open_above = true;
  return anchor;
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

// Icons are filled as vector paths instead of being rasterized as text: font
// metrics made "same size" icons look unequal, ClearType tinted their edges,
// and the text path forced every caller to guess an em size.
//
// Sizing follows Flutter's Icon(size:): the glyph is scaled so its *em box*
// spans `size`, i.e. the artwork lands at the proportion the icon designer
// drew (0.55-0.93 of the em across the Iconsax set).  Normalising by measured
// ink instead looks reasonable until a glyph is not square - a chevron at 0.55
// would be blown up until it is as heavy as a filled square at 0.83, which is
// exactly the icon-weight drift this replaced.  So: same number the Dart side
// passes to Icon(), same result on screen.
//
// Note AddString() takes the *top-left of the em box*, not the baseline, so
// the em box needs no ascent/descent correction here: glyph ink comes back in
// [0, kGlyphDesignEm] and centring on the ink box keeps every icon on the same
// axis.  (Deriving a centre from GetCellAscent/Descent shifts the whole set by
// roughly a fifth of the icon size.)
constexpr float kGlyphDesignEm = 100.0f;

struct GlyphShape {
  Gdiplus::GraphicsPath path;
  Gdiplus::RectF bounds{};  // ink extent, in design-em units
};

// The cache is a function-local static, so its destructor only runs at exit -
// long after GdiplusShutdown has unloaded gdiplus.dll, at which point every
// GraphicsPath inside it would be a call into freed code and the process dies
// with 0xC0000005 on the way out.  ReleaseGlyphCache() empties it while GDI+ is
// still alive; the empty container is then safe for the CRT to tear down.
std::map<wchar_t, std::unique_ptr<GlyphShape>>& GlyphCache() {
  static std::map<wchar_t, std::unique_ptr<GlyphShape>> cache;
  return cache;
}

void ReleaseGlyphCache() { GlyphCache().clear(); }

const GlyphShape* GlyphShapeFor(wchar_t codepoint) {
  auto& cache = GlyphCache();
  const auto cached = cache.find(codepoint);
  if (cached != cache.end()) return cached->second.get();
  auto shape = std::make_unique<GlyphShape>();
  const Gdiplus::FontFamily* family =
      g_iconsax_font_family && g_iconsax_font_family->IsAvailable()
          ? g_iconsax_font_family.get()
          : Gdiplus::FontFamily::GenericSansSerif();
  const wchar_t glyph[] = {codepoint, L'\0'};
  GlyphShape* raw = nullptr;
  if (shape->path.AddString(glyph, 1, family, Gdiplus::FontStyleRegular,
                            kGlyphDesignEm, Gdiplus::PointF(0, 0), nullptr) ==
          Gdiplus::Ok &&
      shape->path.GetBounds(&shape->bounds) == Gdiplus::Ok &&
      shape->bounds.Width > 0.0f && shape->bounds.Height > 0.0f) {
    raw = shape.get();
  }
  // The shipped icon font is tree-shaken at build time, so it only carries the
  // icons the Dart side references - a codepoint that exists in the iconsax
  // package can still be absent here, and would leave an empty button behind.
  // Returns null for those; the codepoints in use are audited by the glyph
  // probe in the windows-native-render-qa skill.
  cache[codepoint] = std::move(shape);
  return raw;
}

// `size` is the Flutter Icon(size:) value, not an ink extent.
// `mirror_x` flips the glyph horizontally: the app's directional affordances
// reuse one glyph and mirror it rather than pulling in an unrelated icon
// (see YingjiDirectionalArrow), which also matters here because the shipped
// font only carries the icons the app already references.
void DrawGlyph(Gdiplus::Graphics& graphics, wchar_t codepoint, float center_x,
               float center_y, float size, Gdiplus::Color color,
               bool mirror_x = false) {
  if (size <= 0.0f) return;
  const GlyphShape* shape = GlyphShapeFor(codepoint);
  if (!shape) return;
  const float scale = size / kGlyphDesignEm;
  const float ink_center_x = shape->bounds.X + shape->bounds.Width / 2.0f;
  const float ink_center_y = shape->bounds.Y + shape->bounds.Height / 2.0f;
  Gdiplus::Matrix placement(
      mirror_x ? -scale : scale, 0.0f, 0.0f, scale,
      center_x + (mirror_x ? ink_center_x * scale : -ink_center_x * scale),
      center_y - ink_center_y * scale);
  Gdiplus::Matrix previous;
  graphics.GetTransform(&previous);
  graphics.MultiplyTransform(&placement);
  Gdiplus::SolidBrush brush(color);
  graphics.FillPath(&brush, &shape->path);
  graphics.SetTransform(&previous);
}

// `size` is the Flutter Icon(size:) value; see DrawGlyph.
void DrawIconsaxGlyph(Gdiplus::Graphics& graphics, wchar_t codepoint, float x,
                      float y, float size, Gdiplus::Color color,
                      bool mirror_x = false) {
  DrawGlyph(graphics, codepoint, x, y, size, color, mirror_x);
}

void DrawPlayIcon(Gdiplus::Graphics& graphics, float x, float y,
                  float play_amount, float emphasis) {
  const wchar_t glyph = play_amount > 0.5f ? L'\xEE64' : L'\xEE44';
  DrawIconsaxGlyph(graphics, glyph, x, y, 25.0f + emphasis,
                   Gdiplus::Color(255, 18, 18, 20));
}

void DrawSpeaker(Gdiplus::Graphics& graphics, float x, float y, bool muted,
                 float emphasis) {
  DrawIconsaxGlyph(graphics, muted ? L'\xF097' : L'\xF08F', x, y,
                   19.0f + emphasis, IconInk(emphasis));
}

// 上一集 / 下一集：字体里没有 Iconsax 的 next / previous（图标集在构建时被
// tree-shake 成 Dart 侧引用过的那些），所以沿用应用的做法——同一个箭头，
// 下一步用镜像，而不是硬塞一个语意不相干的图标。
void DrawSkipIcon(Gdiplus::Graphics& graphics, float x, float y, bool next,
                  float emphasis) {
  DrawIconsaxGlyph(graphics, L'\xE964', x, y, 22.0f + emphasis,
                   IconInk(emphasis), next);
}

void DrawSeekIcon(Gdiplus::Graphics& graphics, float x, float y, bool forward,
                  float emphasis) {
  DrawIconsaxGlyph(graphics, forward ? L'\xEC13' : L'\xE99F', x, y,
                   19.0f + emphasis, IconInk(emphasis));
}

// 工具栏与菜单用同一张图标表（见 ToolGlyph）：以前每个图标各写一个包装函数、
// 各自定一个字号，结果同一排图标大小不一。现在只剩这张表和一个绘制入口。
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

// A scrollbar is a tall, narrow pill.  FillPill is intentionally horizontal
// and assumes width >= height; using it for a 3px-wide vertical bar creates
// negative arc bounds and the large circular artifacts seen in the panel.
void FillVerticalPill(Gdiplus::Graphics& graphics, Gdiplus::Brush& brush,
                      float x, float y, float width, float height) {
  const float radius = width / 2.0f;
  graphics.FillRectangle(&brush,
                         Gdiplus::RectF(x, y + radius, width,
                                        std::max(0.0f, height - width)));
  graphics.FillEllipse(&brush,
                       Gdiplus::RectF(x, y, width, width));
  graphics.FillEllipse(&brush,
                       Gdiplus::RectF(x, y + height - width, width, width));
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
  kPlaybackSettings,
  kPlaylist,
  kDanmaku,
  kPicture,
  kSpeed,
  kChapters,
  kEpisodes,
  kSegments,
  kMore,
};

constexpr size_t kControlCount = static_cast<size_t>(kMore) + 1;

// 每个工具入口一个图标，取自和应用里同一套 Iconsax 线性图标：工具栏、溢出菜单
// 和设置页说同一种图形语言，不再出现「同一个功能两三个图标」的情况。
wchar_t ToolGlyph(ControlId control) {
  switch (control) {
    case kAudio:
      return kGlyphSpeaker;
    case kSubtitle:
      return kGlyphSubtitle;
    case kDanmaku:
      return L'\xED93';
    case kPicture:
      return L'\xF06E';
    case kSpeed:
      return L'\xEFAE';
    case kChapters:
      return L'\xE9EC';
    case kEpisodes:
      return kGlyphEpisodes;
    case kSegments:
      return L'\xEE3E';
    case kPlaylist:
      return L'\xEB14';
    case kMore:
      return L'\xEDDF';
    default:
      return 0;
  }
}

std::wstring ToolHint(ControlId control) {
  switch (control) {
    case kAudio:
      return L"音轨与音量";
    case kSubtitle:
      return L"字幕轨道";
    case kDanmaku:
      return L"弹幕开关";
    case kPicture:
      return L"画面比例与画质";
    case kSpeed:
      return L"播放速度";
    case kChapters:
      return L"章节跳转";
    case kEpisodes:
      return L"浏览全部剧集";
    case kSegments:
      return L"片头片尾";
    case kPlaylist:
      return L"切换资源版本";
    default:
      return L"更多设置";
  }
}
std::array<float, kControlCount> g_control_hover{};
std::vector<std::string> g_tool_order;
std::vector<std::string> g_tool_hidden;
bool g_custom_tool_order = false;

ControlId ToolControl(const std::string& tool) {
  if (tool == "声音") return kAudio;
  if (tool == "字幕") return kSubtitle;
  if (tool == "弹幕") return kDanmaku;
  if (tool == "画面") return kPicture;
  if (tool == "倍速") return kSpeed;
  if (tool == "章节") return kChapters;
  if (tool == "剧集") return kEpisodes;
  if (tool == "片头片尾") return kSegments;
  if (tool == "资源") return kPlaylist;
  return kNone;
}

bool IsToolHidden(const std::string& tool) {
  return std::find(g_tool_hidden.begin(), g_tool_hidden.end(), tool) !=
         g_tool_hidden.end();
}

std::vector<ControlId> ConfiguredTools() {
  std::vector<ControlId> visible;
  for (const auto& tool : g_tool_order) {
    if (IsToolHidden(tool)) continue;
    const ControlId control = ToolControl(tool);
    if (control == kNone) continue;
    if (std::find(visible.begin(), visible.end(), control) == visible.end()) {
      visible.push_back(control);
    }
  }
  return visible;
}

float ToolAreaStart(int width) {
  const float transport_right = width / 2.0f + (width < 780 ? 104.0f : 166.0f);
  return transport_right + 24.0f;
}

// 右侧留白只留 24 px：这里原本为控件条最右那个独立全屏按钮预留了 48 px，
// 该按钮已移除（全屏仍可用画面双击与快捷键触发）。
int ToolSlotCapacity(int width) {
  const bool compact = width < 780;
  const float reserved_for_volume = compact ? 0.0f : 120.0f;
  const float available = width - 24.0f - ToolAreaStart(width) -
                          reserved_for_volume;
  return std::max(0, static_cast<int>(std::floor(available / 40.0f)));
}

std::vector<ControlId> OverflowTools(int width) {
  const auto tools = ConfiguredTools();
  const int slots = ToolSlotCapacity(width);
  if (static_cast<int>(tools.size()) <= slots) return {};
  const int shown = std::max(0, slots - 1);
  return std::vector<ControlId>(tools.begin() + shown, tools.end());
}

std::vector<std::pair<ControlId, float>> ToolLayout(int width) {
  std::vector<std::pair<ControlId, float>> result;
  const auto tools = ConfiguredTools();
  const int slots = ToolSlotCapacity(width);
  if (slots <= 0 || tools.empty()) return result;
  const bool overflow = static_cast<int>(tools.size()) > slots;
  const int shown = overflow ? std::max(0, slots - 1)
                             : std::min(static_cast<int>(tools.size()), slots);
  const float start = ToolAreaStart(width) + (width < 780 ? 0.0f : 120.0f);
  for (int index = 0; index < shown; ++index) {
    result.push_back({tools[static_cast<size_t>(index)],
                      start + 20.0f + index * 40.0f});
  }
  if (overflow) {
    result.push_back({kMore, start + 20.0f + shown * 40.0f});
  }
  return result;
}

float HoverAmount(ControlId id);

float VolumeStart(int width) {
  return ToolAreaStart(width) + 46.0f;
}

void DrawToolIcon(Gdiplus::Graphics& graphics, ControlId control, float x,
                  float y) {
  const wchar_t glyph = ToolGlyph(control);
  if (glyph == 0) return;
  const float emphasis = HoverAmount(control);
  DrawIconsaxGlyph(graphics, glyph, x, y, 19.0f + emphasis,
                   IconInk(emphasis));
}

std::wstring ToolLabel(ControlId control) {
  switch (control) {
    case kAudio:
      return L"声音";
    case kSubtitle:
      return L"字幕";
    case kDanmaku:
      return L"弹幕";
    case kPicture:
      return L"画面";
    case kSpeed:
      return L"倍速";
    case kChapters:
      return L"章节";
    case kEpisodes:
      return L"剧集";
    case kSegments:
      return L"片头片尾";
    case kPlaylist:
      return L"资源";
    default:
      return L"更多";
  }
}

// 每个工具一个专属面板，一一对应，不再有「点 A 出来 B」的兜底分支：
// 兜底只可能是编程错误，指向倍速也比把四个功能混在一起强。
void OpenToolPanel(ControlId control, PanelAnchor anchor) {
  switch (control) {
    case kAudio:
      ShowTrackMenu(g_window, true, anchor);
      break;
    case kSubtitle:
      ShowTrackMenu(g_window, false, anchor);
      break;
    case kDanmaku:
      ShowDanmakuMenu(anchor);
      break;
    case kChapters:
      ShowChapterMenu(anchor);
      break;
    case kEpisodes:
      ShowEpisodeMenu(anchor);
      break;
    case kSegments:
      ShowSegmentMenu(anchor);
      break;
    case kPicture:
      ShowPictureMenu(anchor);
      break;
    case kSpeed:
      ShowSpeedMenu(anchor);
      break;
    case kPlaylist:
      ShowResourceMenu(anchor);
      break;
    default:
      ShowSpeedMenu(anchor);
      break;
  }
}

void ShowOverflowMenu(int width, PanelAnchor anchor) {
  std::vector<PanelItem> items;
  items.push_back(PanelHeader(L'\xEDDF', L"更多", std::wstring()));
  for (const auto control : OverflowTools(width)) {
    items.push_back(PanelOption(ToolGlyph(control), ToolLabel(control),
                                ToolHint(control), "mova-open-tool",
                                std::to_string(static_cast<int>(control)),
                                std::string(), false));
  }
  if (!items.empty()) OpenPanel(std::move(items), anchor, PanelMetrics{});
}

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
  for (const auto& item : ToolLayout(width)) {
    if (x >= item.second - 19 && x < item.second + 19) return item.first;
  }
  if (compact) return kNone;
  const float volume_start = VolumeStart(width);
  const float volume_end = volume_start + 58;
  if (x >= volume_start - 5 && x <= volume_end + 5) return kVolume;
  if (x >= volume_start - 45 && x < volume_start - 7) return kMute;
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

// ------------------------------------------------------------ 弹出菜单绘制

void AddRoundedRectPath(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& rect,
                        float radius) {
  const float limit = std::min(rect.Width, rect.Height) / 2.0f;
  const float diameter = std::max(0.0f, std::min(radius, limit)) * 2.0f;
  if (diameter <= 0.0f) {
    path.AddRectangle(rect);
    return;
  }
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270, 90);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter, diameter,
              diameter, 0, 90);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90, 90);
  path.CloseFigure();
}

// 应用下发的本地图片缓存。缩略图与服务器图标都走这里：同一个路径只解码一次，
// 失败过的路径记下来，免得每次重绘都去撞一次 IO。
std::unordered_map<std::wstring, std::unique_ptr<Gdiplus::Bitmap>>
    g_image_cache;
std::unordered_set<std::wstring> g_image_missing;

Gdiplus::Bitmap* CachedImage(const std::wstring& path) {
  if (path.empty()) return nullptr;
  const auto cached = g_image_cache.find(path);
  if (cached != g_image_cache.end()) return cached->second.get();
  if (g_image_missing.count(path) != 0) return nullptr;
  auto image = std::make_unique<Gdiplus::Bitmap>(path.c_str());
  if (image->GetLastStatus() != Gdiplus::Ok || image->GetWidth() == 0 ||
      image->GetHeight() == 0) {
    g_image_missing.insert(path);
    return nullptr;
  }
  Gdiplus::Bitmap* raw = image.get();
  g_image_cache.emplace(path, std::move(image));
  return raw;
}

// 把图片按「填满并居中裁切」画进矩形，等价于 BoxFit.cover —— 剧集剧照比例
// 五花八门，直接拉伸会把人物压扁。
void DrawCoverImage(Gdiplus::Graphics& graphics, Gdiplus::Bitmap* image,
                    const Gdiplus::RectF& box) {
  if (!image || image->GetLastStatus() != Gdiplus::Ok) return;
  const float source_width = static_cast<float>(image->GetWidth());
  const float source_height = static_cast<float>(image->GetHeight());
  if (source_width <= 0.0f || source_height <= 0.0f) return;
  const float scale =
      std::max(box.Width / source_width, box.Height / source_height);
  const float width = source_width * scale;
  const float height = source_height * scale;
  const Gdiplus::InterpolationMode previous = graphics.GetInterpolationMode();
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  graphics.DrawImage(image,
                     Gdiplus::RectF(box.X + (box.Width - width) / 2.0f,
                                    box.Y + (box.Height - height) / 2.0f,
                                    width, height),
                     0.0f, 0.0f, source_width, source_height,
                     Gdiplus::UnitPixel);
  graphics.SetInterpolationMode(previous);
}

// 应用详情页 ServerMark 的兜底标记：按来源类型给一组渐变色，中间一枚白色
// 旋转方块加播放三角（WebDAV 用云朵）。这里复刻一份，保证原生面板和详情页
// 说的是同一种图形语言。
void DrawServerMark(Gdiplus::Graphics& graphics, const Gdiplus::RectF& box,
                    int mark) {
  Gdiplus::Color first(255, 88, 213, 104);
  Gdiplus::Color second(255, 24, 133, 58);
  if (mark == 2) {
    first = Gdiplus::Color(255, 155, 93, 229);
    second = Gdiplus::Color(255, 49, 87, 200);
  } else if (mark == 3) {
    first = Gdiplus::Color(255, 75, 136, 199);
    second = Gdiplus::Color(255, 35, 69, 107);
  }
  Gdiplus::GraphicsPath path;
  AddRoundedRectPath(path, box, box.Width * 0.29f);
  Gdiplus::LinearGradientBrush brush(Gdiplus::PointF(box.X, box.Y),
                                     Gdiplus::PointF(box.GetRight(),
                                                     box.GetBottom()),
                                     first, second);
  graphics.FillPath(&brush, &path);

  const float center_x = box.X + box.Width / 2.0f;
  const float center_y = box.Y + box.Height / 2.0f;
  Gdiplus::SolidBrush white(Gdiplus::Color(BYTE{242}, 255, 255, 255));
  if (mark == 3) {
    // 云朵：三团圆加一条底座，36px 下够用，也比塞一个字形稳。
    const float radius = box.Width * 0.125f;
    graphics.FillEllipse(&white,
                         Gdiplus::RectF(center_x - radius * 2.5f,
                                        center_y - radius * 0.4f, radius * 2.0f,
                                        radius * 2.0f));
    graphics.FillEllipse(&white,
                         Gdiplus::RectF(center_x - radius * 1.2f,
                                        center_y - radius * 1.6f, radius * 2.6f,
                                        radius * 2.6f));
    graphics.FillEllipse(&white,
                         Gdiplus::RectF(center_x + radius * 0.5f,
                                        center_y - radius * 0.5f, radius * 2.0f,
                                        radius * 2.0f));
    // GDI+ 的 Brush 不可拷贝，这里按同一个颜色另建一支。
    Gdiplus::SolidBrush cloud(Gdiplus::Color(BYTE{242}, 255, 255, 255));
    graphics.FillRectangle(&cloud,
                           Gdiplus::RectF(center_x - radius * 2.1f,
                                          center_y + radius * 0.1f,
                                          radius * 4.6f, radius * 1.5f));
    return;
  }
  const float side = box.Width * 0.44f;
  const Gdiplus::GraphicsState state = graphics.Save();
  graphics.TranslateTransform(center_x, center_y);
  graphics.RotateTransform(45.0f);
  Gdiplus::GraphicsPath square;
  AddRoundedRectPath(square,
                     Gdiplus::RectF(-side / 2.0f, -side / 2.0f, side, side),
                     box.Width * 0.08f);
  graphics.FillPath(&white, &square);
  graphics.Restore(state);
  Gdiplus::PointF triangle[3] = {
      Gdiplus::PointF(center_x - side * 0.14f, center_y - side * 0.22f),
      Gdiplus::PointF(center_x - side * 0.14f, center_y + side * 0.22f),
      Gdiplus::PointF(center_x + side * 0.24f, center_y)};
  Gdiplus::SolidBrush ink(second);
  graphics.FillPolygon(&ink, triangle, 3);
}

// 弹窗里的一套字与色，和应用内的玻璃弹窗是同一支字体、同一组灰阶。
//
// 注意字重：随包的 AlimamaFangYuanTi-Player.ttf 是单字重的静态字体（600），
// GDI+ 无法像 Skia 那样取可变字体的粗体实例，请求 FontStyleBold 只会拿回同一
// 个字面。所以层级靠字号 + 颜色拉，而不是靠字重。
struct PanelSkin {
  Gdiplus::Font header = MakeInterfaceFont(15, Gdiplus::FontStyleRegular);
  Gdiplus::Font title = MakeInterfaceFont(13, Gdiplus::FontStyleRegular);
  Gdiplus::Font detail = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
  Gdiplus::Font chip = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
  Gdiplus::Font note = MakeInterfaceFont(12, Gdiplus::FontStyleRegular);
  Gdiplus::SolidBrush ink{Gdiplus::Color(248, 247, 247, 250)};
  Gdiplus::SolidBrush muted{Gdiplus::Color(255, 185, 187, 195)};
  Gdiplus::SolidBrush quiet{Gdiplus::Color(255, 140, 143, 153)};
  Gdiplus::SolidBrush icon{Gdiplus::Color(236, 236, 238, 245)};
  Gdiplus::SolidBrush icon_bright{Gdiplus::Color(255, 255, 255, 255)};
};

float MeasurePanelText(Gdiplus::Graphics& graphics, const wchar_t* text,
                       const Gdiplus::Font& font) {
  Gdiplus::StringFormat format;
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  Gdiplus::RectF box;
  graphics.MeasureString(text, -1, &font, Gdiplus::PointF(0, 0), &format, &box);
  return box.Width;
}


void DrawPanelOptionRow(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                        const PanelItem& item, const Gdiplus::RectF& row,
                        bool hovered) {
  Gdiplus::GraphicsPath card;
  AddRoundedRectPath(card,
                     Gdiplus::RectF(row.X + 0.5f, row.Y + 0.5f, row.Width - 1.0f,
                                    row.Height - 1.0f),
                     12.0f);
  const BYTE fill_alpha =
      item.selected ? BYTE{42} : (hovered ? BYTE{30} : BYTE{16});
  Gdiplus::SolidBrush card_fill(Gdiplus::Color(fill_alpha, 255, 255, 255));
  graphics.FillPath(&card_fill, &card);
  const BYTE edge_alpha = item.selected ? BYTE{230}
                                        : (hovered ? BYTE{54} : BYTE{28});
  const Gdiplus::Color edge_color(edge_alpha, 255, 255, 255);
  Gdiplus::Pen card_edge(edge_color, item.selected ? 2.0f : 1.0f);
  graphics.DrawPath(&card_edge, &card);

  // 前置图标容器与应用弹窗 _TrackPickerOption 逐项对齐：36px 圆角方块、圆角 12、
  // 内部 Icon(size: 17)，左边距 12、与文字间距 11。
  const float tile = 36.0f;
  const Gdiplus::RectF tile_rect(row.X + 12.0f,
                                 row.Y + (row.Height - tile) / 2.0f, tile, tile);
  Gdiplus::GraphicsPath tile_path;
  AddRoundedRectPath(tile_path, tile_rect, 12.0f);
  // 带图标的行（服务器图标）画成实图，其余仍是图标容器 + 字形。前三名再描一圈
  // 金 / 银 / 铜，和应用播放页资源列表的排名标记是同一套含义。
  Gdiplus::Bitmap* mark_image = CachedImage(item.image);
  if (mark_image) {
    const Gdiplus::GraphicsState state = graphics.Save();
    // 必须是 Intersect：Replace 会把外层的内容视口裁切整个换掉，滚动时图会
    // 画进视口外的 padding 区（Restore 只恢复状态，救不回已画的像素）。
    graphics.SetClip(&tile_path, Gdiplus::CombineModeIntersect);
    DrawCoverImage(graphics, mark_image, tile_rect);
    graphics.Restore(state);
  } else if (item.mark != 0) {
    DrawServerMark(graphics, tile_rect, item.mark);
  } else {
    const BYTE tile_alpha = item.selected ? BYTE{41} : BYTE{16};
    Gdiplus::SolidBrush tile_fill(Gdiplus::Color(tile_alpha, 255, 255, 255));
    graphics.FillPath(&tile_fill, &tile_path);
    if (item.icon != 0) {
      DrawGlyph(graphics, item.icon, tile_rect.X + tile / 2.0f,
                tile_rect.Y + tile / 2.0f, 17.0f,
                item.selected ? Gdiplus::Color(255, 255, 255, 255)
                              : Gdiplus::Color(236, 236, 238, 245));
    }
  }
  if (item.rank >= 1 && item.rank <= 3) {
    const Gdiplus::Color ring = item.rank == 1
                                    ? Gdiplus::Color(255, 255, 215, 106)
                                    : item.rank == 2
                                          ? Gdiplus::Color(255, 220, 229, 238)
                                          : Gdiplus::Color(255, 217, 154, 104);
    Gdiplus::GraphicsPath ring_path;
    AddRoundedRectPath(ring_path,
                       Gdiplus::RectF(tile_rect.X + 0.75f,
                                      tile_rect.Y + 0.75f, tile - 1.5f,
                                      tile - 1.5f),
                       11.5f);
    Gdiplus::Pen ring_pen(ring, 1.5f);
    graphics.DrawPath(&ring_pen, &ring_path);
  }

  const float text_left = tile_rect.GetRight() + 11.0f;
  const float trailing_x = row.GetRight() - 21.0f;
  const float text_right = trailing_x - 17.0f;
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);

  float title_right = text_right;
  if (!item.badge.empty()) {
    const float badge_width =
        MeasurePanelText(graphics, item.badge.c_str(), skin.chip);
    const float badge_left = std::max(text_left, text_right - badge_width);
    graphics.DrawString(item.badge.c_str(), -1, &skin.chip,
                        Gdiplus::RectF(badge_left, row.Y + 18.0f,
                                       text_right - badge_left, 20.0f),
                        &format, &skin.quiet);
    title_right = badge_left - 8.0f;
  }
  const bool single_line = item.detail.empty();
  graphics.DrawString(item.label.c_str(), -1, &skin.title,
                      Gdiplus::RectF(text_left, single_line ? row.Y + 19.0f
                                                            : row.Y + 10.0f,
                                     std::max(0.0f, title_right - text_left),
                                     18.0f),
                      &format, item.enabled ? &skin.ink : &skin.quiet);
  if (!single_line) {
    graphics.DrawString(item.detail.c_str(), -1, &skin.detail,
                        Gdiplus::RectF(text_left, row.Y + 28.0f,
                                       std::max(0.0f, text_right - text_left),
                                       16.0f),
                        &format, &skin.muted);
  }

  // 末尾状态：选中的勾、可展开的箭头、其余的圆形单选圈。
  const bool opens_panel = item.property == "mova-open-tool";
  const wchar_t state = item.selected ? kGlyphCheckCircle
                                      : (opens_panel ? kGlyphChevronRight
                                                     : kGlyphRadio);
  const BYTE state_alpha = opens_panel ? BYTE{190} : BYTE{120};
  const Gdiplus::Color state_ink =
      item.selected ? Gdiplus::Color(255, 255, 255, 255)
                    : Gdiplus::Color(state_alpha, 255, 255, 255);
  DrawGlyph(graphics, state, trailing_x, row.Y + row.Height / 2.0f, 19.0f,
            state_ink);
}

void DrawPanelHeaderRow(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                        const PanelItem& item, const Gdiplus::RectF& row) {
  const float center_y = row.Y + row.Height / 2.0f;
  if (item.icon != 0) {
    DrawGlyph(graphics, item.icon, row.X + 14.0f, center_y, 20.0f,
              Gdiplus::Color(BYTE{255}, 226, 228, 236));
  }
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  graphics.DrawString(item.label.c_str(), -1, &skin.header,
                      Gdiplus::RectF(row.X + 30.0f, row.Y,
                                     std::max(0.0f, row.Width - 90.0f),
                                     row.Height),
                      &format, &skin.ink);
  if (item.badge.empty()) return;
  const float text_width = MeasurePanelText(graphics, item.badge.c_str(), skin.chip);
  const float chip_width = text_width + 18.0f;
  const float chip_height = 20.0f;
  const Gdiplus::RectF chip(row.GetRight() - chip_width,
                            center_y - chip_height / 2.0f, chip_width,
                            chip_height);
  Gdiplus::GraphicsPath chip_path;
  AddRoundedRectPath(chip_path, chip, chip_height / 2.0f);
  const Gdiplus::Color chip_color(BYTE{24}, 255, 255, 255);
  Gdiplus::SolidBrush chip_fill(chip_color);
  graphics.FillPath(&chip_fill, &chip_path);
  Gdiplus::StringFormat centered;
  centered.SetAlignment(Gdiplus::StringAlignmentCenter);
  centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  graphics.DrawString(item.badge.c_str(), -1, &skin.chip, chip, &centered,
                      &skin.quiet);
}

void DrawPanelNoteRow(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                      const PanelItem& item, const Gdiplus::RectF& row) {
  const float center_y = row.Y + row.Height / 2.0f;
  if (item.icon != 0) {
    DrawGlyph(graphics, item.icon, row.X + 14.0f, center_y, 18.0f,
              Gdiplus::Color(BYTE{255}, 148, 151, 161));
  }
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  graphics.DrawString(item.label.c_str(), -1, &skin.note,
                      Gdiplus::RectF(row.X + 30.0f, row.Y,
                                     std::max(0.0f, row.Width - 40.0f),
                                     row.Height),
                      &format, &skin.muted);
}

// 剧集行：一行一集。缩略图在左（16:9），缩略图底部叠观看进度与时间；右侧
// 两行文字是「第 X 集 · 集名」与「第 X 季 · 日期 · 时长」。正在播的那一集
// 在缩略图右上角打勾，整行描白边。
void DrawPanelEpisodeCard(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                          const PanelItem& item, const Gdiplus::RectF& box,
                          bool hovered) {
  Gdiplus::GraphicsPath card;
  AddRoundedRectPath(card,
                     Gdiplus::RectF(box.X + 0.5f, box.Y + 0.5f, box.Width - 1.0f,
                                    box.Height - 1.0f),
                     12.0f);
  const BYTE fill_alpha =
      item.selected ? BYTE{40} : (hovered ? BYTE{30} : BYTE{14});
  Gdiplus::SolidBrush card_fill(Gdiplus::Color(fill_alpha, 255, 255, 255));
  graphics.FillPath(&card_fill, &card);
  const BYTE edge_alpha = item.selected ? BYTE{228}
                                        : (hovered ? BYTE{54} : BYTE{26});
  Gdiplus::Pen card_edge(Gdiplus::Color(edge_alpha, 255, 255, 255),
                         item.selected ? 2.0f : 1.0f);
  graphics.DrawPath(&card_edge, &card);

  const Gdiplus::RectF thumb(box.X + kEpisodeRowInset,
                             box.Y + kEpisodeRowInset, kEpisodeRowThumbWidth,
                             kEpisodeRowThumbHeight);
  Gdiplus::GraphicsPath thumb_path;
  AddRoundedRectPath(thumb_path, thumb, 9.0f);
  Gdiplus::SolidBrush placeholder(Gdiplus::Color(BYTE{30}, 255, 255, 255));
  graphics.FillPath(&placeholder, &thumb_path);
  Gdiplus::Bitmap* image = CachedImage(item.image);
  if (image) {
    const Gdiplus::GraphicsState state = graphics.Save();
    // Intersect：Replace 会把外层视口裁切整个换掉，滚动定位后缩略图会画出
    // 视口顶部（Restore 只恢复状态，救不回已画的像素）。
    graphics.SetClip(&thumb_path, Gdiplus::CombineModeIntersect);
    DrawCoverImage(graphics, image, thumb);
    graphics.Restore(state);
  } else {
    DrawGlyph(graphics, kGlyphEpisodes, thumb.X + thumb.Width / 2.0f,
              thumb.Y + thumb.Height / 2.0f, 26.0f,
              Gdiplus::Color(BYTE{86}, 255, 255, 255));
  }

  // 缩略图底部的进度条与时间。已播完的集整块不画（对勾已经说明状态）；
  // 没看过的集只画时长，避免出现一条空进度槽和没有意义的 00:00:00。
  const bool has_progress = !item.watched && item.progress > 0.0;
  if (has_progress || (!item.watched && item.duration > 0.0)) {
    const Gdiplus::GraphicsState state = graphics.Save();
    // 同上：进度段与视口裁切取交集，防止滚出视口的内容画出面板。
    graphics.SetClip(&thumb_path, Gdiplus::CombineModeIntersect);
    Gdiplus::LinearGradientBrush shade(
        Gdiplus::PointF(0.0f, thumb.GetBottom() - 30.0f),
        Gdiplus::PointF(0.0f, thumb.GetBottom()),
        Gdiplus::Color(BYTE{0}, 0, 0, 0), Gdiplus::Color(BYTE{186}, 0, 0, 0));
    graphics.FillRectangle(&shade, thumb.X, thumb.GetBottom() - 30.0f,
                           thumb.Width, 30.0f);
    const float bar_left = thumb.X + 9.0f;
    const float bar_width = thumb.Width - 18.0f;
    const float bar_y = thumb.GetBottom() - 13.0f;
    Gdiplus::Pen track(Gdiplus::Color(BYTE{110}, 255, 255, 255), 2.6f);
    ConfigureControlPen(track);
    graphics.DrawLine(&track, bar_left, bar_y, bar_left + bar_width, bar_y);
    const float fraction =
        static_cast<float>(std::clamp(item.progress, 0.0, 1.0));
    if (has_progress && fraction > 0.0f) {
      Gdiplus::Pen value(Gdiplus::Color(255, 110, 168, 255), 2.6f);
      ConfigureControlPen(value);
      graphics.DrawLine(&value, bar_left, bar_y,
                        bar_left + bar_width * fraction, bar_y);
    }
    // 左「已看」右「全长」，和播放页剧集卡上的写法一致；没看过的集不画
    // 左侧，免得出现一串 00:00:00。
    const double played = has_progress && item.duration > 0.0
                              ? item.progress * item.duration
                              : 0.0;
    const std::wstring left =
        has_progress ? ClockLabel(played) : std::wstring();
    const std::wstring right =
        item.duration > 0.0 ? ClockLabel(item.duration) : std::wstring();
    Gdiplus::StringFormat format;
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
    auto stamp = MakeInterfaceFont(9, Gdiplus::FontStyleRegular);
    Gdiplus::SolidBrush stamp_ink(Gdiplus::Color(255, 245, 245, 248));
    if (!left.empty()) {
      graphics.DrawString(left.c_str(), -1, &stamp,
                          Gdiplus::RectF(bar_left, bar_y - 18.0f, bar_width / 2,
                                         13.0f),
                          &format, &stamp_ink);
    }
    if (!right.empty()) {
      // StringFormat 也不可拷贝，右对齐另建一个。
      Gdiplus::StringFormat trailing;
      trailing.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      trailing.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
      trailing.SetAlignment(Gdiplus::StringAlignmentFar);
      graphics.DrawString(right.c_str(), -1, &stamp,
                          Gdiplus::RectF(bar_left + bar_width / 2, bar_y - 18.0f,
                                         bar_width / 2, 13.0f),
                          &trailing, &stamp_ink);
    }
    graphics.Restore(state);
  }

  // 已播完的集：右上角一枚对勾。不垫底色圆 —— 一枚深色阴影勾 + 白勾叠出
  // 轮廓，亮封面和暗封面上都认得出来，也不会像之前那样顶着一个黑圆。
  if (item.watched) {
    const float badge = 20.0f;
    const float cx = thumb.GetRight() - 6.0f - badge / 2.0f;
    const float cy = thumb.Y + 6.0f + badge / 2.0f;
    DrawGlyph(graphics, kGlyphCheckCircle, cx + 0.9f, cy + 0.9f, 15.0f,
              Gdiplus::Color(BYTE{150}, 0, 0, 0));
    DrawGlyph(graphics, kGlyphCheckCircle, cx, cy, 15.0f,
              Gdiplus::Color(255, 255, 255, 255));
  }

  const float text_left = thumb.GetRight() + 12.0f;
  const float text_width =
      std::max(0.0f, box.GetRight() - kEpisodeRowInset - 4.0f - text_left);
  Gdiplus::StringFormat format;
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  graphics.DrawString(item.label.c_str(), -1, &skin.title,
                      Gdiplus::RectF(text_left, box.Y + 24.0f, text_width,
                                     18.0f),
                      &format, item.selected ? &skin.icon_bright : &skin.ink);
  if (!item.detail.empty()) {
    graphics.DrawString(item.detail.c_str(), -1, &skin.detail,
                        Gdiplus::RectF(text_left, box.Y + 48.0f, text_width,
                                       15.0f),
                        &format, &skin.muted);
  }
}

void DrawPanelScrollBar(Gdiplus::Graphics& graphics, float body_width,
                        float body_height) {
  if (PanelMaxScroll() <= 0) return;
  const float track_top = static_cast<float>(kPanelShadowMargin) + 12.0f;
  const float track_height = std::max(28.0f, body_height - 24.0f);
  const float thumb_height =
      std::max(36.0f, track_height * body_height /
                          static_cast<float>(std::max(1, PanelContentHeight())));
  const float travel = std::max(0.0f, track_height - thumb_height);
  const float fraction = static_cast<float>(g_panel_scroll) /
                         static_cast<float>(std::max(1, PanelMaxScroll()));
  const float x = static_cast<float>(kPanelShadowMargin) + body_width - 9.0f;
  Gdiplus::SolidBrush track(Gdiplus::Color(BYTE{26}, 255, 255, 255));
  Gdiplus::SolidBrush thumb(Gdiplus::Color(BYTE{96}, 255, 255, 255));
  FillVerticalPill(graphics, track, x, track_top, 4.0f, track_height);
  FillVerticalPill(graphics, thumb, x, track_top + travel * fraction, 4.0f,
                   thumb_height);
}

// 面板走逐像素透明：先画到 32bpp 的 PARGB 位图，再整块交给
// UpdateLayeredWindow。这样圆角有真正的抗锯齿、外阴影能渐隐；改用窗口区域裁剪
// 的话，GDI 会把圆角硬切成阶梯，投影也无处可画。
struct PanelSurface {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous = nullptr;
  Gdiplus::Bitmap* target = nullptr;

  ~PanelSurface() { Destroy(); }

  bool Create(int width, int height) {
    if (width <= 0 || height <= 0) return false;
    dc = CreateCompatibleDC(nullptr);
    if (!dc) return false;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!bitmap || !bits) return false;
    previous = SelectObject(dc, bitmap);
    memset(bits, 0, static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
    target = new Gdiplus::Bitmap(width, height, width * 4,
                                 PixelFormat32bppPARGB,
                                 static_cast<BYTE*>(bits));
    return target->GetLastStatus() == Gdiplus::Ok;
  }

  void Destroy() {
    delete target;
    target = nullptr;
    if (dc && previous) SelectObject(dc, previous);
    previous = nullptr;
    if (bitmap) DeleteObject(bitmap);
    bitmap = nullptr;
    if (dc) DeleteDC(dc);
    dc = nullptr;
  }
};

void PaintPanelContent(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                       float width, float height) {
  const float body_width = width - kPanelShadowMargin * 2.0f;
  const float body_height = height - kPanelShadowMargin * 2.0f;
  const Gdiplus::RectF body_rect(static_cast<float>(kPanelShadowMargin),
                                 static_cast<float>(kPanelShadowMargin),
                                 body_width, body_height);
  // 阴影：由外向内叠一圈圈圆角矩形，越靠近面板越深，得到柔和的下投影。
  constexpr int kShadowSteps = 14;
  for (int step = kShadowSteps; step >= 1; --step) {
    const float spread = static_cast<float>(step) * 1.7f;
    Gdiplus::GraphicsPath ring;
    AddRoundedRectPath(ring,
                       Gdiplus::RectF(body_rect.X - spread,
                                      body_rect.Y - spread + 3.0f,
                                      body_width + spread * 2.0f,
                                      body_height + spread * 2.0f),
                       16.0f + spread);
    const BYTE shadow_alpha = step == kShadowSteps ? BYTE{3} : BYTE{9};
    Gdiplus::SolidBrush shadow(Gdiplus::Color(shadow_alpha, 0, 0, 0));
    graphics.FillPath(&shadow, &ring);
  }

  Gdiplus::GraphicsPath body;
  AddRoundedRectPath(body, body_rect, 16.0f);
  Gdiplus::LinearGradientBrush surface(
      Gdiplus::Point(0, kPanelShadowMargin),
      Gdiplus::Point(0, kPanelShadowMargin + static_cast<int>(body_height)),
      Gdiplus::Color(BYTE{247}, 43, 47, 57),
      Gdiplus::Color(BYTE{247}, 22, 24, 30));
  graphics.FillPath(&surface, &body);
  Gdiplus::Pen edge(Gdiplus::Color(BYTE{kSurfaceEdgeAlpha}, 255, 255, 255),
                    1.0f);
  graphics.DrawPath(&edge, &body);

  // 行内容裁到「内容视口」而不是整个面板体：body 的上下 padding 区留给面板
  // 底色。以前裁到 body_rect，滚动定位后上方行的下半截（缩略图、时间戳）会悬
  // 在面板顶部 padding 区，卡片圆角和面板圆角错位、再往上是透明阴影区，看起来
  // 就像内容画出了面板。收紧后在视口边界干净切断，和任何滚动列表一致。
  const Gdiplus::RectF content_rect(
      body_rect.X + kPanelPadding, body_rect.Y + kPanelPadding,
      body_width - kPanelPadding * 2.0f, body_height - kPanelPadding * 2.0f);
  graphics.SetClip(content_rect);
  for (size_t index = 0; index < g_panel_items.size(); ++index) {
    if (index >= g_panel_boxes.size()) break;
    const PanelItem& item = g_panel_items[index];
    const PanelBox& box = g_panel_boxes[index];
    const float top = static_cast<float>(kPanelShadowMargin) + box.y -
                      static_cast<float>(g_panel_scroll);
    if (top + box.h < 0.0f || top > height) continue;
    const Gdiplus::RectF row(static_cast<float>(kPanelShadowMargin) + box.x, top,
                             box.w, box.h);
    const bool hovered =
        g_panel_hover == static_cast<int>(index) && item.enabled;
    if (item.row == PanelRow::Header) {
      DrawPanelHeaderRow(graphics, skin, item, row);
    } else if (item.row == PanelRow::Note) {
      DrawPanelNoteRow(graphics, skin, item, row);
    } else if (item.row == PanelRow::Episode) {
      DrawPanelEpisodeCard(graphics, skin, item, row, hovered);
    } else {
      DrawPanelOptionRow(graphics, skin, item, row, hovered);
    }
  }
  graphics.ResetClip();
  DrawPanelScrollBar(graphics, body_width, body_height);
}

void PresentPanel(HWND window, int width, int height) {
  PanelSurface surface;
  if (!surface.Create(width, height)) return;
  {
    const PanelSkin skin;
    Gdiplus::Graphics graphics(surface.target);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
    PaintPanelContent(graphics, skin, static_cast<float>(width),
                      static_cast<float>(height));
    graphics.Flush(Gdiplus::FlushIntentionSync);
  }
  POINT source{0, 0};
  SIZE size{width, height};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(window, nullptr, nullptr, &size, surface.dc, &source, 0,
                      &blend, ULW_ALPHA);
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
      PresentPanel(window, rect.right, rect.bottom);
      EndPaint(window, &paint);
      (void)dc;
      return 0;
    }
    case WM_MOUSEMOVE: {
      const int next =
          PanelIndexAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (g_panel_hover != next) {
        g_panel_hover = next;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const int index =
          PanelIndexAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (index < 0) {
        // 点到了投影或空白处：当作关闭菜单，而不是把点击吞掉。
        ShowWindow(window, SW_HIDE);
        SetFocus(g_window);
        ShowControls();
        return 0;
      }
      if (index < static_cast<int>(g_panel_items.size())) {
        const auto item = g_panel_items[index];
        if (item.enabled && item.property == "mova-open-tool") {
          const auto control =
              static_cast<ControlId>(std::atoi(item.value.c_str()));
          // 沿用当前面板的锚点在原位换一个面板。以前是从面板角落再算一次锚点，
          // 「更多」的二级面板就会叠到一级面板上。
          OpenToolPanel(control, g_panel_anchor);
        } else if (item.enabled && item.property == "mova-resource") {
          // 换资源必须由应用重建播放，这里只回传选择然后干净退出。
          EmitResourceChoice(std::atoi(item.value.c_str()));
          ShowWindow(window, SW_HIDE);
          SendMessageW(g_window, WM_CLOSE, 0, 0);
        } else if (item.enabled && !item.property.empty()) {
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
        ScrollPanel(-static_cast<int>(kPanelOptionHeight));
        return 0;
      }
      if (wparam == VK_DOWN) {
        ScrollPanel(static_cast<int>(kPanelOptionHeight));
        return 0;
      }
      if (wparam == VK_PRIOR) {
        ScrollPanel(-g_panel_viewport_height);
        return 0;
      }
      if (wparam == VK_NEXT) {
        ScrollPanel(g_panel_viewport_height);
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

void OpenPanel(std::vector<PanelItem> items, PanelAnchor anchor,
               PanelMetrics metrics) {
  if (!g_panel) return;
  g_panel_items = std::move(items);
  g_panel_metrics = metrics;
  LayoutPanelRows();
  // 记住锚点：从「更多」里再打开子面板时沿用同一位置，避免嵌套面板层层错位。
  g_panel_anchor = anchor;
  g_panel_hover = -1;
  g_panel_scroll = 0;
  const int panel_width = g_panel_metrics.width;
  const int content = std::min(g_panel_metrics.max_height, PanelContentHeight());
  g_panel_viewport_height = content - kPanelPadding * 2;
  // 打开时把指定的行滚进视野：剧集面板要定位到正在播的那一集，而不是永远从
  // 第一集开始。把当前集顶到内容区第一行，一打开视线就落在它上面；越靠近
  // 列表末尾时由 clamp 兜底，不会滚过头。
  if (g_panel_metrics.reveal >= 0 &&
      g_panel_metrics.reveal < static_cast<int>(g_panel_boxes.size())) {
    const PanelBox& box =
        g_panel_boxes[static_cast<size_t>(g_panel_metrics.reveal)];
    const float target = box.y - static_cast<float>(kPanelPadding);
    g_panel_scroll = std::clamp(static_cast<int>(target), 0, PanelMaxScroll());
  }
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int left_limit = static_cast<int>(work_area.left) + 8;
  const int right_limit = std::max(
      left_limit, static_cast<int>(work_area.right) - panel_width - 8);
  const int body_x =
      std::clamp(anchor.x - panel_width / 2, left_limit, right_limit);
  const int top_limit = static_cast<int>(work_area.top) + 8;
  const int bottom_limit =
      std::max(top_limit, static_cast<int>(work_area.bottom) - content - 8);
  // 贴边方向由调用方给出：底部控件条向上展开，顶栏向下展开。两端各夹一次，
  // 保证面板完整落在工作区内。
  int body_y = anchor.open_above ? anchor.y - content - 8 : anchor.y + 8;
  body_y = std::min(std::max(body_y, top_limit), bottom_limit);
  SetWindowPos(g_panel, HWND_TOP, body_x - kPanelShadowMargin,
               body_y - kPanelShadowMargin,
               panel_width + kPanelShadowMargin * 2,
               content + kPanelShadowMargin * 2,
               SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
  InvalidateRect(g_panel, nullptr, FALSE);
  SetForegroundWindow(g_panel);
  SetFocus(g_panel);
  HideHint();
}

// ------------------------------------------------------------ 提示浮层
//
// 两种形态共用一个分层小窗：
//   * Tooltip —— 鼠标停在某个控件上时，在控件正上方显示它的名字；
//   * Toast   —— 调整音量 / 亮度 / 倍速 / 快进退时给一行实时反馈。
//
// 以前这些「实时提示」全部是转调 mpv 自己的 show-text，弹出来的是 mpv 的字体、
// mpv 的位置、mpv 的样式，和 Mova 的玻璃面板是两套语言。改成自绘之后，提示与
// 面板、控件条用同一支字体、同一组灰阶、同一圈内描边。

constexpr wchar_t kHintClass[] = L"MovaNativePlayerHint";
constexpr int kHintMaxTextWidth = 420;
constexpr int kHintRadius = 12;
constexpr ULONGLONG kToastHoldMilliseconds = 1500;

HWND g_hint = nullptr;
HintMode g_hint_mode = HintMode::Hidden;
std::wstring g_hint_text;
std::wstring g_hint_detail;
wchar_t g_hint_icon = 0;
float g_hint_fraction = -1.0f;
ULONGLONG g_hint_until = 0;
// 拖动音量条 / 进度条时，只在整数百分比变化时重建浮层，否则每个鼠标事件都会
// 重新排版一次。
int g_hint_seek_percent = -1;
int g_hint_volume_percent = -1;

Gdiplus::Font MakeHintFont(HintMode mode) {
  return MakeInterfaceFont(mode == HintMode::Tooltip ? 12.0f : 13.0f,
                           Gdiplus::FontStyleRegular);
}

void MeasureHint(const std::wstring& text, const std::wstring& detail,
                 wchar_t icon, bool progress, int* width, int* height) {
  HDC dc = CreateCompatibleDC(nullptr);
  int text_width = 0;
  {
    Gdiplus::Graphics graphics(dc);
    auto font = MakeHintFont(HintMode::Toast);
    auto detail_font = MakeInterfaceFont(11.0f, Gdiplus::FontStyleRegular);
    const float measured = std::max(
        MeasurePanelText(graphics, text.c_str(), font),
        detail.empty() ? 0.0f
                       : MeasurePanelText(graphics, detail.c_str(), detail_font));
    text_width = static_cast<int>(
        std::min(static_cast<float>(kHintMaxTextWidth), measured));
  }
  DeleteDC(dc);
  const int content_height = detail.empty() ? 18 : 32;
  *width = text_width + 28 + (icon != 0 ? 22 : 0);
  *height = 20 + content_height + (progress ? 12 : 0);
  if (*width < 88) *width = 88;
}

void PaintHint(Gdiplus::Graphics& graphics, int width, int height, int icon,
               const std::wstring& text, const std::wstring& detail,
               float fraction) {
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
  const Gdiplus::RectF body(0.5f, 0.5f, static_cast<float>(width) - 1.0f,
                            static_cast<float>(height) - 1.0f);
  Gdiplus::GraphicsPath path;
  AddRoundedRectPath(path, body, static_cast<float>(kHintRadius));
  Gdiplus::LinearGradientBrush surface(
      Gdiplus::PointF(0.0f, 0.0f), Gdiplus::PointF(0.0f, static_cast<float>(height)),
      Gdiplus::Color(BYTE{247}, 43, 47, 57),
      Gdiplus::Color(BYTE{247}, 22, 24, 30));
  graphics.FillPath(&surface, &path);
  Gdiplus::Pen edge(Gdiplus::Color(BYTE{kSurfaceEdgeAlpha}, 255, 255, 255), 1.0f);
  graphics.DrawPath(&edge, &path);

  const PanelSkin skin;
  float text_left = 14.0f;
  if (icon != 0) {
    DrawGlyph(graphics, static_cast<wchar_t>(icon), 24.0f, height / 2.0f, 16.0f,
              Gdiplus::Color(BYTE{240}, 236, 238, 245));
    text_left = 36.0f;
  }
  const float text_width =
      std::max(0.0f, static_cast<float>(width) - text_left - 14.0f);
  Gdiplus::StringFormat format;
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  if (detail.empty()) {
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    graphics.DrawString(text.c_str(), -1, &skin.title,
                        Gdiplus::RectF(text_left, 10.0f, text_width, 18.0f),
                        &format, &skin.ink);
  } else {
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    graphics.DrawString(text.c_str(), -1, &skin.title,
                        Gdiplus::RectF(text_left, 8.0f, text_width, 18.0f),
                        &format, &skin.ink);
    graphics.DrawString(detail.c_str(), -1, &skin.detail,
                        Gdiplus::RectF(text_left, 25.0f, text_width, 15.0f),
                        &format, &skin.muted);
  }
  if (fraction < 0.0f) return;
  const float bar_left = text_left;
  const float bar_width = std::max(40.0f, text_width);
  const float bar_y = static_cast<float>(height) - 13.0f;
  Gdiplus::Pen track(Gdiplus::Color(BYTE{110}, 255, 255, 255), 3.0f);
  ConfigureControlPen(track);
  graphics.DrawLine(&track, bar_left, bar_y, bar_left + bar_width, bar_y);
  Gdiplus::Pen value(Gdiplus::Color(255, 110, 168, 255), 3.0f);
  ConfigureControlPen(value);
  graphics.DrawLine(&value, bar_left, bar_y,
                    bar_left + bar_width * std::clamp(fraction, 0.0f, 1.0f),
                    bar_y);
}

void HideHint() {
  g_hint_mode = HintMode::Hidden;
  g_hint_fraction = -1.0f;
  if (g_hint) ShowWindow(g_hint, SW_HIDE);
}

void ShowHint(const std::wstring& text, const std::wstring& detail,
              wchar_t icon, HintMode mode, float fraction, int anchor_x) {
  if (!g_hint || text.empty() || mode == HintMode::Hidden) {
    HideHint();
    return;
  }
  int width = 0;
  int height = 0;
  MeasureHint(text, detail, icon, fraction >= 0.0f, &width, &height);
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int work_left = static_cast<int>(work_area.left) + 8;
  const int work_right = static_cast<int>(work_area.right) - 8;
  const int dock_top = DockTopScreen();
  int x = mode == HintMode::Tooltip
              ? anchor_x - width / 2
              : work_left + (work_right - work_left - width) / 2;
  x = std::clamp(x, work_left, std::max(work_left, work_right - width));
  const int gap = mode == HintMode::Tooltip ? 10 : 16;
  int y = dock_top - height - gap;
  y = std::max(y, static_cast<int>(work_area.top) + 8);
  g_hint_mode = mode;
  g_hint_text = text;
  g_hint_detail = detail;
  g_hint_icon = icon;
  g_hint_fraction = fraction;
  g_hint_until = GetTickCount64() + kToastHoldMilliseconds;
  SetWindowPos(g_hint, HWND_TOP, x, y, width, height,
               SWP_SHOWWINDOW | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  InvalidateRect(g_hint, nullptr, FALSE);
}

void ShowTooltip(const std::wstring& text, int anchor_x) {
  ShowHint(text, std::wstring(), 0, HintMode::Tooltip, -1.0f, anchor_x);
}

LRESULT CALLBACK HintProc(HWND window, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      PanelSurface surface;
      if (surface.Create(rect.right, rect.bottom)) {
        Gdiplus::Graphics graphics(surface.target);
        PaintHint(graphics, rect.right, rect.bottom, g_hint_icon, g_hint_text,
                  g_hint_detail, g_hint_fraction);
        graphics.Flush(Gdiplus::FlushIntentionSync);
        POINT source{0, 0};
        SIZE size{rect.right, rect.bottom};
        BLENDFUNCTION blend{};
        blend.BlendOp = AC_SRC_OVER;
        blend.SourceConstantAlpha = 255;
        blend.AlphaFormat = AC_SRC_ALPHA;
        UpdateLayeredWindow(window, nullptr, nullptr, &size, surface.dc,
                            &source, 0, &blend, ULW_ALPHA);
      }
      EndPaint(window, &paint);
      return 0;
    }
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

// 控件悬浮时显示的名字。工具按钮走 ToolLabel，播放控制另外给一套说法。
std::wstring ControlTooltip(int control) {
  switch (static_cast<ControlId>(control)) {
    case kPlayPause:
      return g_paused.load() ? L"播放" : L"暂停";
    case kBackTen:
      return L"后退 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒";
    case kForwardTen:
      return L"前进 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒";
    case kPreviousEpisode:
      return L"上一集";
    case kNextEpisode:
      return L"下一集";
    case kMute:
      return g_muted.load() ? L"取消静音" : L"静音";
    case kVolume:
      return L"音量";
    default:
      break;
  }
  const ControlId id = static_cast<ControlId>(control);
  if (id == kAudio || id == kSubtitle || id == kDanmaku || id == kPicture ||
      id == kSpeed || id == kChapters || id == kEpisodes || id == kSegments ||
      id == kPlaylist || id == kMore) {
    return ToolLabel(id);
  }
  return std::wstring();
}

// 控件在控件条客户区里的中心 x。悬浮提示要贴在它正上方，所以命中范围和绘制
// 位置必须来自同一套布局函数，不能再抄一份坐标。
float ControlCenterX(ControlId control, int width) {
  const float center = width / 2.0f;
  switch (control) {
    case kPreviousEpisode:
      return center - 140.0f;
    case kBackTen:
      return center - 76.0f;
    case kPlayPause:
      return center;
    case kForwardTen:
      return center + 76.0f;
    case kNextEpisode:
      return center + 140.0f;
    case kMute:
      return VolumeStart(width) - 28.0f;
    case kVolume:
      return VolumeStart(width) + 29.0f;
    default:
      break;
  }
  for (const auto& item : ToolLayout(width)) {
    if (item.first == control) return item.second;
  }
  return -1.0f;
}

// 调整类操作的统一说法：一行标题 + 一行明细 +（可选）一条进度。音量与亮度这
// 类有量纲的调整，进度条让「现在是多亮、多响」一眼可见。
void ShowAdjustHint(const std::wstring& title, const std::wstring& detail,
                    wchar_t icon, float fraction) {
  ShowHint(title, detail, icon, HintMode::Toast, fraction, 0);
}

void ShowVolumeHint(double volume) {
  const int percent = static_cast<int>(std::round(std::clamp(volume, 0.0, 100.0)));
  ShowAdjustHint(g_muted.load() ? L"静音中" : L"音量",
                 std::to_wstring(percent) + L"%", kGlyphSpeaker,
                 static_cast<float>(percent) / 100.0f);
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

// Only the value is rendered: the chip draws the wifi glyph, so repeating the
// word "网络" inside a 12px pill was what forced the label onto three lines.
std::wstring NetworkSpeedLabel() {
  const double bytes_per_second = g_network_bytes_per_second.load();
  if (bytes_per_second < 1.0) {
    return g_buffering.load() ? L"读取中" : L"—";
  }
  wchar_t text[48]{};
  if (bytes_per_second >= 1024.0 * 1024.0) {
    swprintf_s(text, L"%.1f MB/s", bytes_per_second / (1024.0 * 1024.0));
  } else {
    swprintf_s(text, L"%.0f KB/s", bytes_per_second / 1024.0);
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
        graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
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
        // 网络状态做成和应用里同一枚胶囊：wifi 图标 + 数值，宽度跟着内容走，
        // 这样既不会再折行，也和播放页顶部的 _StateChip 是同一个形态。
        const std::wstring network = NetworkSpeedLabel();
        Gdiplus::StringFormat chip_measure;
        chip_measure.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
        Gdiplus::RectF network_box;
        graphics.MeasureString(network.c_str(), -1, &network_font,
                               Gdiplus::PointF(0, 0), &chip_measure,
                               &network_box);
        const float chip_icon = 15.0f;
        const float chip_height = 26.0f;
        const float chip_padding = 11.0f;
        const float chip_gap = 6.0f;
        const float chip_width = chip_padding * 2.0f + chip_icon + chip_gap +
                                 network_box.Width + 2.0f;
        const Gdiplus::RectF chip(
            static_cast<float>(rect.right) - 156.0f - chip_width,
            (rect.bottom - chip_height) / 2.0f, chip_width, chip_height);
        Gdiplus::GraphicsPath chip_path;
        AddRoundedRectPath(chip_path, chip, chip_height / 2.0f);
        Gdiplus::SolidBrush chip_fill(Gdiplus::Color(BYTE{196}, 26, 29, 36));
        graphics.FillPath(&chip_fill, &chip_path);
        Gdiplus::Pen chip_edge(Gdiplus::Color(BYTE{58}, 255, 255, 255), 1.0f);
        graphics.DrawPath(&chip_edge, &chip_path);
        DrawGlyph(graphics, L'\xF0C3', chip.X + chip_padding + chip_icon / 2.0f,
                  chip.Y + chip_height / 2.0f, chip_icon,
                  g_buffering.load() ? Gdiplus::Color(BYTE{200}, 255, 255, 255)
                                     : Gdiplus::Color(BYTE{235}, 255, 255, 255));
        Gdiplus::SolidBrush network_brush(Gdiplus::Color(BYTE{226}, 236, 238, 245));
        Gdiplus::StringFormat chip_format;
        chip_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        chip_format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
        chip_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
        graphics.DrawString(
            network.c_str(), -1, &network_font,
            Gdiplus::RectF(chip.X + chip_padding + chip_icon + chip_gap, chip.Y,
                           network_box.Width + 4.0f, chip_height),
            &chip_format, &network_brush);
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
          // 和应用标题栏 YingjiMotionIconButton 同一条规则：图标字号 = 直径 × 0.43。
          constexpr float kWindowIcon = 36.0f * 0.43f;
          if (button == 1) {
            DrawGlyph(graphics, L'\xEDAD', x, 29.0f, kWindowIcon,
                      Gdiplus::Color(BYTE{238}, 244, 244, 247));
          } else if (button == 2) {
            const bool zoomed = IsZoomed(g_window) != 0;
            DrawGlyph(graphics, zoomed ? L'\xE9F6' : L'\xED57', x, 29.0f, kWindowIcon,
                      Gdiplus::Color(BYTE{238}, 244, 244, 247));
          } else {
            DrawGlyph(graphics, L'\xEAB2', x, 29.0f, kWindowIcon,
                      Gdiplus::Color(BYTE{238}, 244, 244, 247));
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
      graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
      Gdiplus::LinearGradientBrush surface(
          Gdiplus::Point(0, 0), Gdiplus::Point(0, rect.bottom),
          Gdiplus::Color(224, 39, 41, 48), Gdiplus::Color(244, 14, 15, 19));
      graphics.FillRectangle(&surface, 0, 0, rect.right, rect.bottom);
      Gdiplus::Pen surface_edge(
          Gdiplus::Color(BYTE{kSurfaceEdgeAlpha}, 255, 255, 255), 1.0f);
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
      const auto tool_layout = ToolLayout(static_cast<int>(width));
      if (!compact) {
        const float volume_start = VolumeStart(static_cast<int>(width));
        const float volume_end = volume_start + 58.0f;
        DrawHover(graphics, kMute, volume_start - 28, controls_y, 36);
        DrawSpeaker(graphics, volume_start - 28, controls_y, g_muted.load(),
                    HoverAmount(kMute));
        Gdiplus::Pen volume_track(Gdiplus::Color(120, 174, 176, 184), 3);
        volume_track.SetStartCap(Gdiplus::LineCapRound);
        volume_track.SetEndCap(Gdiplus::LineCapRound);
        graphics.DrawLine(&volume_track, volume_start, controls_y,
                          volume_end, controls_y);
        const float volume_fraction = static_cast<float>(
            std::clamp(g_volume.load() / 100.0, 0.0, 1.0));
        Gdiplus::Pen volume_value(Gdiplus::Color(255, 245, 245, 247), 3);
        volume_value.SetStartCap(Gdiplus::LineCapRound);
        volume_value.SetEndCap(Gdiplus::LineCapRound);
        graphics.DrawLine(&volume_value, volume_start, controls_y,
                          volume_start + 58.0f * volume_fraction,
                          controls_y);
        graphics.FillEllipse(
            &white,
            Gdiplus::RectF(volume_start - 3 + 58 * volume_fraction,
                           controls_y - 3, 6, 6));
      }
      for (const auto& tool : tool_layout) {
        DrawHover(graphics, tool.first, tool.second, controls_y, 34);
        DrawToolIcon(graphics, tool.first, tool.second, controls_y);
      }
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
      const ControlId hit = HitControl(x, y, rect.right);
      if (y <= 34 && g_duration.load() > 0) {
        const double fraction = std::max(
            0.0, std::min(1.0, (x - 24.0) / (rect.right - 48.0)));
        const std::string target = std::to_string(fraction * 100.0);
        MpvCommand("seek", target.c_str(), "absolute-percent");
        ShowAdjustHint(L"跳到 " + ClockLabel(fraction * g_duration.load()),
                       std::wstring(), kGlyphGauge,
                       static_cast<float>(fraction));
        g_hint_seek_percent = static_cast<int>(fraction * 100.0);
      } else if (hit == kAudio || hit == kSubtitle || hit == kDanmaku ||
                 hit == kPicture || hit == kSpeed || hit == kChapters ||
                 hit == kEpisodes || hit == kSegments || hit == kPlaylist) {
        OpenToolPanel(hit, DockAnchor(x));
      } else if (hit == kMore) {
        ShowOverflowMenu(rect.right, DockAnchor(x));
      } else if (x >= center - 28 && x <= center + 28) {
        MpvCommand("cycle", "pause");
      } else if (!compact && x >= center - 166 && x < center - 116) {
        MpvCommand("playlist-prev", "weak");
        ShowToast("上一集");
      } else if (x >= center - 104 && x < center - 48) {
        MpvCommand("seek", std::to_string(-g_seek_seconds).c_str(), "relative");
        ShowAdjustHint(
            L"后退 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒",
            ClockLabel(std::max(0.0, g_position.load() - g_seek_seconds)),
            kGlyphGauge, -1.0f);
      } else if (x > center + 48 && x <= center + 104) {
        MpvCommand("seek", std::to_string(g_seek_seconds).c_str(), "relative");
        ShowAdjustHint(
            L"前进 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒",
            ClockLabel(std::min(g_duration.load(),
                                g_position.load() + g_seek_seconds)),
            kGlyphGauge, -1.0f);
      } else if (!compact && x > center + 116 && x <= center + 166) {
        MpvCommand("playlist-next", "weak");
        ShowToast("下一集");
      } else {
        switch (hit) {
          case kMute: {
            MpvCommand("cycle", "mute");
            ShowAdjustHint(g_muted.load() ? L"取消静音" : L"已静音",
                           std::wstring(), kGlyphSpeaker, -1.0f);
            break;
          }
          case kVolume: {
            const double volume = std::clamp(
                (x - VolumeStart(rect.right)) / 58.0 * 100.0, 0.0, 100.0);
            const std::string value = std::to_string(volume);
            MpvCommand("set", "volume", value.c_str());
            ShowVolumeHint(volume);
            g_hint_volume_percent = static_cast<int>(volume);
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
      // 滚轮改音量同样给实时反馈：音量条本身在下面，眼睛盯着画面时看不见。
      ShowVolumeHint(std::clamp(g_volume.load() +
                                    (GET_WHEEL_DELTA_WPARAM(wparam) > 0
                                         ? g_volume_step
                                         : -g_volume_step),
                                0.0, 100.0));
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
          const int percent = static_cast<int>(fraction * 100.0);
          // 拖动时只在整数百分比变化时重画提示，否则每一像素都会重建一次浮层。
          if (percent != g_hint_seek_percent) {
            g_hint_seek_percent = percent;
            ShowAdjustHint(L"跳到 " + ClockLabel(fraction * g_duration.load()),
                           std::wstring(), kGlyphGauge,
                           static_cast<float>(fraction));
          }
        } else {
          g_hint_seek_percent = -1;
        }
      } else {
        g_seek_hover = -1;
        g_hint_seek_percent = -1;
      }
      if ((wparam & MK_LBUTTON) != 0 &&
          HitControl(mouse_x, mouse_y, rect.right) == kVolume) {
        const double volume = std::clamp(
            (mouse_x - VolumeStart(rect.right)) / 58.0 * 100.0, 0.0, 100.0);
        const std::string value = std::to_string(volume);
        MpvCommand("set", "volume", value.c_str());
        const int percent = static_cast<int>(volume);
        if (percent != g_hint_volume_percent) {
          g_hint_volume_percent = percent;
          ShowVolumeHint(volume);
        }
      } else if ((wparam & MK_LBUTTON) == 0) {
        g_hint_volume_percent = -1;
      }
      const int hovered = HitControl(mouse_x, mouse_y, rect.right);
      if (g_hover_control.exchange(hovered) != hovered) {
        InvalidateRect(window, nullptr, FALSE);
        // 悬浮名称：工具按钮与播放控制都给出自己的名字，悬浮在高亮动效之外
        // 再给一次文字确认。
        const std::wstring label =
            hovered == kNone ? std::wstring() : ControlTooltip(hovered);
        const float anchor = ControlCenterX(static_cast<ControlId>(hovered),
                                            rect.right);
        if (!label.empty() && anchor >= 0.0f) {
          POINT point{static_cast<LONG>(anchor), 0};
          ClientToScreen(window, &point);
          ShowTooltip(label, point.x);
        } else if (g_hint_mode == HintMode::Tooltip) {
          HideHint();
        }
      }
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    }
    case WM_MOUSELEAVE:
      g_seek_hover = -1;
      g_hint_seek_percent = -1;
      g_hint_volume_percent = -1;
      if (g_hint_mode == HintMode::Tooltip) HideHint();
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
    ShowAdjustHint(g_paused.load() ? L"继续播放" : L"已暂停", std::wstring(),
                   0, -1.0f);
  } else if (action == "seekBack") {
    MpvCommand("seek", std::to_string(-g_seek_seconds).c_str(), "relative");
    ShowAdjustHint(
        L"后退 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒",
        ClockLabel(std::max(0.0, g_position.load() - g_seek_seconds)),
        kGlyphGauge, -1.0f);
  } else if (action == "seekForward") {
    MpvCommand("seek", std::to_string(g_seek_seconds).c_str(), "relative");
    ShowAdjustHint(
        L"前进 " + std::to_wstring(static_cast<int>(g_seek_seconds)) + L" 秒",
        ClockLabel(std::min(g_duration.load(),
                            g_position.load() + g_seek_seconds)),
        kGlyphGauge, -1.0f);
  } else if (action == "volumeUp") {
    MpvCommand("add", "volume", std::to_string(g_volume_step).c_str());
    ShowVolumeHint(std::clamp(g_volume.load() + g_volume_step, 0.0, 100.0));
  } else if (action == "volumeDown") {
    MpvCommand("add", "volume", std::to_string(-g_volume_step).c_str());
    ShowVolumeHint(std::clamp(g_volume.load() - g_volume_step, 0.0, 100.0));
  } else if (action == "mute") {
    MpvCommand("cycle", "mute");
    ShowAdjustHint(g_muted.load() ? L"取消静音" : L"已静音", std::wstring(),
                   kGlyphSpeaker, -1.0f);
  } else if (action == "fullscreen") {
    ToggleFullscreen();
    ShowAdjustHint(g_fullscreen ? L"进入全屏" : L"退出全屏", L"再次按 F 可切换",
                   0, -1.0f);
  } else if (action == "exit") {
    // ESC 分层退出：全屏先回窗口，最大化先还原，最后一步才是关掉播放器。
    // 全屏 / 最大化下想直接退出的是误触，先把窗口形态退回去。
    if (g_fullscreen) {
      ToggleFullscreen();
      ShowAdjustHint(L"退出全屏", L"再按一次退出播放器", 0, -1.0f);
    } else if (IsZoomed(g_window)) {
      ShowWindow(g_window, SW_RESTORE);
      ShowAdjustHint(L"已还原窗口", L"再按一次退出播放器", 0, -1.0f);
    } else {
      SendMessageW(g_window, WM_CLOSE, 0, 0);
    }
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
      // 提示浮层跟着控件条一起进退：控件条淡出时提示留着会更奇怪。
      if (g_hint_mode != HintMode::Hidden) {
        const bool expired = g_hint_mode == HintMode::Toast &&
                             GetTickCount64() > g_hint_until;
        if (expired || g_controls_alpha == 0) HideHint();
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
  WNDCLASSW hint_class{};
  hint_class.hInstance = instance;
  hint_class.lpszClassName = kHintClass;
  hint_class.lpfnWndProc = HintProc;
  RegisterClassW(&hint_class);

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
    const std::filesystem::path iconsax_path =
        std::filesystem::path(executable_path).parent_path() / L"data" /
        L"flutter_assets" / L"packages" / L"iconsax_flutter" / L"fonts" /
        L"FlutterIconsax.ttf";
    g_iconsax_font_collection =
        std::make_unique<Gdiplus::PrivateFontCollection>();
    if (g_iconsax_font_collection->AddFontFile(iconsax_path.c_str()) ==
        Gdiplus::Ok) {
      Gdiplus::FontFamily families[1];
      int family_count = 0;
      if (g_iconsax_font_collection->GetFamilies(1, families, &family_count) ==
              Gdiplus::Ok &&
          family_count > 0) {
        wchar_t family_name[LF_FACESIZE]{};
        if (families[0].GetFamilyName(family_name) == Gdiplus::Ok) {
          auto family = std::make_unique<Gdiplus::FontFamily>(
              family_name, g_iconsax_font_collection.get());
          if (family->IsAvailable()) g_iconsax_font_family = std::move(family);
        }
      }
    }
  }

  // 播放器每次打开都摆在屏幕正中：此前用的是 CW_USEDEFAULT，位置交给系统的
  // 层叠规则，多屏或覆盖过窗口位置时会跑偏。
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int work_width = static_cast<int>(work_area.right - work_area.left);
  const int work_height = static_cast<int>(work_area.bottom - work_area.top);
  const int window_width = std::min(1280, work_width);
  const int window_height = std::min(760, work_height);
  const int window_x = static_cast<int>(work_area.left) +
                       (work_width - window_width) / 2;
  const int window_y = static_cast<int>(work_area.top) +
                       (work_height - window_height) / 2;
  HWND window = CreateWindowExW(
      0, kWindowClass, L"Mova",
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
          WS_CLIPCHILDREN,
      window_x, window_y, window_width, window_height, nullptr, nullptr, instance,
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
  // 提示浮层要能压在画面上、又绝不能抢鼠标：无激活、透明命中、工具窗口。
  g_hint = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT |
                               WS_EX_NOACTIVATE,
                           kHintClass, L"", WS_POPUP, 0, 0, 1, 1, window,
                           nullptr, instance, nullptr);
  g_panel = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kPanelClass, L"",
                            WS_POPUP, 0, 0, 1, 1, window, nullptr, instance,
                            nullptr);
  // The panel does not use SetLayeredWindowAttributes: it hands a premultiplied
  // bitmap to UpdateLayeredWindow instead, which is what gives it anti-aliased
  // rounded corners and a soft shadow.  Calling the attribute API here would
  // switch the window back to the whole-window alpha path.

  g_handle = g_mpv.create();
  if (!g_handle) return 4;

  // mpv expects the full pointer-sized HWND value.  Truncating it to 32 bits
  // on a 64-bit build leaves gpu-next without a valid render target and causes
  // the file to end with a generic playback error.
  SetOption(g_handle, "wid",
            std::to_string(reinterpret_cast<intptr_t>(window)));
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
  // 顺序即控件条上的显示顺序：前面几个直接摆在控件条上，放不下的进「更多」。
  // 剧集排在字幕之后，是因为控件条只有四个工具槽（三个直接入口 + 更多），而
  // 「弹幕」在原生窗口里只给一句说明、并不渲染，优先级低于能直接换集的剧集。
  g_tool_order = {"声音", "字幕", "剧集", "弹幕", "画面", "倍速",
                  "章节", "片头片尾", "资源"};
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
        } else if (name == "mova-playlist-season") {
          g_playlist_seasons.push_back(argument.substr(equals + 1));
        } else if (name == "mova-playlist-episode") {
          g_playlist_episodes.push_back(argument.substr(equals + 1));
        } else if (name == "mova-playlist-episode-title") {
          g_playlist_episode_titles.push_back(argument.substr(equals + 1));
        } else if (name == "mova-playlist-image") {
          g_playlist_images.push_back(argument.substr(equals + 1));
        } else if (name == "mova-playlist-meta") {
          g_playlist_meta.push_back(argument.substr(equals + 1));
        } else if (name == "mova-playlist-progress") {
          const std::wstring value = argument.substr(equals + 1);
          g_playlist_progress.push_back(
              value.empty() ? -1.0
                            : std::strtod(Utf8(value).c_str(), nullptr));
        } else if (name == "mova-playlist-duration") {
          const std::wstring value = argument.substr(equals + 1);
          g_playlist_durations.push_back(
              value.empty() ? 0.0
                            : std::strtod(Utf8(value).c_str(), nullptr));
        } else if (name == "mova-playlist-watched") {
          g_playlist_watched.push_back(argument.substr(equals + 1) == L"1");
        } else if (name == "mova-resource-source") {
          g_resource_sources.push_back(argument.substr(equals + 1));
        } else if (name == "mova-resource-detail") {
          g_resource_details.push_back(argument.substr(equals + 1));
        } else if (name == "mova-resource-icon") {
          g_resource_icons.push_back(argument.substr(equals + 1));
        } else if (name == "mova-resource-mark") {
          g_resource_marks.push_back(
              std::atoi(Utf8(argument.substr(equals + 1)).c_str()));
        } else if (name == "mova-resource-rank") {
          g_resource_ranks.push_back(
              std::atoi(Utf8(argument.substr(equals + 1)).c_str()));
        } else if (name == "mova-resource-current") {
          g_resource_current =
              std::atoi(Utf8(argument.substr(equals + 1)).c_str());
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
        } else if (name == "mova-tool-order") {
          if (!g_custom_tool_order) {
            g_tool_order.clear();
            g_custom_tool_order = true;
          }
          g_tool_order.push_back(Utf8(argument.substr(equals + 1)));
        } else if (name == "mova-tool-hidden") {
          g_tool_hidden.push_back(Utf8(argument.substr(equals + 1)));
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
  // 并行下发的数组都补齐到同一长度，免得面板里按下标取数据时越界。
  while (g_playlist_seasons.size() < media_urls.size()) {
    g_playlist_seasons.emplace_back();
  }
  while (g_playlist_episodes.size() < media_urls.size()) {
    g_playlist_episodes.emplace_back();
  }
  while (g_playlist_episode_titles.size() < media_urls.size()) {
    g_playlist_episode_titles.emplace_back();
  }
  while (g_playlist_images.size() < media_urls.size()) {
    g_playlist_images.emplace_back();
  }
  while (g_playlist_meta.size() < media_urls.size()) {
    g_playlist_meta.emplace_back();
  }
  while (g_playlist_progress.size() < media_urls.size()) {
    g_playlist_progress.push_back(-1.0);
  }
  while (g_playlist_durations.size() < media_urls.size()) {
    g_playlist_durations.push_back(0.0);
  }
  while (g_playlist_watched.size() < media_urls.size()) {
    g_playlist_watched.push_back(false);
  }
  while (g_resource_icons.size() < g_resource_sources.size()) {
    g_resource_icons.emplace_back();
  }
  while (g_resource_marks.size() < g_resource_sources.size()) {
    g_resource_marks.push_back(0);
  }
  while (g_resource_ranks.size() < g_resource_sources.size()) {
    g_resource_ranks.push_back(0);
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
  g_mpv.observe_property(g_handle, 9, "brightness", MPV_FORMAT_DOUBLE);
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
          } else if (property->name &&
                     std::string(property->name) == "brightness") {
            g_brightness = value;
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
  // GdiplusShutdown 会卸载 gdiplus.dll；这些全局 GDI+ 对象必须在它之前释放，
  // 否则进程退出时它们的析构函数会调用已失效的 Gdip* 并触发访问冲突（0xC0000005）。
  ReleaseGlyphCache();
  // 图片缓存里的 Gdiplus::Bitmap 同样是 GDI+ 对象，必须在 GdiplusShutdown 之前
  // 释放，否则进程退出时会走到已卸载的 Gdip* 上。
  g_image_cache.clear();
  g_image_missing.clear();
  g_series_logo.reset();
  g_iconsax_font_family.reset();
  g_iconsax_font_collection.reset();
  g_interface_font_family.reset();
  g_interface_font_collection.reset();
  if (g_gdiplus_token) {
    Gdiplus::GdiplusShutdown(g_gdiplus_token);
    g_gdiplus_token = 0;
  }
  return 0;
}
