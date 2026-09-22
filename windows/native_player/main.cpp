#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <gdiplus.h>
// timeBeginPeriod / timeEndPeriod：把系统时钟粒度提到 1ms，帧定时器才准。
#pragma comment(lib, "winmm.lib")
// AlphaBlend：弹幕文字栅格化后每帧只做一次带 alpha 的贴图（见 BlendDanmakuTexture）。
#pragma comment(lib, "msimg32.lib")

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
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <fstream>
#include <chrono>

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
// 弹幕在播放过程中才拉到，stdin 线程收到后投递这条消息，由主线程建窗/重载。
constexpr UINT kDanmakuReload = WM_APP + 3;
// keep-open=yes 关掉了 mpv 的自动前进：播完（EOF）时由事件线程投递这条消息，
// 主线程再执行 playlist-next。这样「读取出错」就不会被当成播完而跳集。
constexpr UINT kPlaylistAdvance = WM_APP + 4;
// 同上，出错时停在原地并给一次可见提示（原来的错误分支只改内部标志，
// 界面上什么都不显示，用户只看到画面卡住然后跳到下一集）。
constexpr UINT kPlaybackInterrupted = WM_APP + 5;
// 播放期间应用侧改了设置页里的弹幕 / 片头片尾项：stdin 线程入队后投递这条
// 消息，主线程逐个应用（见 ApplyLiveOption），不必等下一次起播。
constexpr UINT kApplyLiveSettings = WM_APP + 6;
// 判断「是不是真播完了」的容差：正常播完时 time-pos 和 duration 会差一点点，
// 给几秒余量；差得更多的 EOF 就是中途断流被误报成播完。
constexpr double kEofGraceSeconds = 3.0;
constexpr wchar_t kControlsClass[] = L"MovaNativePlayerControls";
constexpr wchar_t kPanelClass[] = L"MovaNativePlayerPanel";
constexpr wchar_t kTopBarClass[] = L"MovaNativePlayerTopBar";
constexpr COLORREF kOverlayColorKey = RGB(1, 2, 3);
constexpr wchar_t kInterfaceFont[] = L"Alimama FangYuanTi VF";

MpvApi g_mpv;
mpv_handle* g_handle = nullptr;
std::atomic<bool> g_running{true};
std::atomic<double> g_position{0};
// g_position 最后一次被 mpv 回报的时刻（高精度 QPC 毫秒）。弹幕的出现时机与位置
// 都按「插值后的播放位置」算，不再受属性上报粒度限制（见 DanmakuPlayhead）。
//
// 这里**不能**用 GetTickCount64：它的粒度是系统时钟节拍（默认 15.6ms），插值出来
// 的位置就会一步 15.6ms 地跳，而波动的是「一条弹幕在屏上被画到哪一列」。
std::atomic<double> g_position_tick{0.0};
std::atomic<double> g_duration{0};
// 最后一次有效的播放位置。end-file 时 mpv 可能已经把 time-pos 清成 0/NaN，
// 那时再读 g_position 判断「有没有播到片尾」就不准了，所以单独留一份。
std::atomic<double> g_last_valid_position{0};
std::atomic<bool> g_paused{false};
std::atomic<double> g_volume{100};
std::atomic<double> g_speed{1};
std::atomic<bool> g_muted{false};
// 画面亮度（mpv 的 video equalizer，-100..100）。面板里用时读、由属性观察回填。
std::atomic<double> g_brightness{0};
std::atomic<bool> g_buffering{false};
std::atomic<bool> g_playback_error{false};
// 中断自动重试：源站在「跳转 / 换段」的那一刻要新建连接，偶发抖动会让 mpv 把
// 这一集判成结束（ERROR，或者一个离片尾很远的 EOF）。以前这里直接举手投降，
// 用户看到的是「播放失败 · 请更换资源」，而同一集的地址往往下一秒就能播。
// 所以同一集内先补一次：位置记在 g_resume_seconds 里，等新文件加载完再 seek
// 回去。重试预算按「这一集已经稳稳放了十几秒」就复位，免得一次抖动就把整集的
// 重试机会用光。
std::atomic<double> g_resume_seconds{0};
// 重试成功、位置已经补回去：由事件线程置位，主线程在下一帧把「正在重试…」
// 换成一句「已继续播放」，免得重试成功之后那句提示还挂在那里自相矛盾。
std::atomic<bool> g_resume_done{false};
int g_retry_count = 0;          // 只在主线程读写
uint64_t g_retry_stamp = 0;     // 上次重试的时刻（用来判「已经健康播放多久」）
constexpr int kMaxInterruptRetries = 1;
constexpr uint64_t kRetryHealthWindowMs = 15000;
std::atomic<double> g_cache_fraction{0};
std::atomic<double> g_network_bytes_per_second{0};
std::atomic<int64_t> g_playlist_position{0};
// 整季的播放地址。注意：只有当前这一集会交给 mpv —— 把整季都 loadfile 进去
// 的话，mpv 在任何 end-file（包括读取出错）之后都会自动前进到下一项，表现
// 就是「卡一下就跳下一集」。连播与选集一律走 LoadPlaylistEntry()。
std::vector<std::string> g_media_urls;
std::atomic<int> g_hover_control{0};
std::atomic<double> g_seek_hover{-1};
HWND g_window = nullptr;
HWND g_controls = nullptr;
HWND g_panel = nullptr;
HWND g_top_bar = nullptr;
// 提示浮层（跳过倒计时 / 音量亮度回显）。句柄放在这里而不是它自己的绘制函数
// 旁边：外观里的「玻璃浓度」热更新要给所有浮层发重画，那条路在这一段之前。
HWND g_hint = nullptr;
ULONG_PTR g_gdiplus_token = 0;
std::unique_ptr<Gdiplus::PrivateFontCollection> g_interface_font_collection;
std::unique_ptr<Gdiplus::FontFamily> g_interface_font_family;
std::unique_ptr<Gdiplus::PrivateFontCollection> g_iconsax_font_collection;
std::unique_ptr<Gdiplus::FontFamily> g_iconsax_font_family;
BYTE g_controls_alpha = 232;
ULONGLONG g_last_interaction = 0;
// 自动隐藏改为轮询光标位置：mpv 子类化了主窗口，光标停在画面或控件条上时
// 移动消息会被 mpv 吞掉，窗口过程收不到 WM_MOUSEMOVE，消息驱动永远学不到
// 「光标已经停了」。50ms 一次的位置对比不依赖消息，被吞也一样有效。
POINT g_last_cursor{-0x7fffffff, -0x7fffffff};
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
// 每一集的续播秒数，与 g_media_urls 同序（0 = 这一集没有记录，从头播）。
//
// ⚠️ 这件事**不能**交给 mpv 的命令行 `--start=`：它是普通（非文件局部）选项，
// mpv 手册 Per-File Options 明说「any option given on the command line usually
// affects all files」「are not reset when a new file is played」。原生换集走的是
// `loadfile <url> replace`，于是第 1 集的续播点会被 mpv 重新应用到第 2 集上 ——
// 每一集都从上一集的位置开始，正是用户报的「切换上下集都是从上一集的进度播放」。
// 改成每集在 loadfile 之前显式 set 一次 start（没有记录就显式归零）。
std::vector<double> g_playlist_resumes;
// 应用侧给「本次起播这一集」的精确续播点（秒）。它可能来自服务器端进度，比
// playlist 里那份由「观看比例 × 时长」估出来的值准，所以覆盖对应项。
double g_initial_position = 0.0;
// 上面那个值是不是由 `--mova-start` 明确给的。`--start=`（mpv 自己的选项）只作
// 兜底：老调用方、探针与手工调试还在用它指定起播点，但它的优先级更低。
bool g_initial_position_explicit = false;
int g_panel_hover = -1;
float g_play_state_mix = 0.0f;
float g_buffer_phase = 0.0f;
double g_seek_seconds = 10.0;
double g_volume_step = 5.0;
std::unordered_map<int, std::string> g_shortcuts;
// 统一帧率：播放器内的控件动画与弹幕都跑在 60fps 上，与应用（Flutter）界面
// 的刷新节奏一致。定时器只负责「叫醒」，动画一律按经过时间推进，因此帧率
// 变化时动画时长不变，只是更平滑。
//
// ⚠️ 这个 16ms **只作为拿不到刷新周期时的兜底**，不再是主路径。
// 它曾经被当成「对齐 60fps 的显示刷新」，而 16ms 是 62.5Hz —— 与 60Hz 的
// 16.667ms 也差 4%，在 170Hz 面板上（本机）更是差到 2.72 倍。后果不是「帧率
// 低」，而是**每帧停留的刷新周期数不是整数**：170/61.3 = 2.77 → 77% 的帧停留
// 3 个周期、23% 停留 2 个 → 屏幕上看得见的位移步长在 3:2 之间交替，约 14 次/秒。
// 均值 / late20 / late33 都正常，所以这个缺陷以前一直量不出来。
// 见 docs/specs/2026-09-22-danmaku-frame-pacing.md。
constexpr int kFrameIntervalMs = 16;
// 上一帧的时刻（QPC 毫秒）。动画按「经过时间」推进，所以这个差值必须是高精度
// 的：GetTickCount64（粒度 15.6ms）会让每帧的 dt 在 0 / 15.6 / 31.2ms 之间跳，
// 转圈和淡出看起来就是一下一下顿着走。
double g_last_frame_ms = 0.0;
// 面板一个刷新周期的毫秒数（由 DwmGetCompositionTimingInfo 取，失败退回
// EnumDisplaySettings 的标称值）。0 = 没拿到，退回 kFrameIntervalMs 的定时器。
double g_refresh_period_ms = 0.0;
// 每几个刷新周期出一帧（一个 tick = divisor × 刷新周期）。0 = 未启用节拍时钟。
int g_frame_divisor = 0;
bool g_danmaku_enabled = false;
// 弹幕由应用侧拉取后写入临时文本文件，原生侧读入并在视频之上叠加渲染。
std::wstring g_danmaku_path;
double g_danmaku_opacity = 0.82;
double g_danmaku_area = 0.65;
double g_danmaku_font_size = 18.0;
double g_danmaku_speed = 1.0;
double g_danmaku_density = 0.55;
bool g_danmaku_scroll = true;
bool g_danmaku_top = true;
bool g_danmaku_bottom = true;
HWND g_danmaku = nullptr;
constexpr wchar_t kDanmakuClass[] = L"MovaNativePlayerDanmaku";
// 弹幕每帧都要重画，位图与字体复用而不是重建。两者都持有 GDI+ 对象，
// 必须在 GdiplusShutdown 之前释放（见 ReleaseDanmakuSurface）。
struct PanelSurface;
PanelSurface* g_danmaku_surface = nullptr;
Gdiplus::Font* g_danmaku_font = nullptr;
float g_danmaku_font_px = -1.0f;
// 面板里要显示的状态：应用侧通过 stdin 把匹配结果一并送过来。
std::wstring g_danmaku_source;   // 命中的 API 名称
std::wstring g_danmaku_matched;  // 匹配到的作品 / 集
int g_danmaku_count = 0;         // 弹幕条数
bool g_danmaku_loading = false;  // 应用侧还在拉取
std::wstring g_danmaku_error;    // 失败原因

// 每条弹幕的文字只栅格化一次，画进一张刚好包住它的小位图（32bpp 预乘 ARGB），
// 之后每帧只做一次 GDI AlphaBlend。逐帧 DrawString 非常贵：实测同屏 162 条时
// 每帧要 8.9ms（60fps 的预算是 16.7ms），而它的输出对同一条弹幕是不变的 ——
// 变的只有位置。位图里的透明度按「满不透明」画，整体的不透明度由每帧的
// SourceConstantAlpha 施加，这样改「不透明度」不必重新栅格化。
struct DanmakuTexture {
  static constexpr int kPhases = 4;
  std::array<HDC, kPhases> dc{};
  std::array<HBITMAP, kPhases> bitmap{};
  std::array<HGDIOBJ, kPhases> previous{};
  std::array<BYTE*, kPhases> bits{};
  int width = 0;
  int height = 0;

  ~DanmakuTexture() { Destroy(); }

  bool Create(int w, int h) {
    Destroy();
    if (w <= 0 || h <= 0) return false;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;  // top-down，与弹幕层一致
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    for (int phase = 0; phase < kPhases; ++phase) {
      dc[phase] = CreateCompatibleDC(nullptr);
      if (!dc[phase]) {
        Destroy();
        return false;
      }
      void* raw = nullptr;
      bitmap[phase] =
          CreateDIBSection(dc[phase], &info, DIB_RGB_COLORS, &raw, nullptr, 0);
      if (!bitmap[phase] || !raw) {
        Destroy();
        return false;
      }
      previous[phase] = SelectObject(dc[phase], bitmap[phase]);
      bits[phase] = static_cast<BYTE*>(raw);
      memset(bits[phase], 0, static_cast<size_t>(w) *
                                     static_cast<size_t>(h) * 4);
    }
    width = w;
    height = h;
    return true;
  }

  void Destroy() {
    for (int phase = 0; phase < kPhases; ++phase) {
      if (dc[phase] && previous[phase]) SelectObject(dc[phase], previous[phase]);
      previous[phase] = nullptr;
      if (bitmap[phase]) DeleteObject(bitmap[phase]);
      bitmap[phase] = nullptr;
      if (dc[phase]) DeleteDC(dc[phase]);
      dc[phase] = nullptr;
      bits[phase] = nullptr;
    }
    width = 0;
    height = 0;
  }
};

struct DanmakuItem {
  double time = 0;        // 应出现的播放时间（秒）
  int mode = 1;           // 1 滚动, 4/5 顶部, 6 底部
  int color = -1;         // -1 用默认白
  std::wstring text;
  bool live = false;      // 是否已在屏幕上
  double appear = -1.0;   // 出现时刻（steady_clock 秒）
  int lane = -1;
  // 这条弹幕「让出自己轨道」的时刻（动画时钟）。占轨时写一次，之后不再变。
  // 记下来是为了在**局部**回收轨道时能按在屏条目重建占用表：改设置撤掉一类
  // 弹幕时，只能把那一类占的轨道还回去，不能整体归零 —— 否则还在屏上的那些
  // 轨道会被当成空的，新条目直接压上去。
  double free_at = 0.0;
  bool played = false;    // 已播完（飞出/超时）；seek 跳转检测会重置，允许重播
  float text_width = -1.0f;  // 缓存 MeasureString 结果（<0 表示未测过）
  float font_size = -1.0f;   // 该宽度是按哪个字号测的，字号变了要重测
  // 文字栅格化缓存。离开屏幕时释放（重新出现时重建），这样 GDI 对象数量只与
  // 「同时在屏的条数」有关，不会随整集的弹幕数增长到 GDI 句柄上限。
  std::shared_ptr<DanmakuTexture> texture;
};

std::vector<DanmakuItem> g_danmaku_items;
// 在屏条目（指向 g_danmaku_items 里的元素）与「下一条待处理」的光标。条目按
// 时间排好序，所以每帧只需要从光标往前推，整集摊下来是 O(N)。
std::vector<DanmakuItem*> g_danmaku_live;
size_t g_danmaku_cursor = 0;
// 每条轨道「下一次可用」的动画时钟时刻（滚动弹幕是尾巴离开右边缘的时刻，
// 顶/底弹幕是停留结束的时刻）。按轨道下标查询，见 PaintDanmaku 里的占轨规则。
// 整层被清空（跳转 / 换字号 / 关掉某一类弹幕）时必须一起归零，否则新条目会被
// 上一批留下的未来时刻挡住。
std::vector<double> g_danmaku_lane_free;
int g_danmaku_dropped = 0;

void ResetDanmakuLaneFree() {
  std::fill(g_danmaku_lane_free.begin(), g_danmaku_lane_free.end(), 0.0);
}
bool g_danmaku_loaded = false;
double g_danmaku_last_position = -1.0;
static const double kDanmakuExitSeconds = 4.0;          // 顶/底固定弹幕停留时长
static const double kDanmakuScrollBaseSeconds = 8.0;    // 滚动弹幕基础穿越时长
// 跳转之后只补「刚刚过去」的这一小段：以前补的是 600 秒，一次 seek 会把几百条
// 历史弹幕全放到屏上（连带几百次栅格化），画面上像炸开一样。
static const double kDanmakuCatchupSeconds = 2.0;
// 每帧给「栅格化新出现的弹幕」的预算：密集片头一次冒出来几十条时，把它们摊到
// 几帧里画，宁可晚一两帧显示，也不要卡掉一帧。
static const double kDanmakuRasterBudgetMs = 2.5;
// 栅格化时四周留的空边：阴影偏移 1.2px，加上抗锯齿的溢出。
static const int kDanmakuTexturePad = 2;
// MOVA_TRACE_PANEL 导出弹幕层的间隔（帧）。起播那一瞬整层只有几条贴在右边缘，
// 排版问题要等铺满之后才看得出来，所以挑稳态的两帧导。
static const long long kDanmakuTraceSpacingFrames = 330;
// 所有轨道都被占满时，最晚允许一条弹幕等这么久再入场；再久就直接丢掉。
// 真实播放器在「同屏上限」之后也是丢，而不是叠上去 —— 叠上去就是看不清。
static const double kDanmakuMaxDelaySeconds = 1.5;
// 同一条轨道上，前一条的**尾巴**再往里让出这么多像素，后一条才允许入场。
// 只按「尾巴刚离开右边缘」放行是不够的：那一刻两条弹幕的间距正好是 0，浮点
// 误差会让它们压上几个像素 —— 观感上就是「两句贴在一起、糊成一团」。留一段
// 固定间距之后，同轨相邻两条永远有肉眼可见的缝。
static const float kDanmakuLaneGapPx = 32.0f;
// 弹幕动画时钟（见 DanmakuAnimationClock）与「这一帧有没有东西需要重画」。
double g_danmaku_clock = 0.0;
double g_danmaku_clock_tick = 0.0;
bool g_danmaku_dirty = true;

// 弹幕帧耗时统计（MOVA_TRACE_DANMAKU）。一帧画了多久、两帧之间隔了多久，
// 比「屏上有几条」更能说明「一顿一顿」的成因：draw 高说明绘制超预算，
// gap 高说明定时器被别的东西堵住了。
double g_danmaku_paint_last = 0.0;
double g_danmaku_draw_ms = 0.0;
double g_danmaku_post_ms = 0.0;
double g_danmaku_gap_ms = 0.0;
// 只报「最大间隔」不足以定性：61 帧里偶尔抖一次，和整段稳定掉到 50fps，最大值
// 可能一样，观感却完全不同。所以把均值与「超过 20ms / 33ms 的帧数」一起记下来
// —— 均值贴着 16.7 就是 60fps 正常，只有 late 计数零星跳动。
double g_danmaku_gap_sum_ms = 0.0;
int g_danmaku_gap_count = 0;
int g_danmaku_gap_late20 = 0;
int g_danmaku_gap_late33 = 0;
// 「相邻两帧之间隔了几个刷新周期」的分布（只在拿到刷新周期时统计）。
//
// 这是唯一能直接判「平滑」的指标：均值 / late20 / late33 只说明「平均出够
// 帧数」，看不出**每帧被显示的时长是否相等**。理想是全部落在同一个整数拍数上
// （现在恒定 divisor 拍，本机 170Hz/divisor=2 → 全部落 2 拍）。
// 下标含义：`[1]`=1 拍、`[2]`=2 拍、`[3]`=3 拍、`[4]`=**≥4 拍**（兜底档）。
int g_danmaku_dwell[5] = {0, 0, 0, 0, 0};

// DWM 自报的合成节奏（rateCompose，毫秒）与它报的刷新周期。
//
// `qpcRefreshPeriod` 是**面板能多快**，`rateCompose` 是**DWM 打算跑多快** ——
// 两者可以不一样：DWM 在合成预算不够时会自行降频。实测过一轮：本机
// compose=5.88ms（≈169Hz，与面板一致），说明节拍问题**不在 DWM 的目标节奏**，
// 而在 DwmFlush 的返回本身会漏拍（fhist 实测 [30,29,1,0]）—— 否则会误判成
// 「DWM 被降到 124Hz」而去调根本没错的合成设置。
//
// 注意别再往这里加 `cFrameDisplayed` 算实测 fps：本机这个计数不推进（恒为 0），
// 算出来永远是 0，看上去像「合成器没在合成」，反而误导。
double g_dwm_compose_ms = 0.0;
double g_dwm_refresh_ms = 0.0;

// ---- 节拍时钟：高精度固定周期定时器 ----
//
// 见 docs/specs/2026-09-22-danmaku-frame-pacing.md。**不要**改回「每轮 DwmFlush
// 计满 divisor 拍」：实测 DwmFlush 的返回本身就在 1 拍 / 2 拍之间跳
// （`fhist=[30,29,1,0]`），把 tick 挂在它上面等于把这份抖动直接搬进 paint 间隔，
// 落成 2/3/4 拍的不规则混合（`dwell=[6,9,24,21]`，只有 4–8.5% 恰好 1 拍）。
//
// 唯一能给出**均匀 dwell** 的是与面板成精确整数比的固定周期时钟：
// `divisor × 刷新周期`（170Hz、divisor=2 → 11.7647ms）能精确表达成 100ns 的
// 117647 个单位，配上 CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 就有亚毫秒精度。
HANDLE g_pacing_timer = nullptr;
double g_pacing_period_ms = 0.0;  ///< 一个 tick = divisor × 刷新周期
double g_pacing_anchor_ms = 0.0;  ///< tick 绝对日程的原点
long long g_pacing_tick = 0;      ///< 已经排到第几个 tick
// 实测 tick 间隔（均值 / 次数）。
//
// `dwell` 量的是**绘制**间隔，正常情况下两者应当一致；一旦不一致，说明
// 「画的次数」和「节拍的次数」对不上（重复绘制 / 漏 tick），这时只盯 dwell 会查错方向。
double g_tick_last_ms = 0.0;
double g_tick_sum_ms = 0.0;
int g_tick_count = 0;

// 上面那三个只有**均值**，而均值对「每拍时长不等」是全盲的：1 拍 + 3 拍交替，
// 均值照样是 2 拍。所以再补一份**节拍间隔的分布**，和 `g_danmaku_dwell`（绘制
// 间隔分布）配对读：
//
//   * 两者都塌在 divisor 拍   → 真的锁住了；
//   * 节拍分布就是散的         → 定时器 / 主循环调度的问题，改绘制没用；
//   * 节拍整齐、绘制是散的     → tick 没问题，是**绘制被推迟**（WM_PAINT 是低
//     优先级消息，要等消息队列排空才派发，相位于是跟着消息负载漂）。
//
// 2026-09-22 加这一对，正是因为只看到「均值 = 11.76ms 达标」就把 1/3 拍交替
// 当成正常了。下标同 g_danmaku_dwell：`[1..3]`=1/2/3 拍，`[4]`=≥4 拍。
int g_tick_dwell[5] = {0, 0, 0, 0, 0};
double g_tick_gap_max = 0.0;
// 绘制相对**本拍 tick 时刻**滞后多少（均值 / 极差）。tick 整齐而 dwell 散时，
// 滞后极差就是「paint 相位在漂」的直接证据。
double g_paint_phase_sum_ms = 0.0;
double g_paint_phase_min_ms = 0.0;
double g_paint_phase_max_ms = 0.0;
int g_paint_phase_count = 0;
double g_tick_now_ms = 0.0;  ///< 最近一次 tick 的时刻（算 paint 相位用）
// 主等待返回「有消息」而不是「定时器到点」的次数。
//
// `MsgWaitForMultipleObjects` 返回索引 1 时**不会**复位定时器 —— 定时器保持
// 已触发状态，下一轮立即再返回一次索引 0，于是出现「一个短间隔 + 一个长间隔」
// 的交替。这个计数非零且与 tick 数同量级时，就是它。
int g_msg_wakes = 0;

double QpcToMs(long long qpc) {
  static const double k_frequency = [] {
    LARGE_INTEGER value{};
    QueryPerformanceFrequency(&value);
    return static_cast<double>(value.QuadPart);
  }();
  return k_frequency > 0.0 ? static_cast<double>(qpc) * 1000.0 / k_frequency
                           : 0.0;
}

// SampleCompositionTiming 的定义放在文件靠后的 NowMs 旁边 —— 它要用 NowMs，
// 而两者都在同一个匿名命名空间里。**不要**在这里写一句 `double NowMs();` 了事：
// 块作用域里的函数声明会落到**全局**命名空间，编译能过、链接必报 LNK2019。
int g_danmaku_frames = 0;
// 累计贴过多少帧（不受诊断窗口 60 帧的重置影响），用于挑「铺满之后」的稳态时刻
// 导出弹幕层位图。
long long g_danmaku_paint_total = 0;
// 本窗口里「同轨与他条横向相交」的条数峰值。这是「弹幕叠在一起看不清」的直接
// 度量：轨道分配只要不严密，这个数字就上去了。
int g_danmaku_overlap_max = 0;
// 最深的「压进去多少像素」。只数条数不够用：1px 是浮点误差留下的贴边，肉眼
// 看不出来；几十像素才是真的糊在一起。判缺陷要看这个深度。
double g_danmaku_overlap_depth = 0.0;
// 最深那一对的几何（轨道 + 两段的左右边界），跟 depth 一起回报。
int g_danmaku_overlap_lane = -1;
float g_danmaku_overlap_a0 = 0.0f;
float g_danmaku_overlap_a1 = 0.0f;
float g_danmaku_overlap_b0 = 0.0f;
float g_danmaku_overlap_b1 = 0.0f;
// 滚动弹幕穿过顶/底固定弹幕的条数峰值。所有播放器都是这个行为（固定弹幕占住
// 轨道正中停 4 秒，滚动弹幕从它上面飘过去），只作参考，不算缺陷 —— 但它能解释
// 「同轨有两拨东西」时 overlap 为什么仍然是 0。
int g_danmaku_mixed_max = 0;
int g_danmaku_lanes = 0;

void PositionDanmaku();
void PaintDanmaku();
void LoadDanmaku();
void CreateDanmakuWindow(HINSTANCE instance);
bool g_auto_skip_segments = true;
// 自动跳过的「提示停留」秒数，与应用设置里的同一项对应。
double g_skip_delay_seconds = 5.0;

// ---- 片头片尾 ------------------------------------------------------------
// 数据由应用侧按设置里勾选的来源拉好，经 stdin 下发（原生不联网、不持有令牌）。
// 原生只负责：面板里展示、手动跳转、以及按设置执行自动跳过。
enum class SegmentKind { intro, recap, credits, preview };

struct SegmentItem {
  SegmentKind kind = SegmentKind::intro;
  double start = 0;
  /// 结束秒；< 0 表示来源没给结束点（片尾条目常常只有起点），按总时长处理。
  double end = -1;
  std::wstring provider;
  /// 已跳过 / 本次不跳过：不再重复触发。
  bool consumed = false;
};

std::vector<SegmentItem> g_segments;
/// 一次下发的多条片段先攒在这里，等 MOVA_SEGMENTS_DONE 到了再整体替换 ——
/// 逐条替换会让面板/自动跳过看到半截数据。
std::vector<SegmentItem> g_segments_pending;
bool g_segments_loading = false;
bool g_segments_ready = false;
std::wstring g_segments_error;
/// 正在倒计时的那一段（-1 表示没有），以及它的截止时刻。
int g_skip_index = -1;
uint64_t g_skip_deadline = 0;
uint64_t g_skip_hint_shown = 0;
/// 片段表由 stdin 线程整体替换、主线程读取（面板与自动跳过），所以替换与
/// 读取都走这把锁。主线程侧一律用 SegmentsSnapshot() 拿副本，避免读到被
/// 替换到一半的向量。
std::mutex g_segments_mutex;

/// 播放期间应用侧改了「设置 → 弹幕显示 / 片头片尾」里的项，经 stdin 推过来。
/// stdin 线程只负责入队并叫醒主线程：这些设置会动窗口（弹幕层要重新贴合、
/// 重绘），窗口操作必须留在创建它的线程上。
std::mutex g_live_mutex;
std::vector<std::pair<std::string, std::string>> g_live_pending;

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

// ---- 自绘 UI 的全局缩放 --------------------------------------------------
//
// 下面的尺寸常量都是按 1280×760 的窗口量出来的设计稿值。窗口比这小的时候
// 照搬就会互相挤压、探出屏幕；比这大时又显得小气。所有绘制与命中判定统一
// 从 UiScale() 取系数：窗口变小整体等比缩小，变大轻微放大（封顶，避免 4K
// 全屏时按钮大到夸张）。绘制与命中必须用同一个系数，否则点不准。
constexpr float kUiDesignWidth = 1280.0f;
constexpr float kUiDesignHeight = 760.0f;
constexpr float kUiMinScale = 0.55f;
constexpr float kUiMaxScale = 1.25f;
std::atomic<float> g_ui_scale{1.0f};

float UiScale() { return g_ui_scale.load(); }

int Scaled(int value) {
  return static_cast<int>(std::lround(static_cast<double>(value) *
                                      UiScale()));
}

float ScaledF(float value) { return value * UiScale(); }

// 由主窗口客户区推导缩放系数，取宽高比例中较小者，保证小维度也放得下。
void UpdateUiScale(const RECT& client) {
  const float width = static_cast<float>(client.right - client.left);
  const float height = static_cast<float>(client.bottom - client.top);
  g_ui_scale.store(std::clamp(std::min(width / kUiDesignWidth,
                                       height / kUiDesignHeight),
                              kUiMinScale, kUiMaxScale));
}

// 弹出菜单的度量与 Flutter 弹窗对齐：卡片式行、12px 圆角、图标容器 34px。
constexpr int kPanelPadding = 10;constexpr float kPanelRowGap = 6.0f;
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

// ---------------------------------------------------------------- 液态玻璃
//
// 原生侧没有背板高斯模糊（GDI+ 没有），所以这里复刻应用侧那套配方的**另一半**：
//
//   * 基色 —— 取 `YingjiGlass.frost`（#14141A），而不是此前那块海军蓝
//     (43,47,57)/(22,24,30)。偏蓝的近黑叠在白字幕上会发青，也是用户说
//     「菜单是一块黑色背景」的来源之一。
//   * 浓度 —— 与应用侧常规玻璃和 HUD 的两级透明度保持同一范围；
//     整条曲线由「设置 → 外观 → 模糊程度」驱动（stdin 的
//     `MOVA_APPLY=mova-glass-blur|<0-40>`）：模糊越大 → 玻璃越薄、越透。
//   * 厚度 —— `YingjiGlass.depth` 那条「只沉底边」的渐变，**里面没有白色**：
//     白 = 高光，把材质带向塑料片的就是它。
//   * 描边 —— 白 .16 的 1px 内描边（与 Dart 侧 `YingjiGlass.line()` 同值）。
//
// 默认 30 与 Dart 侧 `YingjiAppearance.glassBlur` 一致。
std::atomic<double> g_glass_blur{30.0};

/// 玻璃基色：与应用侧 `YingjiGlass.frost` 完全一致。
constexpr BYTE kGlassFrostRed = 247;
constexpr BYTE kGlassFrostGreen = 250;
constexpr BYTE kGlassFrostBlue = 255;

/// 玻璃厚度 0.55 ~ 1.0；1.0 = 最透（模糊拉满）。
float GlassLevel() {
  const double blur = std::clamp(g_glass_blur.load(), 0.0, 40.0);
  return static_cast<float>(0.55 + 0.45 * (blur / 40.0));
}

/// 面板 / 提示这类大面积玻璃的底色。默认（30）给 97 → 87。
///
/// 这里只压一层约 30% 的中性基色；真正的材质来自背板模糊和连续光学曲线，
/// 而不是把面板做成不透明深色板。
///
/// 仍然跟着「设置 → 外观 → 模糊程度」走：模糊越弱，玻璃要越实才能压住背后那张
/// 越来越清晰的画面。
int GlassPanelAlpha(bool bottom) {
  const float level = GlassLevel();
  const double base = 16.0 + (1.0 - level) * 8.0;
  return static_cast<int>(std::lround(bottom ? base + 3.0 : base));
}

/// 控件条 / 顶栏上的按钮圆片：面积小、常驻，做得很薄，画面透得最多。
int GlassDiscAlpha(bool bottom) {
  const float level = GlassLevel();
  const double base = 9.0 + (1.0 - level) * 6.0;
  return static_cast<int>(std::lround(bottom ? base + 2.0 : base));
}

/// 小面积但**带字**的玻璃（顶栏的网络胶囊）：比纯按钮圆片实一点，否则上面的
/// 12px 数字压不住画面。
int GlassChromeAlpha(bool bottom) {
  const float level = GlassLevel();
  const double base = 13.0 + (1.0 - level) * 7.0;
  return static_cast<int>(std::lround(bottom ? base + 3.0 : base));
}

/// 图标阴影：控件条去掉底板之后，白色字形要靠这一层暗影才在亮画面上读得出来。
constexpr float kGlyphShadowOffset = 1.0f;
constexpr int kGlyphShadowAlpha = 118;

// 背板模糊（原生侧的 BackdropFilter）—— 三个入口先声明在这里，实现在 PanelSurface
// 之后（那边才有画板对象可用）：FillGlassSurface 要给玻璃铺背板，位置在这之前。
void ReleaseGlassBackdrop();
bool UpdateGlassBackdrop(bool force);
bool DrawGlassBackdrop(Gdiplus::Graphics& graphics,
                       const Gdiplus::GraphicsPath& path,
                       const Gdiplus::RectF& rect);

/// 一片玻璃的底色：基色渐变 + 应用侧 `YingjiGlass.depth` 那条「只沉底边」的厚度。
/// 面板、二级菜单、提示、悬浮气泡全部走它 —— 材质只有这一处定义，改一次全跟着
/// 变，不会再出现「这个菜单改了、那个提示还是黑塑料」的割裂。
///
/// `use_backdrop` 打开时先铺一层「被模糊、轻微提饱和的背后画面」（见
/// DrawGlassBackdrop）。这一层是不透明的，于是整块玻璃的合成变成
/// `blur(背后) × (1−α) + frost × α` —— 与应用侧 `backdrop()` ＋ `surface()` 完全
/// 同构。它不是「假透明」：真实的分层窗口透明度仍在（背板拿不到时就走原来的路），
/// 只是换成了「背后画面先糊再混」这种更接近毛玻璃的合成方式。
void FillGlassSurface(Gdiplus::Graphics& graphics,
                      const Gdiplus::GraphicsPath& path,
                      const Gdiplus::RectF& rect, int top_alpha,
                      int bottom_alpha, bool use_backdrop = false) {
  const bool has_backdrop = use_backdrop && DrawGlassBackdrop(graphics, path, rect);
  if (has_backdrop) {
    // A restrained neutral tint keeps white text legible without washing out
    // the video colours. Apply once per glass surface.
    Gdiplus::SolidBrush tint(Gdiplus::Color(78, 12, 13, 15));
    graphics.FillPath(&tint, &path);
  }
  Gdiplus::LinearGradientBrush surface(
      Gdiplus::PointF(rect.X, rect.Y), Gdiplus::PointF(rect.X, rect.GetBottom()),
      Gdiplus::Color(static_cast<BYTE>(top_alpha), kGlassFrostRed,
                     kGlassFrostGreen, kGlassFrostBlue),
      Gdiplus::Color(static_cast<BYTE>(bottom_alpha), kGlassFrostRed,
                     kGlassFrostGreen, kGlassFrostBlue));
  graphics.FillPath(&surface, &path);
  // 一条覆盖完整高度的连续光学曲线。上一版把顶部反射和底部厚度分别限制在
  // 局部区间，GDI+ 会把区间外颜色钳住，于是圆钮里出现两条硬横纹。
  Gdiplus::LinearGradientBrush optics(
      Gdiplus::PointF(rect.X, rect.Y),
      Gdiplus::PointF(rect.X, rect.GetBottom()), Gdiplus::Color(0, 0, 0, 0),
      Gdiplus::Color(0, 0, 0, 0));
  Gdiplus::Color optical_colors[5] = {
      Gdiplus::Color(13, 255, 255, 255),
      Gdiplus::Color(5, 255, 247, 224), Gdiplus::Color(0, 255, 255, 255),
      Gdiplus::Color(2, 130, 205, 255), Gdiplus::Color(4, 0, 0, 0)};
  Gdiplus::REAL optical_positions[5] = {0.0f, 0.14f, 0.46f, 0.78f, 1.0f};
  optics.SetInterpolationColors(optical_colors, optical_positions, 5);
  graphics.FillPath(&optics, &path);
}

/// 玻璃的一圈内描边（白 .16）。面板、提示、气泡共用同一个值：以前面板 46、
/// 控件条 76，同一屏里两圈线亮度不同，看着就不是一套皮肤。
void StrokeGlassEdge(Gdiplus::Graphics& graphics,
                     const Gdiplus::GraphicsPath& path) {
  Gdiplus::RectF bounds;
  path.GetBounds(&bounds);
  Gdiplus::LinearGradientBrush light(
      Gdiplus::PointF(bounds.X, bounds.Y),
      Gdiplus::PointF(bounds.GetRight(), bounds.GetBottom()),
      Gdiplus::Color(105, 255, 246, 222), Gdiplus::Color(28, 255, 255, 255));
  Gdiplus::Pen edge(&light, 0.8f);
  graphics.DrawPath(&edge, &path);
}

/// 玻璃上的文字：先垫一层轻薄暗色轮廓再写字。
///
/// 原生没有背板模糊，玻璃一透，白字压到亮画面上就糊了 —— 这层暗影就是应用侧那个
/// `BackdropFilter` 的替身（控件条去掉底板后给字形垫的也是它）。
void DrawGlassText(Gdiplus::Graphics& graphics, const wchar_t* text,
                   const Gdiplus::Font& font, const Gdiplus::RectF& box,
                   const Gdiplus::StringFormat& format,
                   const Gdiplus::Brush& brush,
                   BYTE shadow_alpha = kGlyphShadowAlpha) {
  Gdiplus::SolidBrush shade(Gdiplus::Color(shadow_alpha, 0, 0, 0));
  constexpr float outline = 0.7f;
  for (const Gdiplus::PointF offset :
       {Gdiplus::PointF(-outline, 0), Gdiplus::PointF(outline, 0),
        Gdiplus::PointF(0, -outline), Gdiplus::PointF(0, outline)}) {
    graphics.DrawString(
        text, -1, &font,
        Gdiplus::RectF(box.X + offset.X, box.Y + offset.Y, box.Width,
                       box.Height),
        &format, &shade);
  }
  graphics.DrawString(text, -1, &font, box, &format, &brush);
}

// ------------------------------------------- 背板模糊（原生侧的 BackdropFilter）
//
// 原生没有 `BackdropFilter`：分层窗口只能「透」，不能「糊」。而应用里那层液态玻璃
// 有一半的质感来自**背后那张被模糊、轻微提饱和的画面**
// （`YingjiGlass.backdrop()`）—— 少了它，同一支 frost 基色、同一个浓度，在应用里
// 是玻璃，在播放器里就是一块黑板。这里把缺的那半块补上：抓一帧背后的画面，降采样
// ＋三次盒式模糊近似高斯＋轻微提饱和，画在 frost 底下。
//
// 从播放器 HWND 获取视频源，再裁切可见玻璃区域；不从桌面抓取自己的浮层，
// 避免菜单反复进入背板造成白色残影。CPU 采集仍受窗口尺寸与驱动影响。
//
/// 最小采样间隔，不代表实际达到 60 FPS；实际速率受采集耗时限制。
constexpr ULONGLONG kGlassBackdropRefreshMs = 16;
/// 模糊在 1/6 尺寸上做：像素量只有原图的 1/36，给 60Hz 采集留出
/// CPU 预算。HALFTONE 降采样已经提供一层低通，对最终本就需要强模糊的玻璃不会
/// 损失可见细节。
constexpr int kGlassDownscale = 6;
/// 盒式模糊的遍数（三次已经足够接近高斯，再多只是更贵）。
constexpr int kGlassBlurPasses = 3;

struct GlassLayer {
  HWND window = nullptr;
  // 成员别叫 small：`rpcndr.h` 里有 `#define small char`。
  PanelSurface* reduced = nullptr;       ///< UI 线程只读的最新完成帧
  PanelSurface* reduced_back = nullptr;  ///< 后台线程写入的下一帧
  std::vector<BYTE> scratch;
  int source_width = 0;
  int source_height = 0;
  int origin_x = 0;
  int origin_y = 0;
  bool ready = false;
};

struct GlassBackdrop {
  PanelSurface* video = nullptr;  ///< 仅播放器窗口的画面，不含独立浮层
  std::array<GlassLayer, 4> layers{};
  std::mutex mutex;                      ///< 只保护前后帧交换与读取
  std::atomic<ULONGLONG> captured_at{0};
  // 「最后一次尝试」的 tick，成功失败都记。失败（黑屏 / 抓不动）时如果只看
  // captured_at，节流条件永远不满足，会在失败时空转。失败也要进节流。
  ULONGLONG attempted_at = 0;
};

GlassBackdrop g_backdrop;

/// 正在绘制的这块玻璃所在窗口的客户区 (0,0) 在屏幕上的位置。设计稿矩形要映射回
/// 背板的像素就靠它 —— 每个窗口在开画前设一次（面板与提示各一处）。
POINT g_glass_window_origin{0, 0};

void SyncGlassWindowOrigin(HWND window) {
  RECT frame{};
  if (window && GetWindowRect(window, &frame)) {
    g_glass_window_origin.x = frame.left;
    g_glass_window_origin.y = frame.top;
  }
}

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
// 自动隐藏的计时器只有一个入口，一旦「该隐藏却不隐藏」，最要紧的是知道
// 谁在刷新它。宏把调用点行号带进 ShowControlsAt，配合下面的诊断开关就能
// 直接看到刷新来源，不用每次排查都临时改代码。
void ShowControlsAt(int line);
#define ShowControls() ShowControlsAt(__LINE__)
void SetOverlayHitTest(bool enabled);
std::string Utf8(const std::wstring& value);
void OpenPanel(std::vector<PanelItem> items, PanelAnchor anchor,
               PanelMetrics metrics);
// 提示浮层：调整操作（音量 / 亮度 / 倍速 / 快进退 / 跳转）时的实时反馈。
// 按钮悬浮名称气泡已移除：鼠标扫过一排按钮时每个按钮都弹一张卡，比
// 「确认悬停目标」更干扰；按钮身份用高亮动效表达已经足够。
enum class HintMode { Hidden, Toast };

void ShowHint(const std::wstring& text, const std::wstring& detail,
              wchar_t icon, HintMode mode, float fraction, int anchor_x,
              bool accent = false);
void HideHint();
void ShowAdjustHint(const std::wstring& title, const std::wstring& detail,
                    wchar_t icon, float fraction, bool accent = false);

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

// 这一集该从第几秒开始（0 = 没有记录）。小于 1 秒的残值当 0：从第 0.4 秒起播
// 与从头播没有区别，反而多一次 seek。
double EntryResumeSeconds(int64_t index) {
  if (index < 0 || index >= static_cast<int64_t>(g_playlist_resumes.size())) {
    return 0.0;
  }
  const double value = g_playlist_resumes[static_cast<size_t>(index)];
  return value >= 1.0 ? value : 0.0;
}

// 让「接下来 loadfile 进来的那一集」从它自己的续播点开始。
//
// 必须每次 loadfile 之前调一次，而且**没有记录时也要显式归零**：mpv 的 `start`
// 是普通选项，换文件时不会被清掉，留着上一集的值就让新集从上一集的位置起播。
void ApplyPlaylistStart(int64_t index) {
  const std::string value = std::to_string(EntryResumeSeconds(index));
  MpvCommand("set", "start", value.c_str());
}

// 切到播放列表的第 index 项。mpv 里始终只装着这一项，所以换集必须用
// loadfile 而不是 playlist-next / playlist-pos —— 后者在单项列表上无效。
// 索引由我们自己维护，Dart 侧据此跟踪集数、切换缓存与预加载下一集。
bool LoadPlaylistEntry(int64_t index) {
  if (index < 0 || index >= static_cast<int64_t>(g_media_urls.size())) {
    return false;
  }
  g_playlist_position = index;
  g_cache_fraction = 0;
  g_playback_error = false;
  g_last_valid_position = 0;
  // 换了一集：中断重试的预算重新给（见 kMaxInterruptRetries 的注释）。
  g_retry_count = 0;
  g_resume_seconds = 0;
  if (!g_handle) return false;
  // 换集前先把起播点换成**这一集自己的**：不换的话 mpv 会沿用上一集的值
  // （见 g_playlist_resumes 的注释）。
  ApplyPlaylistStart(index);
  const char* args[] = {"loadfile",
                        g_media_urls[static_cast<size_t>(index)].c_str(),
                        "replace", nullptr};
  return g_mpv.command(g_handle, args) >= 0;
}

// 在同一集上重开一次。用于播放中断的自动重试：注意它**不走**
// LoadPlaylistEntry()——那里会把重试预算清零，一抖就无限重试了。
// 位置不在这里 seek：文件还没加载完时发 seek 会落空，改在 FILE_LOADED 里补。
bool RetryCurrentEpisode() {
  if (!g_handle) return false;
  const int64_t index = g_playlist_position.load();
  if (index < 0 || index >= static_cast<int64_t>(g_media_urls.size())) {
    return false;
  }
  const double resume = g_last_valid_position.load();
  // 退回最后一次有效位置即可，不用减偏移：这一集本来就是从这里断的。
  g_resume_seconds = resume > 1.0 ? resume : 0.0;
  // 起播点也要显式设：mpv 会沿用上一次 set 的值（那是这一集最早的续播点），
  // 不覆盖就会先跳到旧位置、再由 FILE_LOADED 的补 seek 拉回断点，多一次跳动。
  const std::string start_value = std::to_string(g_resume_seconds.load());
  MpvCommand("set", "start", start_value.c_str());
  const char* args[] = {"loadfile",
                        g_media_urls[static_cast<size_t>(index)].c_str(),
                        "replace", nullptr};
  if (g_mpv.command(g_handle, args) < 0) {
    g_resume_seconds = 0;
    return false;
  }
  g_cache_fraction = 0;
  g_playback_error = false;
  g_retry_stamp = GetTickCount64();
  char trace[96]{};
  std::snprintf(trace, sizeof(trace), "MOVA_RETRY=%lld|%.3f\r\n",
                static_cast<long long>(index), g_resume_seconds.load());
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    WriteFile(output, trace, static_cast<DWORD>(std::strlen(trace)), &written,
              nullptr);
  }
  return true;
}

// 播放失败之后的**显式**恢复：重开当前集，位置等 FILE_LOADED 时再补回来。
//
// 与自动重试只差一处，但这一处是关键：它会**清零重试预算**。RetryCurrentEpisode
// 故意不动预算（防止自动重试变成无限循环），可用户按下按钮是另一回事 —— 不清零
// 的话，自动补的那一次失败之后，用户再点也只是白发一条 loadfile，界面永远停在
// 「播放失败」。
//
// 返回 true 表示这次动作已经被当成「重新播放」处理了，调用方不要再发 cycle pause：
// mpv 此刻是 idle，pause 属性根本没有文件可作用。
bool ReplayAfterPlaybackFailure() {
  if (!g_playback_error.load()) return false;
  const int64_t index = g_playlist_position.load();
  if (index < 0 || index >= static_cast<int64_t>(g_media_urls.size())) {
    return false;
  }
  g_retry_count = 0;
  if (!RetryCurrentEpisode()) {
    ShowToast("重新播放失败");
    return false;
  }
  char trace[96]{};
  std::snprintf(trace, sizeof(trace), "MOVA_REPLAY=%lld|%.3f\r\n",
                static_cast<long long>(index), g_resume_seconds.load());
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    WriteFile(output, trace, static_cast<DWORD>(std::strlen(trace)), &written,
              nullptr);
  }
  ShowToast("正在重新播放…");
  return true;
}

// 图标与工具栏保持同一套语义：音轨用扬声器、字幕用字幕框、自动用星标。
//
// ⚠️ 这一组定义在**片头片尾之前**：跳过提示、工具面板、设置面板都更早就要引用。
constexpr wchar_t kGlyphSpeaker = L'\xF08F';
constexpr wchar_t kGlyphSubtitle = L'\xEFCE';
constexpr wchar_t kGlyphSparkles = L'\xED43';
constexpr wchar_t kGlyphInfo = L'\xECDD';
// 二者都取自与应用 YingjiIcons 同一张表：kGlyphEpisodes = document_text（列表）、
// kGlyphServer = data（应用里 "资源" 用的就是它）。
constexpr wchar_t kGlyphEpisodes = L'\xEB73';
constexpr wchar_t kGlyphServer = L'\xEB14';
// 面板行里用到的其余字形。
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

// 一行反馈。以前是 mpv 的 show-text，字体、位置、配色全是 mpv 的；现在和面板
// 走同一个自绘浮层，位置也固定贴在控件条上方，不再压在画面中间。
void ShowToast(const std::string& text) {
  if (text.empty()) return;
  ShowHint(Wide(text), std::wstring(), 0, HintMode::Toast, -1.0f, 0);
}

// ===================== 片头片尾 =====================
void HideHint();

const wchar_t* SegmentLabel(SegmentKind kind) {
  switch (kind) {
    case SegmentKind::recap:
      return L"前情提要";
    case SegmentKind::credits:
      return L"片尾";
    case SegmentKind::preview:
      return L"下集预告";
    default:
      return L"片头";
  }
}

std::wstring SegmentGlyphLabel(SegmentKind kind) {
  return std::wstring(SegmentLabel(kind));
}

// 段落的结束秒。来源只给起点时（公共库的片尾大多是这种）退回总时长 ——
// 播放器里读的总时长比任何推测都可靠。
double SegmentEnd(const SegmentItem& segment) {
  if (segment.end > segment.start) return segment.end;
  const double duration = g_duration.load();
  return duration > segment.start ? duration : segment.start;
}

// 一批片段下发完（MOVA_SEGMENTS_DONE）才整体换上去，避免面板和自动跳过
// 看到「只到了一半」的中间状态。由 stdin 线程调用。
void ApplyPendingSegments() {
  {
    std::lock_guard<std::mutex> guard(g_segments_mutex);
    g_segments = std::move(g_segments_pending);
  }
  g_segments_pending.clear();
  g_segments_ready = true;
}

/// 主线程侧的读取入口：拿一份副本，锁只在这个函数里短短持有一瞬间。
std::vector<SegmentItem> SegmentsSnapshot() {
  std::lock_guard<std::mutex> guard(g_segments_mutex);
  return g_segments;
}

bool SegmentActive(const SegmentItem& segment, double position, double duration) {
  if (segment.consumed) return false;
  const double end = SegmentEnd(segment);
  if (end <= segment.start) return false;
  if (position < segment.start || position >= end) return false;
  // 公共数据需要体检；用户手动标记是明确指令，不应用启发式规则否决。
  if (segment.provider != L"手动设置") {
    if (segment.kind == SegmentKind::credits) {
      if (duration <= 0 || segment.start < duration * 0.5) return false;
    } else if (duration > 0 && segment.start > duration * 0.5) {
      return false;
    }
  }
  return true;
}

int ActiveSegmentIndex(const std::vector<SegmentItem>& segments, double position,
                       double duration) {
  for (size_t index = 0; index < segments.size(); ++index) {
    if (SegmentActive(segments[index], position, duration)) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

// 跳过一个片段。片头 / 前情 / 预告跳到它的结束点；片尾则前进到下一集
// （已经是最后一集时跳到结尾，让「播完」按正常 EOF 处理）。
void SkipSegment(size_t index, bool automatic) {
  SegmentItem segment;
  {
    std::lock_guard<std::mutex> guard(g_segments_mutex);
    if (index >= g_segments.size()) return;
    g_segments[index].consumed = true;
    segment = g_segments[index];
  }
  g_skip_index = -1;
  HideHint();
  const std::wstring label = SegmentGlyphLabel(segment.kind);
  if (segment.kind == SegmentKind::credits) {
    if (LoadPlaylistEntry(g_playlist_position.load() + 1)) {
      ShowControls();
      ShowToast(Utf8(automatic ? label + L"已跳过，正在播放下一集"
                               : label + L"已跳过"));
      return;
    }
    const double duration = g_duration.load();
    if (duration > 0) {
      MpvCommand("seek", std::to_string(duration).c_str(), "absolute");
    }
    ShowControls();
    ShowToast(Utf8(label) + "已跳过");
    return;
  }
  double end = SegmentEnd(segment);
  const double duration = g_duration.load();
  // 片段数据来自公共库，结束点偶尔跑到总时长之外（拿错版本，或时长字段是按
  // 另一个版本算的）。照跳就会 seek 到文件之外：mpv 立刻报到结尾，位置校验
  // 看到「已经播到片尾」，于是当成正常播完去切下一集 —— 表现就是「自动跳过
  // 之后直接跳集」。留 1 秒余量，落到文件里才跳。
  if (duration > 0 && end > duration) end = duration - 1.0;
  if (end <= segment.start + 0.5) return;
  // 位置已经越过结束点（重复下发的数据、用户手动拖过）就不必再跳。
  if (g_position.load() >= end - 0.5) return;
  MpvCommand("seek", std::to_string(end).c_str(), "absolute");
  ShowControls();
  ShowToast(Utf8(automatic ? label + L"已自动跳过" : label + L"已跳过"));
}

// 自动跳过：位置落进某个片段后先提示、按设置里的秒数倒计时，到点才跳。
// 倒计时期间用户可以在「片头片尾」面板里点「本次不跳过」取消。
void UpdateAutoSkip(uint64_t now) {
  if (!g_auto_skip_segments || g_paused.load()) {
    g_skip_index = -1;
    return;
  }
  const auto segments = SegmentsSnapshot();
  if (segments.empty()) {
    g_skip_index = -1;
    return;
  }
  const int candidate =
      ActiveSegmentIndex(segments, g_position.load(), g_duration.load());
  if (candidate < 0) {
    g_skip_index = -1;
    return;
  }
  if (candidate != g_skip_index) {
    g_skip_index = candidate;
    g_skip_deadline = now + static_cast<uint64_t>(
                                std::max(0.0, g_skip_delay_seconds) * 1000.0);
    g_skip_hint_shown = 0;
  }
  const double remaining = g_skip_deadline > now
                               ? static_cast<double>(g_skip_deadline - now) / 1000.0
                               : 0.0;
  // 每半秒刷一次提示：文案里的剩余秒数要跟着走，进度条也才有推进感。
  if (g_skip_hint_shown == 0 || now - g_skip_hint_shown >= 500) {
    g_skip_hint_shown = now;
    const double total = std::max(0.1, g_skip_delay_seconds);
    const std::wstring label = SegmentGlyphLabel(segments[candidate].kind);
    // 跳过是「要发生的事」，用应用侧的成功绿做强调（进度线与图标同色），
    // 与提示里其它白色信息分开 —— 参考图里那条 +6s 就是这么用的。
    ShowHint(
        label + L" · " + std::to_wstring(static_cast<int>(remaining + 0.999)) +
            L" 秒后跳过",
        L"打开菜单可取消", kGlyphScissors, HintMode::Toast,
        static_cast<float>(std::clamp(1.0 - remaining / total, 0.0, 1.0)), 0,
        true);
  }
  if (now >= g_skip_deadline) {
    SkipSegment(static_cast<size_t>(candidate), true);
  }
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

// ---- 弹幕显示设置 --------------------------------------------------------
//
// 与应用「设置 → 弹幕显示」是同一批值、同一批 SharedPreferences 键：
// 面板里改完立刻作用于已加载的弹幕，并把新值回传应用写盘（MOVA_SETTING），
// 下次起播直接沿用，两边不会各说各话。
void EmitSetting(const std::string& key, const std::string& value) {
  char text[192]{};
  const int length = std::snprintf(text, sizeof(text), "MOVA_SETTING=%s|%s\r\n",
                                   key.c_str(), value.c_str());
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE && length > 0) {
    DWORD written = 0;
    WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
  }
}

// 画面比例在设置页里存的是标签（自动 / 16:9 / 4:3 / 21:9），mpv 这边用的是比例
// 数值 —— 回写时得转回同一套说法，否则设置页那条下拉读不出自己的值。
std::string AspectPreferenceLabel(const std::string& value) {
  const double ratio = std::strtod(value.c_str(), nullptr);
  if (ratio <= 0.0001) return "自动";
  if (std::abs(ratio - 1.7777778) < 0.01) return "16:9";
  if (std::abs(ratio - 1.3333333) < 0.01) return "4:3";
  if (std::abs(ratio - 2.3333333) < 0.01) return "21:9";
  return "自动";
}

// 控件菜单里改的播放器偏好要沿用到下一次播放：把 mpv 属性回写成应用偏好，应用
// 侧起播时再下发回来。以前只在本次播放里生效，下次播又回到设置页里的旧值，
// 用户会以为「改了没用」。
//
// 应用侧对回写有白名单（见 windows_native_player.dart 的 _saveNativeSetting），
// 这里列出的就是白名单里的那几个键，多发的会被丢掉。
void EmitPlayerPreference(const std::string& property,
                          const std::string& value) {
  if (property == "speed") {
    EmitSetting("yingji.player.speed", value);
  } else if (property == "volume") {
    EmitSetting("yingji.player.volume", value);
  } else if (property == "brightness") {
    EmitSetting("yingji.player.brightness", value);
  } else if (property == "video-aspect-override") {
    EmitSetting("yingji.player.aspect", AspectPreferenceLabel(value));
  }
}

// 音量是连续量：拖一次音量条会连着发出几十个值，逐个回写就是几十次写盘。攒到
// 手停下来（400ms 没有新值）再回写一次，播放器退出前的那次也会被 TickFrame
// 收尾时冲掉。
double g_volume_pending = -1.0;
uint64_t g_volume_pending_deadline = 0;

void NoteVolumeForPreference(double volume) {
  g_volume_pending = volume;
  g_volume_pending_deadline = GetTickCount64() + 400;
}

void FlushPendingPlayerPreferences() {
  if (g_volume_pending < 0.0) return;
  if (GetTickCount64() < g_volume_pending_deadline) return;
  const double volume = g_volume_pending;
  g_volume_pending = -1.0;
  char text[32]{};
  std::snprintf(text, sizeof(text), "%g", volume);
  EmitSetting("yingji.player.volume", text);
}

std::string NumberText(double value) {
  char text[32]{};
  std::snprintf(text, sizeof(text), "%g", value);
  return text;
}

/// 在当前值之后找下一个档位，到头回到第一个。面板里每点一次前进一档，
/// 一屏就把所有可调项摆完，不必为每个档位单开一行。
std::string NextStep(const std::vector<double>& steps, double current) {
  for (const double step : steps) {
    if (step > current + 0.001) return NumberText(step);
  }
  return NumberText(steps.empty() ? current : steps.front());
}

std::wstring DanmakuAreaLabel(double value) {
  return std::to_wstring(static_cast<int>(std::lround(value * 100))) + L"%";
}

std::wstring DanmakuOpacityLabel(double value) {
  if (value < 0.7) return L"淡";
  if (value < 0.95) return L"标准";
  return L"清晰";
}

std::wstring DanmakuFontLabel(double value) {
  if (value < 16.5) return L"小";
  if (value < 20.5) return L"标准";
  return L"大";
}

std::wstring DanmakuSpeedLabel(double value) {
  if (value < 0.85) return L"慢";
  if (value < 1.25) return L"标准";
  return L"快";
}

std::wstring DanmakuDensityLabel(double value) {
  if (value < 0.45) return L"稀疏";
  if (value < 0.7) return L"标准";
  return L"密集";
}

void ApplyDanmakuSetting(const std::string& name, const std::string& value) {
  const double number = std::strtod(value.c_str(), nullptr);
  std::string emitted = value;
  if (name == "area") {
    g_danmaku_area = std::clamp(number, 0.2, 1.0);
    // 区域变了要把弹幕窗口重新贴合：窗口高度就是这块区域的高度。
    PositionDanmaku();
    emitted = NumberText(g_danmaku_area);
  } else if (name == "opacity") {
    g_danmaku_opacity = std::clamp(number, 0.15, 1.0);
    emitted = NumberText(g_danmaku_opacity);
  } else if (name == "font-size") {
    g_danmaku_font_size = std::clamp(number, 12.0, 30.0);
    // 字号变了由绘制侧按缓存里的字号重建字体并重测文本宽度（见 PaintDanmaku）。
    emitted = NumberText(g_danmaku_font_size);
  } else if (name == "speed") {
    g_danmaku_speed = std::clamp(number, 0.5, 2.0);
    emitted = NumberText(g_danmaku_speed);
  } else if (name == "density") {
    g_danmaku_density = std::clamp(number, 0.2, 1.0);
    emitted = NumberText(g_danmaku_density);
  } else if (name == "scroll") {
    g_danmaku_scroll = value == "true";
    emitted = g_danmaku_scroll ? "true" : "false";
  } else if (name == "top") {
    g_danmaku_top = value == "true";
    emitted = g_danmaku_top ? "true" : "false";
  } else if (name == "bottom") {
    g_danmaku_bottom = value == "true";
    emitted = g_danmaku_bottom ? "true" : "false";
  } else {
    return;
  }
  // 关掉某一类弹幕时把已经在屏的那些一起撤掉，否则要等它们自己飞出去，
  // 看起来像「关不掉」。原地置为 played，重新开启时不会又冒出来。
  //
  // 只动「正在屏上」的那几条（item.live）。以前这里扫的是整集列表，把还没
  // 到时间的弹幕也一并写成 played —— 关掉再打开某个开关后，那一类弹幕在
  // 本集里就再也不出现了（看起来像「改完设置弹幕就没了」）。未来的条目必须
  // 原样留着，等播放到它们的时间点时照常出现。
  if (name == "scroll" || name == "top" || name == "bottom") {
    for (auto& item : g_danmaku_items) {
      if (!item.live) continue;
      const bool top = item.mode == 4 || item.mode == 5;
      const bool bottom = item.mode == 6;
      const bool hidden = (top && !g_danmaku_top) ||
                          (bottom && !g_danmaku_bottom) ||
                          (!top && !bottom && !g_danmaku_scroll);
      if (hidden) {
        item.live = false;
        item.played = true;
        item.lane = -1;
      }
    }
    // 撤掉了一整类弹幕，只把**它们占的**轨道还回来。不能整体归零：还在屏上的
    // 那些（比如关了顶弹幕、滚动弹幕照旧在飞）仍然占着自己的轨道，归零会让新
    // 条目立刻挤进同一条轨道，糊成一片，要等旧的那批飞出去才恢复。
    ResetDanmakuLaneFree();
    for (const DanmakuItem* pointer : g_danmaku_live) {
      const DanmakuItem& item = *pointer;
      if (item.lane < 0 ||
          item.lane >= static_cast<int>(g_danmaku_lane_free.size()))
        continue;
      double& slot = g_danmaku_lane_free[static_cast<size_t>(item.lane)];
      slot = std::max(slot, item.free_at);
    }
  }
  EmitSetting("yingji.danmaku." + name, emitted);
  g_danmaku_dirty = true;
  if (g_danmaku) InvalidateRect(g_danmaku, nullptr, FALSE);
}

/// 归一化 yes/no 与 true/false：命令行沿用的是 yes/no（同 mpv 参数风格），
/// 面板点击回传的是 true/false，热更新两种都可能收到。
bool LiveFlag(const std::string& value) {
  return value == "yes" || value == "true";
}

/// 设置的「热更新」入口：播放期间从设置页改了下面这些项，应用侧经 stdin 推
/// 过来，就地生效 —— 以前这些值只在起播时以命令行下发一次，播放中改设置页
/// 要等下一次播放才生效，两边的显示会各说各话。
///
/// 返回是否产生了实际变化。命令行解析与 stdin 热更新共用这一份实现，值域与
/// 副作用（重新贴合弹幕层、重绘、取消倒计时）不会分叉。
bool ApplyLiveOption(const std::string& name, const std::string& value) {
  if (name == "mova-danmaku-enabled") {
    const bool enabled = LiveFlag(value);
    if (enabled == g_danmaku_enabled) return false;
    g_danmaku_enabled = enabled;
    if (!enabled) {
      // 关掉时把已解析的弹幕一起丢掉，重开由应用侧重新拉一集再推。
      g_danmaku_items.clear();
      g_danmaku_loaded = false;
      g_danmaku_live.clear();
      g_danmaku_dropped = 0;
      ResetDanmakuLaneFree();
      if (g_danmaku) ShowWindow(g_danmaku, SW_HIDE);
    } else if (!g_danmaku_path.empty()) {
      PostMessageW(g_window, kDanmakuReload, 0, 0);
    }
    if (g_danmaku) InvalidateRect(g_danmaku, nullptr, FALSE);
    return true;
  }
  if (name.rfind("mova-danmaku-", 0) == 0) {
    const std::string key = name.substr(13);
    std::string normalized = value;
    if (key == "scroll" || key == "top" || key == "bottom") {
      normalized = LiveFlag(value) ? "true" : "false";
    }
    ApplyDanmakuSetting(key, normalized);
    return true;
  }
  if (name == "mova-auto-skip-segments") {
    const bool enabled = LiveFlag(value);
    if (enabled == g_auto_skip_segments) return false;
    g_auto_skip_segments = enabled;
    if (!enabled) {
      // 设置页里关掉自动跳过时，正在倒计时的那一段也要立刻停手。
      g_skip_index = -1;
      HideHint();
    }
    return true;
  }
  if (name == "mova-skip-delay-seconds") {
    g_skip_delay_seconds = std::clamp(
        std::strtod(value.c_str(), nullptr), 0.0, 30.0);
    return true;
  }
  // 快进步长与音量步长同属「播放器设置」，改了立刻生效才符合直觉：设置页把
  // 方向键快进调成 30 秒，回到播放器还按 10 秒跳就很别扭。
  if (name == "mova-seek-seconds") {
    g_seek_seconds = std::max(1.0, std::strtod(value.c_str(), nullptr));
    return true;
  }
  if (name == "mova-volume-step") {
    g_volume_step = std::max(1.0, std::strtod(value.c_str(), nullptr));
    return true;
  }
  // 外观里的「模糊程度」。原生没有高斯背板，能做的是把同一个数值换算成玻璃
  // 浓度（见 GlassLevel）：拖滑杆时播放器里的控件条、顶栏、菜单、提示会一起
  // 变透 / 变实，而不是「应用改了、播放器一动不动」。
  if (name == "mova-glass-blur") {
    g_glass_blur = std::clamp(std::strtod(value.c_str(), nullptr), 0.0, 40.0);
    if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
    if (g_top_bar) InvalidateRect(g_top_bar, nullptr, FALSE);
    if (g_hint) InvalidateRect(g_hint, nullptr, FALSE);
    if (g_panel && IsWindowVisible(g_panel)) {
      InvalidateRect(g_panel, nullptr, FALSE);
    }
    if (g_danmaku) InvalidateRect(g_danmaku, nullptr, FALSE);
    return true;
  }
  // 播放器偏好（倍速 / 音量 / 亮度 / 画面比例）：设置页里改了要立刻作用到正在
  // 播放的这一集，走的就是面板点击那条 mpv 属性写入路径，改完的提示与数值回填
  // 也一致。它们不是 mova- 前缀的参数，所以单列一组（见 IsLiveApplyName）。
  if (name == "speed" || name == "volume" || name == "brightness" ||
      name == "video-aspect-override") {
    MpvCommand("set", name.c_str(), value.c_str());
    return true;
  }
  return false;
}

/// 哪些参数既能在命令行里给（起播时的初始值），也能在播放期间经 stdin 热更新。
/// mova-danmaku-file 是例外：那条带的是临时文件路径，由 stdin 单独处理。
bool IsLiveSettingName(const std::string& name) {
  return name == "mova-auto-skip-segments" ||
         name == "mova-skip-delay-seconds" ||
         name == "mova-seek-seconds" || name == "mova-volume-step" ||
         name == "mova-glass-blur" ||
         (name.rfind("mova-danmaku-", 0) == 0 && name != "mova-danmaku-file");
}

/// stdin 的 MOVA_APPLY 还接受一组播放器偏好：它们在命令行里走 mpv 自己的参数
/// （--speed= / --volume= …），不是 mova- 前缀，所以不并进 IsLiveSettingName，
/// 免得起播时也被当成「热更新」处理一遍。
bool IsLiveApplyName(const std::string& name) {
  return IsLiveSettingName(name) || name == "speed" || name == "volume" ||
         name == "brightness" || name == "video-aspect-override";
}

void ShowDanmakuMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  std::wstring header;
  if (!g_danmaku_enabled) {
    header = L"已关闭";
  } else if (g_danmaku_loading) {
    header = L"获取中";
  } else if (g_danmaku_count > 0) {
    header = std::to_wstring(g_danmaku_count) + L" 条";
  } else {
    header = L"无数据";
  }
  items.push_back(PanelHeader(L'\xED93', L"弹幕", header));

  if (!g_danmaku_enabled) {
    items.push_back(PanelNote(kGlyphInfo, L"弹幕已在设置中关闭"));
    items.push_back(PanelNote(kGlyphInfo, L"开启后播放开始时会自动获取"));
  } else if (g_danmaku_loading) {
    items.push_back(PanelNote(kGlyphInfo, L"正在从弹幕服务获取…"));
    items.push_back(PanelNote(kGlyphInfo, L"获取完成后会自动叠加到画面上"));
  } else if (!g_danmaku_error.empty()) {
    items.push_back(PanelNote(kGlyphInfo, L"获取失败：" + g_danmaku_error));
    items.push_back(PanelNote(kGlyphInfo, L"可检查弹幕 API 地址与网络代理"));
  } else if (g_danmaku_count > 0) {
    items.push_back(PanelNote(
        kGlyphInfo, L"已加载 " + std::to_wstring(g_danmaku_count) + L" 条弹幕"));
    if (!g_danmaku_matched.empty()) {
      items.push_back(PanelNote(kGlyphInfo, L"匹配：" + g_danmaku_matched));
    }
    if (!g_danmaku_source.empty()) {
      items.push_back(PanelNote(kGlyphInfo, L"来自：" + g_danmaku_source));
    }
    const int area_percent = static_cast<int>(g_danmaku_area * 100);
    items.push_back(PanelNote(kGlyphInfo, L"显示区域：画面上部 " +
                                              std::to_wstring(area_percent) +
                                              L"%"));
  } else {
    items.push_back(PanelNote(kGlyphInfo, L"当前片源没有匹配的弹幕"));
    items.push_back(PanelNote(kGlyphInfo, L"弹幕库未收录该作品时不会有数据"));
  }

  // 显示设置：与应用「设置 → 弹幕显示」一一对应，即使当前没拉到数据也能调
  // （改完立刻生效，并回写应用偏好让下次起播沿用）。每项一行、点按前进一档，
  // 面板不会因为档位多而滚不到底。
  items.push_back(PanelHeader(kGlyphCrop, L"显示设置", DanmakuAreaLabel(g_danmaku_area)));
  const double area = g_danmaku_area;
  items.push_back(PanelOption(
      kGlyphCrop, L"显示区域",
      // 四档比其它项多一档，写全「25% / 50% / 75% / 100%」会被行宽截断成
      // 「10…」，所以省掉每个百分号后的空格。
      L"当前 " + DanmakuAreaLabel(area) + L" · 可选 25/50/75/100",
      "mova-danmaku-area", NextStep({0.25, 0.5, 0.75, 1.0}, area), "", false));
  const double opacity = g_danmaku_opacity;
  items.push_back(PanelOption(
      kGlyphSparkles, L"不透明度",
      L"当前 " + DanmakuOpacityLabel(opacity) + L" · 可选 淡 / 标准 / 清晰",
      "mova-danmaku-opacity", NextStep({0.55, 0.82, 1.0}, opacity), "", false));
  const double font = g_danmaku_font_size;
  items.push_back(PanelOption(
      kGlyphSubtitle, L"字号",
      L"当前 " + DanmakuFontLabel(font) + L" · 可选 小 / 标准 / 大",
      "mova-danmaku-font-size", NextStep({15.0, 18.0, 22.0}, font), "", false));
  const double speed = g_danmaku_speed;
  items.push_back(PanelOption(
      kGlyphGauge, L"滚动速度",
      L"当前 " + DanmakuSpeedLabel(speed) + L" · 可选 慢 / 标准 / 快",
      "mova-danmaku-speed", NextStep({0.7, 1.0, 1.5}, speed), "", false));
  const double density = g_danmaku_density;
  items.push_back(PanelOption(
      kGlyphEpisodes, L"同屏密度",
      L"当前 " + DanmakuDensityLabel(density) + L" · 可选 稀疏 / 标准 / 密集",
      "mova-danmaku-density", NextStep({0.35, 0.55, 0.8}, density), "", false));
  items.push_back(PanelOption(
      kGlyphCheckCircle, L"滚动弹幕",
      g_danmaku_scroll ? L"已开启 · 点按关闭" : L"已关闭 · 点按开启",
      "mova-danmaku-scroll", g_danmaku_scroll ? "false" : "true", "",
      g_danmaku_scroll));
  items.push_back(PanelOption(
      kGlyphCheckCircle, L"顶部弹幕",
      g_danmaku_top ? L"已开启 · 点按关闭" : L"已关闭 · 点按开启",
      "mova-danmaku-top", g_danmaku_top ? "false" : "true", "",
      g_danmaku_top));
  items.push_back(PanelOption(
      kGlyphCheckCircle, L"底部弹幕",
      g_danmaku_bottom ? L"已开启 · 点按关闭" : L"已关闭 · 点按开启",
      "mova-danmaku-bottom", g_danmaku_bottom ? "false" : "true", "",
      g_danmaku_bottom));
  OpenPanel(std::move(items), anchor, PanelMetrics{});
}

void ShowSegmentMenu(PanelAnchor anchor) {
  std::vector<PanelItem> items;
  const auto segments = SegmentsSnapshot();
  std::wstring badge;
  if (g_segments_loading) {
    badge = L"获取中";
  } else if (!segments.empty()) {
    badge = std::to_wstring(segments.size()) + L" 段";
  } else {
    badge = L"无数据";
  }
  items.push_back(PanelHeader(kGlyphScissors, L"片头片尾", badge));
  // 自动跳过做成开关行（而不是只读说明）：这个开关在应用设置页里也有，
  // 两边都能改、改完互相回写，就不会出现「设置页关了但播放器还在跳」。
  items.push_back(PanelOption(
      kGlyphCheckCircle, L"自动跳过",
      g_auto_skip_segments ? L"已开启 · 进入片段先提示再跳转，点按关闭"
                           : L"已关闭 · 点按开启",
      "mova-auto-skip-segments", g_auto_skip_segments ? "false" : "true", "",
      g_auto_skip_segments));
  const double position = std::max(0.0, g_position.load());
  items.push_back(PanelOption(
      kGlyphScissors, L"将当前位置设为片头结束",
      L"当前 " + ClockLabel(position) + L" · 手动设置优先于自动来源",
      "mova-segment-mark", "intro", "片头结束已保存", false));
  items.push_back(PanelOption(
      kGlyphBookmark, L"将当前位置设为片尾开始",
      L"当前 " + ClockLabel(position) + L" · 手动设置优先于自动来源",
      "mova-segment-mark", "outro", "片尾开始已保存", false));
  const bool manual_intro = std::any_of(
      segments.begin(), segments.end(), [](const SegmentItem& segment) {
        return segment.kind == SegmentKind::intro &&
               segment.provider == L"手动设置";
      });
  const bool manual_outro = std::any_of(
      segments.begin(), segments.end(), [](const SegmentItem& segment) {
        return segment.kind == SegmentKind::credits &&
               segment.provider == L"手动设置";
      });
  if (manual_intro) {
    items.push_back(PanelOption(kGlyphInfo, L"清除手动片头结束",
                                L"恢复使用自动来源", "mova-segment-clear",
                                "intro", "手动片头已清除", false));
  }
  if (manual_outro) {
    items.push_back(PanelOption(kGlyphInfo, L"清除手动片尾开始",
                                L"恢复使用自动来源", "mova-segment-clear",
                                "outro", "手动片尾已清除", false));
  }
  if (g_segments_loading) {
    items.push_back(PanelNote(kGlyphInfo, L"正在按设置里的来源获取…"));
  } else if (!g_segments_error.empty()) {
    items.push_back(PanelNote(kGlyphInfo, g_segments_error));
  }
  for (size_t index = 0; index < segments.size(); ++index) {
    const SegmentItem& segment = segments[index];
    const std::wstring kind = SegmentGlyphLabel(segment.kind);
    std::wstring detail;
    if (!segment.provider.empty()) {
      detail = L"来源 " + segment.provider + L" · ";
    }
    detail += L"点按跳到 " + ClockLabel(SegmentEnd(segment));
    PanelItem row = PanelOption(
        kGlyphScissors,
        kind + L" " + ClockLabel(segment.start) + L" – " +
            ClockLabel(SegmentEnd(segment)),
        detail, "mova-seek", std::to_string(index),
        Utf8(kind) + "已跳过", segment.consumed);
    // 已经处理过的段落置灰：留一行说明「这段跳过过了」，但不再重复触发。
    row.enabled = !segment.consumed;
    items.push_back(std::move(row));
  }
  if (segments.empty() && !g_segments_loading && g_segments_error.empty()) {
    items.push_back(PanelNote(kGlyphInfo, L"当前片源没有可用的片头片尾数据"));
    items.push_back(PanelNote(kGlyphInfo, L"可在设置里勾选更多来源"));
  }
  // 倒计时进行中：给出取消入口（提示浮层上写着的正是「打开菜单可取消」）。
  if (g_skip_index >= 0 && g_skip_index < static_cast<int>(segments.size()) &&
      !segments[static_cast<size_t>(g_skip_index)].consumed) {
    items.push_back(PanelOption(
        kGlyphInfo, L"本次不跳过",
        std::wstring(SegmentLabel(segments[static_cast<size_t>(g_skip_index)].kind)) +
            L" 即将在 " +
            std::to_wstring(std::max(
                0, static_cast<int>((g_skip_deadline > GetTickCount64()
                                         ? g_skip_deadline - GetTickCount64()
                                         : 0) /
                                    1000))) +
            L" 秒后跳过",
        "mova-skip-cancel", "", "本次不再跳过", false));
  }
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
    card.property = "mova-playlist-index";
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
// 进度条在设计稿里的 y。它现在是通屏的：0 → 窗口宽度。
constexpr float kSeekLineY = 19.0f;
// 控件条的「命中带」：铺满整条窗口的极淡底色（6/255 ≈ 2%，肉眼不可见）。
//
// 逐像素 alpha 下 alpha=0 的像素会点击穿透，而进度条拖动 / 悬停预览 / 按钮
// 点击都靠这个窗口收鼠标。以前这个作用由那道 10→124 的 scrim 承担，玩家看到的
// 「控件背景框」正是它；现在只留这一点点，命中行为不变、画面却干净。
constexpr int kDockHitBandAlpha = 6;
constexpr int kControlsBottomMargin = 20;
constexpr int kTopBarHeight = 58;
constexpr int kTopBarTopMargin = 14;

void PositionControls() {
  if (!g_window || !g_controls) return;
  RECT client{};
  GetClientRect(g_window, &client);
  UpdateUiScale(client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  const int client_width = static_cast<int>(client.right - client.left);
  // 进度条要「从屏幕最左边到最右边」完整展开，控件条窗口就得铺满整个客户区
  // 宽度（以前是居中、最宽 1040）。窗口本身已经没有底板，看不见的地方是真的
  // 透明，所以铺满不会变成一条横幅。
  const int width = std::max(240, client_width);
  const int height = Scaled(kControlsHeight);
  SetWindowPos(g_controls, HWND_TOP, origin.x,
               origin.y + client.bottom - height - Scaled(kControlsBottomMargin),
               width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  // 不再 SetWindowRgn：圆角改由离屏面的裁剪路径画出来（逐像素 alpha 下更平滑，
  // 也顺带让圆角外真正点击穿透）。窗口保持一个普通矩形，形状完全由 alpha 决定。
  InvalidateRect(g_controls, nullptr, FALSE);
  if (g_top_bar) {
    // The title bar belongs to the window edges, unlike the deliberately
    // compact transport dock.  Keeping it full-width means its two groups
    // remain anchored correctly while the window is resized.
    const int top_width = std::max(240, client_width - 32);
    const int top_height = Scaled(kTopBarHeight);
    SetWindowPos(g_top_bar, HWND_TOP, origin.x + Scaled(16),
                 origin.y + Scaled(kTopBarTopMargin), top_width, top_height,
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
  // 弹幕层覆盖整块视频区，随窗口尺寸/位置一起贴合。
  if (g_danmaku) PositionDanmaku();
}

// 控件条顶边的屏幕 y。底部工具的面板挂在它上方，而不是挂在被点击的像素上 ——
// 控件条本身的高度（缩放后）贴着点的位置展开会让面板盖住同一排的其它按钮。
int DockTopScreen() {
  if (!g_window) return 0;
  RECT client{};
  GetClientRect(g_window, &client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  return origin.y + static_cast<int>(client.bottom) - Scaled(kControlsHeight) -
         Scaled(kControlsBottomMargin);
}

// 控件条上某个控件的锚点：横向对准被点的那个按钮，纵向贴控件条顶边并向上展开。
//
// x 必须用控件条自己的窗口换算：控件条是居中的，比主窗口窄一圈（1280 宽的窗口里
// 它从 x=120 起），拿主窗口换算会把面板整体左移那半个内边距，鼠标点着 A 按钮、
// 面板却挂在 A 左边一段。
PanelAnchor DockAnchor(int client_x) {
  // client_x 是设计稿坐标系里的按钮位置；控件条窗口是缩放后的物理大小，
  // 换算屏幕坐标前先放大回去。
  POINT point{static_cast<LONG>(std::lround(client_x * UiScale())), 0};
  if (g_controls) ClientToScreen(g_controls, &point);
  PanelAnchor anchor;
  anchor.x = point.x;
  anchor.y = DockTopScreen();
  anchor.open_above = true;
  return anchor;
}

// 诊断开关：设 MOVA_TRACE_AUTOHIDE=<文件路径> 后，自动隐藏的每个 timer tick
// 与每次计时器刷新都会落一行。排查「该隐藏却不隐藏」时，看 idle 是否被周期
// 性清零，再对照 show 行的行号就能定位刷新来源。正常情况下完全不写盘。
FILE* AutoHideTrace() {
  static const std::wstring path = []() -> std::wstring {
    wchar_t buffer[MAX_PATH]{};
    if (GetEnvironmentVariableW(L"MOVA_TRACE_AUTOHIDE", buffer, MAX_PATH) > 0) {
      return std::wstring(buffer);
    }
    return std::wstring();
  }();
  if (path.empty()) return nullptr;
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"a") != 0 || !file) return nullptr;
  return file;
}

// 控件条与顶栏退场时要连命中测试一起退出。它们退场后仍压在画面上，鼠标移到
// 控件条区域会被这两个窗口接住：类光标（手型 / 箭头）会在 WM_SETCURSOR 里
// 立刻把光标重新点亮，透明区域上的点击也会落空。退场就彻底穿透，回来再恢复。
void SetOverlayHitTest(bool enabled) {
  const HWND overlays[] = {g_controls, g_top_bar};
  for (HWND overlay : overlays) {
    if (!overlay) continue;
    const LONG_PTR style = GetWindowLongPtrW(overlay, GWL_EXSTYLE);
    const LONG_PTR mask = static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
    const LONG_PTR next = enabled ? (style & ~mask) : (style | mask);
    if (next == style) continue;
    SetWindowLongPtrW(overlay, GWL_EXSTYLE, next);
    SetWindowPos(overlay, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
  }
}

void ShowControlsAt(int line) {
  if (FILE* trace = AutoHideTrace()) {
    std::fprintf(trace, "show line=%d tick=%llu idle=%llu\n", line,
                 GetTickCount64(), GetTickCount64() - g_last_interaction);
    std::fclose(trace);
  }
  g_last_interaction = GetTickCount64();
  SetOverlayHitTest(true);
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

void ApplyManualSegmentMark(const std::string& kind, double seconds) {
  const SegmentKind target =
      kind == "outro" ? SegmentKind::credits : SegmentKind::intro;
  std::lock_guard<std::mutex> guard(g_segments_mutex);
  g_segments.erase(
      std::remove_if(g_segments.begin(), g_segments.end(),
                     [target](const SegmentItem& segment) {
                       return segment.kind == target;
                     }),
      g_segments.end());
  if (seconds <= 0) return;
  SegmentItem manual;
  manual.kind = target;
  manual.start = target == SegmentKind::intro ? 0.0 : seconds;
  manual.end = target == SegmentKind::intro ? seconds : -1.0;
  manual.provider = L"手动设置";
  g_segments.insert(g_segments.begin(), std::move(manual));
}

void EmitSegmentMark(const std::string& kind, double seconds) {
  char text[160]{};
  const int length = std::snprintf(
      text, sizeof(text), "MOVA_SEGMENT_MARK=%s|%lld|%.3f\r\n",
      kind.c_str(), static_cast<long long>(g_playlist_position.load()), seconds);
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE && length > 0) {
    DWORD written = 0;
    WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
  }
}

void ConfigureGlassGraphics(Gdiplus::Graphics& graphics) {
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  // Match sRGB UI alpha compositing; gamma-correct white overlays look milky.
  graphics.SetCompositingQuality(Gdiplus::CompositingQualityAssumeLinear);
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
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
               bool mirror_x = false, bool shadow = false) {
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
  if (shadow) {
    // 控件条已经没有整块底板了：白色图标压在亮画面上会糊成一片。先在同一个
    // 位形下垫一层向下偏 1.2px 的暗影把图标托起来 —— 比恢复底板轻得多，也不会
    // 变成「一块背景」。
    // ⚠️ 不能拷贝 placement：`Gdiplus::Matrix` 的拷贝构造是私有的（C2248）。
    // 改成「先按位形放置，再在最外层整体下移」，结果与「位形 + 偏移」等价。
    Gdiplus::Matrix shift;
    shift.Translate(0.0f, kGlyphShadowOffset);
    graphics.MultiplyTransform(&placement);
    graphics.MultiplyTransform(&shift);
    Gdiplus::SolidBrush shade(Gdiplus::Color(
        static_cast<BYTE>(kGlyphShadowAlpha), 0, 0, 0));
    graphics.FillPath(&shade, &shape->path);
    graphics.SetTransform(&previous);
  }
  graphics.MultiplyTransform(&placement);
  Gdiplus::SolidBrush brush(color);
  graphics.FillPath(&brush, &shape->path);
  graphics.SetTransform(&previous);
}

// `size` is the Flutter Icon(size:) value; see DrawGlyph.
void DrawIconsaxGlyph(Gdiplus::Graphics& graphics, wchar_t codepoint, float x,
                      float y, float size, Gdiplus::Color color,
                      bool mirror_x = false, bool shadow = false) {
  DrawGlyph(graphics, codepoint, x, y, size, color, mirror_x, shadow);
}

void DrawPlayIcon(Gdiplus::Graphics& graphics, float x, float y,
                  float play_amount, float emphasis) {
  const wchar_t glyph = play_amount > 0.5f ? L'\xEE64' : L'\xEE44';
  DrawIconsaxGlyph(graphics, glyph, x, y, 25.0f + emphasis,
                   IconInk(emphasis), false, true);
}

void DrawSpeaker(Gdiplus::Graphics& graphics, float x, float y, bool muted,
                 float emphasis) {
  DrawIconsaxGlyph(graphics, muted ? L'\xF097' : L'\xF08F', x, y,
                   19.0f + emphasis, IconInk(emphasis), false, true);
}

// 上一集 / 下一集：字体里没有 Iconsax 的 next / previous（图标集在构建时被
// tree-shake 成 Dart 侧引用过的那些），所以沿用应用的做法——同一个箭头，
// 下一步用镜像，而不是硬塞一个语意不相干的图标。
void DrawSkipIcon(Gdiplus::Graphics& graphics, float x, float y, bool next,
                  float emphasis) {
  DrawIconsaxGlyph(graphics, L'\xE964', x, y, 22.0f + emphasis,
                   IconInk(emphasis), next, true);
}

void DrawSeekIcon(Gdiplus::Graphics& graphics, float x, float y, bool forward,
                  float emphasis) {
  DrawIconsaxGlyph(graphics, forward ? L'\xEC13' : L'\xE99F', x, y,
                   19.0f + emphasis, IconInk(emphasis), false, true);
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
  // 播放失败后的恢复入口（左下状态行变成的那颗胶囊，命中区见 HitControl）。
  // mpv 中断之后停在 idle，播放键的 cycle pause 是空操作 —— 没有这一项，单集
  // 影片就只能退出播放页重进，正是用户报的「播放失败就无法恢复」。
  kReplay,
};

constexpr size_t kControlCount = static_cast<size_t>(kReplay) + 1;

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

// 控件条上的文字（时间码 / 状态）：控件条已经没有底板，先垫一层暗影再画正文，
// 免得白色文字压在亮画面上糊掉。
void DrawDockLabel(Gdiplus::Graphics& graphics, const wchar_t* text,
                   Gdiplus::Font& font, const Gdiplus::PointF& at,
                   Gdiplus::Brush& brush) {
  Gdiplus::SolidBrush shade(
      Gdiplus::Color(static_cast<BYTE>(kGlyphShadowAlpha), 0, 0, 0));
  graphics.DrawString(text, -1, &font,
                      Gdiplus::PointF(at.X, at.Y + kGlyphShadowOffset), &shade);
  graphics.DrawString(text, -1, &font, at, &brush);
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
                   IconInk(emphasis), false, true);
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
  // 播放失败后的「重新播放」：占住左下时间码那一行。命中区比胶囊本身略宽，
  // 手抖也点得中。放在 y<34 之后，所以进度条（含拖动）那一带完全不受影响。
  if (g_playback_error.load() && x >= 20 && x <= 152) return kReplay;
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

void AddRoundedRectPath(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& rect,
                        float radius);
Gdiplus::RectF PixelSnapRect(const Gdiplus::RectF& rect, float inset);

// 控件条上的按钮底：一片**常驻**的液态玻璃圆片。
//
// 之前静止时不画（只有一个图标漂在画面上），悬停才冒出一个蓝圈 —— 拖「模糊
// 程度」的时候这一整排毫无反应，而且看着不像按钮。现在底片一直在，浓度跟着
// 外观里的模糊程度走（见 GlassDiscAlpha），悬停只是把它点亮。
void DrawHover(Gdiplus::Graphics& graphics, ControlId id, float x, float y,
               float size = 38) {
  const float amount = HoverAmount(id);
  const Gdiplus::RectF disc =
      PixelSnapRect(Gdiplus::RectF(x - size / 2, y - size / 2, size, size),
                    0.5f);
  Gdiplus::GraphicsPath disc_path;
  AddRoundedRectPath(disc_path, disc, disc.Width / 2.0f);
  FillGlassSurface(graphics, disc_path, disc, GlassDiscAlpha(false),
                   GlassDiscAlpha(true), true);
  StrokeGlassEdge(graphics, disc_path);
  if (amount <= 0.001f) return;
  // 悬停：只是把这层玻璃点亮（叠一层极淡的白），不换形状、不跳位。
  // 点亮色必须是白：以前这里叠的是 (110,168,255)，于是「鼠标一放上去就泛蓝」，
  // 而且进度条自己也用了同一支蓝 —— 全屏唯一的强调色不该是蓝。
  Gdiplus::SolidBrush lit(
      Gdiplus::Color(static_cast<BYTE>(amount * 22.0f), 255, 255, 255));
  graphics.FillPath(&lit, &disc_path);
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

Gdiplus::RectF PixelSnapRect(const Gdiplus::RectF& rect,
                             float inset = 0.5f) {
  return Gdiplus::RectF(rect.X + inset, rect.Y + inset,
                        std::max(0.0f, rect.Width - inset * 2.0f),
                        std::max(0.0f, rect.Height - inset * 2.0f));
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
  Gdiplus::SolidBrush muted{Gdiplus::Color(255, 226, 228, 234)};
  Gdiplus::SolidBrush quiet{Gdiplus::Color(255, 202, 205, 214)};
  Gdiplus::SolidBrush icon{Gdiplus::Color(236, 236, 238, 245)};
  Gdiplus::SolidBrush icon_bright{Gdiplus::Color(255, 255, 255, 255)};
};

float MeasurePanelText(Gdiplus::Graphics& graphics, const wchar_t* text,
                       const Gdiplus::Font& font) {
  // GenericTypographic = **紧贴墨迹**的度量：默认格式会按 GDI+ 的老习惯在左右
  // 各留约 1/6 em 的空白，量"100%"能多出小半行 —— 拿这个数去排「标题 + 值」
  // 这种左右分栏，多出来的空白就把标题挤掉了（提示的标题一度只剩一个字）。
  Gdiplus::StringFormat format(Gdiplus::StringFormat::GenericTypographic());
  format.SetFormatFlags(format.GetFormatFlags() |
                        Gdiplus::StringFormatFlagsNoWrap);
  // ⚠️ 同时还要把世界变换复位：面板 / 提示绘制时 graphics 已经按 UiScale 放大
  // 过，不定标的话量出来是物理像素，而所有布局常量都是设计稿坐标。
  Gdiplus::Matrix transform;
  graphics.GetTransform(&transform);
  graphics.ResetTransform();
  Gdiplus::RectF box;
  graphics.MeasureString(text, -1, &font, Gdiplus::PointF(0, 0), &format, &box);
  graphics.SetTransform(&transform);
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
      item.selected ? BYTE{22} : (hovered ? BYTE{14} : BYTE{4});
  Gdiplus::SolidBrush card_fill(Gdiplus::Color(fill_alpha, 255, 255, 255));
  graphics.FillPath(&card_fill, &card);
  const BYTE edge_alpha = item.selected ? BYTE{105}
                                        : (hovered ? BYTE{44} : BYTE{22});
  const Gdiplus::Color edge_color(edge_alpha, 255, 255, 255);
  Gdiplus::Pen card_edge(edge_color, item.selected ? 1.25f : 1.0f);
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
    const BYTE tile_alpha = item.selected ? BYTE{34} : BYTE{12};
    Gdiplus::SolidBrush tile_fill(Gdiplus::Color(tile_alpha, 255, 255, 255));
    graphics.FillPath(&tile_fill, &tile_path);
    if (item.icon != 0) {
      DrawGlyph(graphics, item.icon, tile_rect.X + tile / 2.0f,
                tile_rect.Y + tile / 2.0f, 17.0f,
                item.selected ? Gdiplus::Color(255, 255, 255, 255)
                              : Gdiplus::Color(236, 236, 238, 245),
                false, true);
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
    // +2：度量现在是紧贴墨迹的，盒宽正好等于墨迹宽会把最后一笔切掉半个像素。
    const float badge_width =
        MeasurePanelText(graphics, item.badge.c_str(), skin.chip) + 2.0f;
    const float badge_left = std::max(text_left, text_right - badge_width);
    DrawGlassText(graphics, item.badge.c_str(), skin.chip,
                  Gdiplus::RectF(badge_left, row.Y + 18.0f,
                                 text_right - badge_left, 20.0f),
                  format, skin.quiet);
    title_right = badge_left - 8.0f;
  }
  const bool single_line = item.detail.empty();
  const Gdiplus::RectF label_box(
      text_left, single_line ? row.Y + 19.0f : row.Y + 10.0f,
      std::max(0.0f, title_right - text_left), 18.0f);
  // 主标题走带暗影的那支：面板透出画面之后，白字全靠这层影子压住对比度。
  DrawGlassText(graphics, item.label.c_str(), skin.title, label_box, format,
                item.enabled ? static_cast<const Gdiplus::Brush&>(skin.ink)
                             : static_cast<const Gdiplus::Brush&>(skin.quiet));
  if (!single_line) {
    DrawGlassText(graphics, item.detail.c_str(), skin.detail,
                  Gdiplus::RectF(text_left, row.Y + 28.0f,
                                 std::max(0.0f, text_right - text_left),
                                 16.0f),
                  format, skin.muted);
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
  DrawGlassText(graphics, item.label.c_str(), skin.header,
                Gdiplus::RectF(row.X + 30.0f, row.Y,
                               std::max(0.0f, row.Width - 90.0f), row.Height),
                format, skin.ink);
  if (item.badge.empty()) return;
  const float text_width = MeasurePanelText(graphics, item.badge.c_str(), skin.chip);
  const float chip_width = text_width + 18.0f;
  const float chip_height = 20.0f;
  const Gdiplus::RectF chip(row.GetRight() - chip_width,
                            center_y - chip_height / 2.0f, chip_width,
                            chip_height);
  Gdiplus::GraphicsPath chip_path;
  AddRoundedRectPath(chip_path, chip, chip_height / 2.0f);
  const Gdiplus::Color chip_color(BYTE{18}, 255, 255, 255);
  Gdiplus::SolidBrush chip_fill(chip_color);
  graphics.FillPath(&chip_fill, &chip_path);
  Gdiplus::StringFormat centered;
  centered.SetAlignment(Gdiplus::StringAlignmentCenter);
  centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  DrawGlassText(graphics, item.badge.c_str(), skin.chip, chip, centered,
                skin.quiet);
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
  DrawGlassText(graphics, item.label.c_str(), skin.note,
                Gdiplus::RectF(row.X + 30.0f, row.Y,
                               std::max(0.0f, row.Width - 40.0f), row.Height),
                format, skin.muted);
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
      item.selected ? BYTE{22} : (hovered ? BYTE{14} : BYTE{4});
  Gdiplus::SolidBrush card_fill(Gdiplus::Color(fill_alpha, 255, 255, 255));
  graphics.FillPath(&card_fill, &card);
  const BYTE edge_alpha = item.selected ? BYTE{105}
                                        : (hovered ? BYTE{44} : BYTE{20});
  Gdiplus::Pen card_edge(Gdiplus::Color(edge_alpha, 255, 255, 255),
                         item.selected ? 1.25f : 1.0f);
  graphics.DrawPath(&card_edge, &card);

  const Gdiplus::RectF thumb(box.X + kEpisodeRowInset,
                             box.Y + kEpisodeRowInset, kEpisodeRowThumbWidth,
                             kEpisodeRowThumbHeight);
  Gdiplus::GraphicsPath thumb_path;
  AddRoundedRectPath(thumb_path, thumb, 9.0f);
  Gdiplus::SolidBrush placeholder(Gdiplus::Color(BYTE{22}, 255, 255, 255));
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
      Gdiplus::Pen value(Gdiplus::Color(255, 250, 250, 252), 2.6f);
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
  // 剧集标题也走带暗影的那支：面板透出画面后，白字靠这层影子才压得住。
  DrawGlassText(graphics, item.label.c_str(), skin.title,
                Gdiplus::RectF(text_left, box.Y + 24.0f, text_width, 18.0f),
                format,
                item.selected ? static_cast<const Gdiplus::Brush&>(skin.icon_bright)
                              : static_cast<const Gdiplus::Brush&>(skin.ink));  if (!item.detail.empty()) {
    DrawGlassText(graphics, item.detail.c_str(), skin.detail,
                  Gdiplus::RectF(text_left, box.Y + 48.0f, text_width, 15.0f),
                  format, skin.muted);
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
  BYTE* bits = nullptr;
  int width = 0;
  int height = 0;

  ~PanelSurface() { Destroy(); }

  // 参数不能叫 width/height：会遮蔽同名成员，项目按 /W4 /WX 编译，C4458
  // 会被当成错误（C2220）直接挂掉构建。
  bool Create(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    // 先释放上一块：弹幕层会随「显示区域」改档反复重建，直接覆盖 dc / bitmap /
    // target 会让旧的 DC 与位图再也回收不了（每调一档漏一块整屏位图）。
    Destroy();
    dc = CreateCompatibleDC(nullptr);
    if (!dc) return false;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* raw = nullptr;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &raw, nullptr, 0);
    if (!bitmap || !raw) return false;
    previous = SelectObject(dc, bitmap);
    bits = static_cast<BYTE*>(raw);
    width = w;
    height = h;
    Clear();
    target = new Gdiplus::Bitmap(width, height, width * 4,
                                 PixelFormat32bppPARGB, bits);
    return target->GetLastStatus() == Gdiplus::Ok;
  }

  // 复用同一块 DIB 画下一帧：省掉每帧 CreateDIBSection + new Bitmap。
  // 弹幕层每帧都要重画整屏，这块开销在 60fps 下非常可观。
  void Clear() {
    if (!bits || width <= 0 || height <= 0) return;
    memset(bits, 0,
           static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
  }

  bool Matches(int w, int h) const { return w == width && h == height; }

  void Destroy() {
    delete target;
    target = nullptr;
    bits = nullptr;
    width = 0;
    height = 0;
    if (dc && previous) SelectObject(dc, previous);
    previous = nullptr;
    if (bitmap) DeleteObject(bitmap);
    bitmap = nullptr;
    if (dc) DeleteDC(dc);
    dc = nullptr;
  }

  // 诊断用：把这块 DIB 直接导出成 BMP（32bpp，与内存里的 BGRA 顺序一致）。
  // 面板是 layered 窗口（UpdateLayeredWindow），像素只存在于这块位图里，抓屏
  // 抓到的是压在上面的别的窗口、PrintWindow 也拿不到 —— 想离线核对面板长什么
  // 样，只能从这里导出（见 MOVA_TRACE_PANEL）。
  bool SaveBmp(const std::wstring& path) const {
    if (!bits || width <= 0 || height <= 0) return false;
    BITMAPFILEHEADER file{};
    BITMAPINFOHEADER info{};
    info.biSize = sizeof(BITMAPINFOHEADER);
    info.biWidth = width;
    info.biHeight = -height;  // top-down，和 DIB 的内存顺序一致
    info.biPlanes = 1;
    info.biBitCount = 32;
    info.biCompression = BI_RGB;
    info.biSizeImage = static_cast<DWORD>(width) * 4u * static_cast<DWORD>(height);
    file.bfType = 0x4D42;
    file.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    file.bfSize = file.bfOffBits + info.biSizeImage;
    FILE* handle = nullptr;
    if (_wfopen_s(&handle, path.c_str(), L"wb") != 0 || !handle) return false;
    std::fwrite(&file, sizeof(file), 1, handle);
    std::fwrite(&info, sizeof(info), 1, handle);
    std::fwrite(bits, info.biSizeImage, 1, handle);
    std::fclose(handle);
    return true;
  }
};

// 诊断开关：设 MOVA_TRACE_PANEL=<目录> 后，面板每次重绘都把同一块位图备份成
// panel_NN.bmp（最多 `limit` 张）。正常运行时环境变量不存在，一次查询后直接返回。
// 背板那种整窗大图只留 2~3 张，不然光一个临时目录就能塞几百 MB。
const std::wstring& TraceDirectory() {
  static const std::wstring directory = []() -> std::wstring {
    wchar_t buffer[MAX_PATH]{};
    if (GetEnvironmentVariableW(L"MOVA_TRACE_PANEL", buffer, MAX_PATH) > 0) {
      return std::wstring(buffer);
    }
    return std::wstring();
  }();
  return directory;
}

/// 背板不是每次都能拿到（没出画面、抓不动、被独占挡住）。为什么没拿到要能事后查，
/// 不然现场只剩一句「提示这次没铺上背板」，只能靠猜。写到 backdrop.log。
void TraceGlassBackdropNote(const std::wstring& note) {
  const std::wstring& directory = TraceDirectory();
  if (directory.empty()) return;
  FILE* handle = nullptr;
  const std::wstring path = directory + L"\\backdrop.log";
  if (_wfopen_s(&handle, path.c_str(), L"a, ccs=UTF-8") != 0 || !handle) return;
  fwprintf(handle, L"%s\n", note.c_str());
  fclose(handle);
}

void TracePanelSurface(const PanelSurface& surface, const wchar_t* prefix,
                       int limit) {
  const std::wstring& directory = TraceDirectory();
  if (directory.empty()) return;
  static std::unordered_map<std::wstring, int> sequences;
  int& sequence = sequences[prefix];
  if (sequence >= limit) return;
  wchar_t name[48]{};
  swprintf_s(name, L"\\%s_%02d.bmp", prefix, sequence++);
  surface.SaveBmp(directory + name);
}

void TracePanelSurface(const PanelSurface& surface,
                       const wchar_t* prefix = L"panel") {
  TracePanelSurface(surface, prefix, 40);
}

// --------------------------------------------------------- 背板模糊的实现
//
// 一次采集三步：抓窗口 → 降到 1/kGlassDownscale → 三次盒式模糊＋轻微提饱和。
// 放大是一次性的：绘制时按物理像素 1:1 取子矩形，不必每次重绘都重采样一遍。

/// 三次盒式模糊（横向、纵向各一次算一遍，来回做三遍）。
///
/// `scratch` 与 `data` 同尺寸，当双缓冲用：每个方向都从一块读、往另一块写，滑窗就
/// 不会读到自己刚写下的模糊值。三次往返是偶数次，结果最终落回 `data`。
void BoxBlurPasses(BYTE* data, BYTE* scratch, int width, int height,
                   int radius) {
  if (radius < 1) return;
  const int window = radius * 2 + 1;
  const size_t stride = static_cast<size_t>(width) * 4u;
  BYTE* source = data;
  BYTE* target = scratch;
  for (int pass = 0; pass < kGlassBlurPasses; ++pass) {
    for (int y = 0; y < height; ++y) {
      const BYTE* row = source + static_cast<size_t>(y) * stride;
      BYTE* out_row = target + static_cast<size_t>(y) * stride;
      int sum[4] = {0, 0, 0, 0};
      for (int k = -radius; k <= radius; ++k) {
        const BYTE* pixel =
            row + static_cast<size_t>(k < 0 ? 0 : std::min(k, width - 1)) * 4u;
        for (int channel = 0; channel < 4; ++channel) sum[channel] += pixel[channel];
      }
      for (int x = 0; x < width; ++x) {
        for (int channel = 0; channel < 4; ++channel) {
          out_row[x * 4 + channel] = static_cast<BYTE>(sum[channel] / window);
        }
        const int add = x + radius + 1;
        const int sub = x - radius;
        const BYTE* added =
            row + static_cast<size_t>(add < width ? add : width - 1) * 4u;
        const BYTE* removed = row + static_cast<size_t>(sub > 0 ? sub : 0) * 4u;
        for (int channel = 0; channel < 4; ++channel) {
          sum[channel] += added[channel] - removed[channel];
        }
      }
    }
    std::swap(source, target);
    for (int x = 0; x < width; ++x) {
      const BYTE* column = source + static_cast<size_t>(x) * 4u;
      BYTE* out_column = target + static_cast<size_t>(x) * 4u;
      int sum[4] = {0, 0, 0, 0};
      for (int k = -radius; k <= radius; ++k) {
        const BYTE* pixel =
            column +
            static_cast<size_t>(k < 0 ? 0 : std::min(k, height - 1)) * stride;
        for (int channel = 0; channel < 4; ++channel) sum[channel] += pixel[channel];
      }
      for (int y = 0; y < height; ++y) {
        for (int channel = 0; channel < 4; ++channel) {
          out_column[static_cast<size_t>(y) * stride + channel] =
              static_cast<BYTE>(sum[channel] / window);
        }
        const int add = y + radius + 1;
        const int sub = y - radius;
        const BYTE* added = column +
                            static_cast<size_t>(add < height ? add : height - 1) *
                                stride;
        const BYTE* removed =
            column + static_cast<size_t>(sub > 0 ? sub : 0) * stride;
        for (int channel = 0; channel < 4; ++channel) {
          sum[channel] += added[channel] - removed[channel];
        }
      }
    }
    std::swap(source, target);
  }
  if (source != data) {
    memcpy(data, source, stride * static_cast<size_t>(height));
  }
}

/// 应用侧 `YingjiGlass.backdrop()` 里 colorMatrix 的等价物：只轻微增加饱和度，
/// 不再提亮。亮色视频本身已经接近白色，再提亮会让菜单和按钮一起过曝。
///
/// 顺手把 alpha 补成 255：GDI 不管 alpha 通道，PrintWindow / StretchBlt 留下的第
/// 4 字节是 0，而绘制端用的是预乘 ARGB —— 不补就是「画了等于没画」。
void ApplyGlassVibrancy(BYTE* data, size_t pixels) {
  constexpr double kSaturation = 1.35;
  for (size_t index = 0; index < pixels; ++index) {
    BYTE* pixel = data + index * 4u;
    const double luma =
        0.213 * pixel[2] + 0.715 * pixel[1] + 0.072 * pixel[0];
    for (int channel = 0; channel < 3; ++channel) {
      const double value = luma + (pixel[channel] - luma) * kSaturation;
      pixel[channel] = static_cast<BYTE>(std::clamp(value, 0.0, 255.0));
    }
    pixel[3] = 255;
  }
}

// QPC 时钟（定义在后面的帧循环一节）。背板各步的耗时要用它量：GetTickCount64 即使
// 开了 timeBeginPeriod(1) 也只以 15/16ms 的台阶推进，量单步会有半个节拍的误差。
double NowMs();

void ReleaseGlassBackdrop() {
  std::lock_guard<std::mutex> guard(g_backdrop.mutex);
  delete g_backdrop.video;
  g_backdrop.video = nullptr;
  for (GlassLayer& layer : g_backdrop.layers) {
    delete layer.reduced;
    layer.reduced = nullptr;
    delete layer.reduced_back;
    layer.reduced_back = nullptr;
    layer.scratch.clear();
    layer.ready = false;
  }
  g_backdrop.captured_at = 0;
}

bool CaptureGlassLayer(GlassLayer& layer, HWND window, HDC video,
                       const RECT& video_frame) {
  RECT frame{};
  if (!window || !IsWindowVisible(window) || !GetWindowRect(window, &frame)) {
    return false;
  }
  const int width = frame.right - frame.left;
  const int height = frame.bottom - frame.top;
  if (width < 8 || height < 8) return false;
  const int reduced_width = (width + kGlassDownscale - 1) / kGlassDownscale;
  const int reduced_height = (height + kGlassDownscale - 1) / kGlassDownscale;
  if (!layer.reduced_back) layer.reduced_back = new PanelSurface();
  if (!layer.reduced_back->Matches(reduced_width, reduced_height) &&
      !layer.reduced_back->Create(reduced_width, reduced_height)) {
    return false;
  }

  // 从播放器专属画面裁取区域。不能读桌面 DC：现代 DWM 合成下即使没有
  // CAPTUREBLT，也不能保证排除自己的浮层，反复采集会累积成白色残影。
  SetStretchBltMode(layer.reduced_back->dc, HALFTONE);
  SetBrushOrgEx(layer.reduced_back->dc, 0, 0, nullptr);
  if (!StretchBlt(layer.reduced_back->dc, 0, 0, reduced_width, reduced_height,
                  video, frame.left - video_frame.left,
                  frame.top - video_frame.top, width, height, SRCCOPY)) {
    return false;
  }
  // GDI batches writes to DIB sections. Complete them before CPU blur reads
  // and rewrites these bytes, otherwise a pending blit can overwrite the blur.
  GdiFlush();

  const size_t pixels = static_cast<size_t>(reduced_width) *
                        static_cast<size_t>(reduced_height);
  layer.scratch.resize(pixels * 4u);
  const double sigma_reduced =
      g_glass_blur.load() * 0.55 * static_cast<double>(UiScale()) /
      static_cast<double>(kGlassDownscale);
  const int radius = static_cast<int>(std::lround(sigma_reduced / 1.05));
  BoxBlurPasses(layer.reduced_back->bits, layer.scratch.data(), reduced_width,
                reduced_height, radius);

  // 黑色也是合法视频内容，必须发布；跳过黑帧会留下上一场景的亮色残影。
  ApplyGlassVibrancy(layer.reduced_back->bits, pixels);

  std::lock_guard<std::mutex> guard(g_backdrop.mutex);
  std::swap(layer.reduced, layer.reduced_back);
  layer.window = window;
  layer.source_width = width;
  layer.source_height = height;
  layer.origin_x = frame.left;
  layer.origin_y = frame.top;
  layer.ready = true;
  return true;
}

/// 重抓一帧背后的画面。`force` 为假时按 `kGlassBackdropRefreshMs` 节流（音量键
/// 连击那种高频调用就靠它挡住）。共用播放器源帧，只模糊可见玻璃区域。
bool UpdateGlassBackdrop(bool force) {
  if (!g_window) return false;
  const ULONGLONG now = GetTickCount64();
  if (!force && now - g_backdrop.attempted_at < kGlassBackdropRefreshMs) {
    return false;
  }
  g_backdrop.attempted_at = now;
  const double started = NowMs();
  RECT video_frame{};
  if (IsIconic(g_window) || !GetWindowRect(g_window, &video_frame)) return false;
  const int width = video_frame.right - video_frame.left;
  const int height = video_frame.bottom - video_frame.top;
  if (width < 1 || height < 1) return false;
  if (!g_backdrop.video) g_backdrop.video = new PanelSurface();
  if (!g_backdrop.video->Matches(width, height) &&
      !g_backdrop.video->Create(width, height)) return false;
  // PW_RENDERFULLCONTENT includes the D3D video content of this HWND only.
  if (!PrintWindow(g_window, g_backdrop.video->dc, 0x00000002)) return false;
  GdiFlush();
  TracePanelSurface(*g_backdrop.video, L"video-source", 3);
  const std::array<HWND, 4> windows = {g_controls, g_top_bar, g_panel, g_hint};
  bool updated = false;
  for (size_t index = 0; index < windows.size(); ++index) {
    updated = CaptureGlassLayer(g_backdrop.layers[index], windows[index],
                                g_backdrop.video->dc, video_frame) || updated;
  }
  if (!TraceDirectory().empty()) {
    wchar_t note[128]{};
    swprintf_s(note, L"regions %s  total %.1fms",
               updated ? L"ok" : L"skip", NowMs() - started);
    TraceGlassBackdropNote(note);
  }
  if (updated) g_backdrop.captured_at = now;
  return updated;
}

bool DrawGlassBackdrop(Gdiplus::Graphics& graphics,
                       const Gdiplus::GraphicsPath& path,
                       const Gdiplus::RectF& rect) {
  std::lock_guard<std::mutex> guard(g_backdrop.mutex);
  GlassLayer* selected = nullptr;
  for (GlassLayer& layer : g_backdrop.layers) {
    if (layer.ready && layer.reduced && layer.reduced->bits &&
        layer.origin_x == g_glass_window_origin.x &&
        layer.origin_y == g_glass_window_origin.y) {
      selected = &layer;
      break;
    }
  }
  if (!selected) return false;
  const float scale = UiScale();
  const float full_x = rect.X * scale;
  const float full_y = rect.Y * scale;
  const float full_width = rect.Width * scale;
  const float full_height = rect.Height * scale;
  const float full_x1 = full_x + full_width;
  const float full_y1 = full_y + full_height;
  // 窗口被挪到背板范围之外（挪窗、换分辨率）时宁可不画：画错位比不画更难看。
  if (full_width <= 0.0f || full_height <= 0.0f || full_x < 0.0f ||
      full_y < 0.0f ||
      full_x1 > static_cast<float>(selected->source_width) ||
      full_y1 > static_cast<float>(selected->source_height)) {
    return false;
  }
  const Gdiplus::GraphicsState state = graphics.Save();
  // 源是已经糊透的降采样图，放大用双线性即可 —— 它本来就是平滑的，不会放大出细节，
  // 也不会像最近邻那样露出块状边缘。
  graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBilinear);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  // FillPath applies antialias coverage; SetClip(path)+DrawImage cuts a binary
  // edge and leaves stair steps on the transparent layered-window surface.
  Gdiplus::TextureBrush backdrop(selected->reduced->target,
                                 Gdiplus::WrapModeTileFlipXY);
  backdrop.ScaleTransform(
      static_cast<float>(selected->source_width) /
          static_cast<float>(selected->reduced->width) / scale,
      static_cast<float>(selected->source_height) /
          static_cast<float>(selected->reduced->height) / scale);
  graphics.FillPath(&backdrop, &path);
  graphics.Restore(state);
  return true;
}

void PaintPanelContent(Gdiplus::Graphics& graphics, const PanelSkin& skin,
                       float width, float height) {
  const float body_width = width - kPanelShadowMargin * 2.0f;
  const float body_height = height - kPanelShadowMargin * 2.0f;
  const Gdiplus::RectF body_rect = PixelSnapRect(Gdiplus::RectF(
      static_cast<float>(kPanelShadowMargin),
      static_cast<float>(kPanelShadowMargin), body_width, body_height));
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
  // 面板底是液态玻璃：材质只有 FillGlassSurface 一处定义（基色 = 应用侧
  // YingjiGlass.frost，厚度 = 只沉底边），浓度跟着「设置 → 外观 → 模糊程度」走
  // （见 GlassPanelAlpha）。以前这里是一块 168~196 的海军蓝，用户看到的
  // 「二级菜单还是黑塑料」就是它。
  FillGlassSurface(graphics, body, body_rect, GlassPanelAlpha(false),
                   GlassPanelAlpha(true), true);
  StrokeGlassEdge(graphics, body);

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
    ConfigureGlassGraphics(graphics);
    graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
    // 窗口是缩放后的物理大小，面板内部的布局全是设计稿坐标：一次
    // ScaleTransform 换到设计坐标系，行高、缩略图、字号就都跟着窗口走。
    const float scale = UiScale();
    graphics.ScaleTransform(scale, scale);
    // 背板是按屏幕坐标抓的，绘制端要先把「设计稿矩形」映射回屏幕 —— 窗口自己的
    // 位置在这里读一次（每帧重设，挪窗之后立刻就对得上）。
    RECT rect{};
    if (GetWindowRect(window, &rect)) {
      g_glass_window_origin.x = rect.left;
      g_glass_window_origin.y = rect.top;
    }
    PaintPanelContent(graphics, skin, static_cast<float>(width) / scale,
                      static_cast<float>(height) / scale);
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
  TracePanelSurface(surface);
}

// 控件条的离屏面。
//
// ⚠️ 为什么不能用 `SetLayeredWindowAttributes(g_controls, 0, 232, LWA_ALPHA)`：
// 常量 alpha 只能把「一整块不透明内容」整体压到 91%，视频只透过 9% —— 于是控件
// 条必然是一块近黑板，无论里面画多淡的渐变都救不回来（用户看到的「控件背景」就是
// 它）。要「只显示控件」就必须有逐像素 alpha，也就是和面板同一条路：
// 32bpp 预乘 ARGB 的 DIB + `UpdateLayeredWindow(ULW_ALPHA)`。
//
// 一旦某个窗口用了 ULW，就**再也不能**对它调 SetLayeredWindowAttributes：两者
// 互斥，混用会让窗口内容直接失效。所以淡入淡出改由 `SourceConstantAlpha` 承担
// （PresentControlsSurface 里的 g_controls_alpha）。
PanelSurface* g_controls_surface = nullptr;

void PresentControlsSurface() {
  if (!g_controls || !g_controls_surface || !g_controls_surface->dc) return;
  POINT source{0, 0};
  SIZE size{static_cast<LONG>(g_controls_surface->width),
            static_cast<LONG>(g_controls_surface->height)};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = g_controls_alpha;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(g_controls, nullptr, nullptr, &size,
                      g_controls_surface->dc, &source, 0, &blend, ULW_ALPHA);
  // 与面板共用抓图通道（MOVA_TRACE_PANEL=<目录>）：控件条的内容只存在于这块
  // 离屏面里，抓屏/PrintWindow 都拿不到，只能从这里导出 BMP 离线核对。
  TracePanelSurface(*g_controls_surface, L"controls");
}

// 顶栏的离屏面。
//
// ⚠️ 顶栏原来走 `SetLayeredWindowAttributes(hwnd, kOverlayColorKey, 232,
// LWA_ALPHA | LWA_COLORKEY)`：键色只能表达「透明 / 不透明」两档，半透明的玻璃
// 圆片根本画不出来（非键色的像素一律按 232 常量 alpha 呈现）—— 右上角三个窗口
// 按钮就只能是一块实心深灰。改成和控件条、面板同一条路：32bpp 预乘 ARGB 的 DIB
// + `UpdateLayeredWindow(ULW_ALPHA)`，于是按钮圆片、网络胶囊都是真的半透明。
// ⚠️ 与控件条同理：用了 ULW 就不能再对这个窗口调 SetLayeredWindowAttributes，
// 淡入淡出改由 SourceConstantAlpha 承担。
PanelSurface* g_top_surface = nullptr;

void PresentTopBarSurface() {
  if (!g_top_bar || !g_top_surface || !g_top_surface->dc) return;
  POINT source{0, 0};
  SIZE size{static_cast<LONG>(g_top_surface->width),
            static_cast<LONG>(g_top_surface->height)};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = g_controls_alpha;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(g_top_bar, nullptr, nullptr, &size, g_top_surface->dc,
                      &source, 0, &blend, ULW_ALPHA);
  TracePanelSurface(*g_top_surface, L"topbar");
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
      const float scale = UiScale();
      const int next = PanelIndexAt(
          static_cast<int>(GET_X_LPARAM(lparam) / scale),
          static_cast<int>(GET_Y_LPARAM(lparam) / scale));
      if (g_panel_hover != next) {
        g_panel_hover = next;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const float scale = UiScale();
      const int index = PanelIndexAt(
          static_cast<int>(GET_X_LPARAM(lparam) / scale),
          static_cast<int>(GET_Y_LPARAM(lparam) / scale));
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
        } else if (item.enabled && item.property == "mova-playlist-index") {
          // 剧集面板选集：mpv 里只有当前一集，换集必须显式 loadfile。
          LoadPlaylistEntry(std::atoi(item.value.c_str()));
          if (!item.toast.empty()) ShowToast(item.toast);
          ShowWindow(window, SW_HIDE);
          SetFocus(g_window);
          ShowControls();
        } else if (item.enabled && item.property == "mova-seek") {
          // 片头片尾面板按段落跳转。走 SkipSegment 而不是直接 seek：那里会
          // 一并标记「这段处理过了」，免得自动跳过紧接着又跳一次。
          const int segment_index = std::atoi(item.value.c_str());
          if (segment_index >= 0) {
            SkipSegment(static_cast<size_t>(segment_index), false);
          }
          ShowWindow(window, SW_HIDE);
          SetFocus(g_window);
        } else if (item.enabled && item.property == "mova-skip-cancel") {
          // 取消这一次的自动跳过。面板原地刷新，用户能看到那一行已经变灰。
          if (g_skip_index >= 0) {
            std::lock_guard<std::mutex> guard(g_segments_mutex);
            if (g_skip_index < static_cast<int>(g_segments.size())) {
              g_segments[static_cast<size_t>(g_skip_index)].consumed = true;
            }
          }
          g_skip_index = -1;
          HideHint();
          ShowSegmentMenu(g_panel_anchor);
          ShowToast("本次不跳过");
        } else if (item.enabled && item.property == "mova-segment-mark") {
          const double seconds = std::max(0.0, g_position.load());
          ApplyManualSegmentMark(item.value, seconds);
          EmitSegmentMark(item.value, seconds);
          ShowToast(item.toast);
          ShowWindow(window, SW_HIDE);
          SetFocus(g_window);
        } else if (item.enabled && item.property == "mova-segment-clear") {
          ApplyManualSegmentMark(item.value, -1.0);
          EmitSegmentMark(item.value, -1.0);
          ShowToast(item.toast);
          ShowWindow(window, SW_HIDE);
          SetFocus(g_window);
        } else if (item.enabled &&
                   item.property == "mova-auto-skip-segments") {
          // 片头片尾的自动跳过开关：就地生效，并把新值回写应用偏好，
          // 设置页那边下次读到的就是这里改后的值。
          ApplyLiveOption(item.property, item.value);
          EmitSetting("yingji.segment.auto-skip",
                      g_auto_skip_segments ? "true" : "false");
          ShowSegmentMenu(g_panel_anchor);
        } else if (item.enabled &&
                   item.property.rfind("mova-danmaku-", 0) == 0) {
          // 弹幕显示设置：改完立刻生效，面板就地刷新（不关闭）方便连续调。
          ApplyDanmakuSetting(item.property.substr(13), item.value);
          ShowDanmakuMenu(g_panel_anchor);
        } else if (item.enabled && !item.property.empty()) {
          MpvCommand("set", item.property.c_str(), item.value.c_str());
          // 倍速 / 亮度 / 画面比例属「播放器偏好」：顺手回写应用偏好，下次起播
          // 按这里设的来（应用侧白名单只收这几个键，别的会被丢掉）。
          EmitPlayerPreference(item.property, item.value);
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
  // 度量与布局全部是设计稿坐标；窗口开成缩放后的物理大小，绘制端用
  // ScaleTransform 一次放大，滚动、命中继续留在设计坐标系，两套坐标不混算。
  const int shadow = Scaled(kPanelShadowMargin);
  const int panel_width = Scaled(g_panel_metrics.width);
  // 面板必须完整落在**播放器窗口**里：以前只夹屏幕工作区，窗口模式下菜单会探出
  // 播放器边界、压在桌面或别的窗口上 —— 用户看到的「资源面板显示在播放器外面」
  // 就是这个。边界取「播放器窗口 ∩ 屏幕工作区」，再各收一个阴影边距，保证连
  // 那圈柔影都不越界。
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  RECT frame{};
  if (g_window) GetWindowRect(g_window, &frame);
  if (frame.right <= frame.left) frame = work_area;
  const int limit_left =
      std::max(static_cast<int>(work_area.left), static_cast<int>(frame.left)) +
      shadow;
  const int limit_right =
      std::min(static_cast<int>(work_area.right), static_cast<int>(frame.right)) -
      shadow;
  const int limit_top =
      std::max(static_cast<int>(work_area.top), static_cast<int>(frame.top)) +
      shadow;
  const int limit_bottom =
      std::min(static_cast<int>(work_area.bottom),
               static_cast<int>(frame.bottom)) -
      shadow;
  // 高度先按窗口收：面板再高也不可能高过播放器窗口，否则夹不住、必然越界。
  // 还受锚点方向约束 —— 向上展开的面板最多只能长到锚点上方，否则它的底边会
  // 压住控件条本身（面板是夹在窗口里了，却盖住了唤出它的那排按钮）。
  const int anchor_room = anchor.open_above ? anchor.y - limit_top - 8
                                            : limit_bottom - anchor.y - 8;
  const int max_content = std::max(
      Scaled(120),
      std::min(limit_bottom - limit_top, std::max(Scaled(120), anchor_room)));
  const int content_design = std::min(
      g_panel_metrics.max_height,
      std::min(PanelContentHeight(),
               static_cast<int>(max_content / std::max(0.1f, UiScale()))));
  const int content = Scaled(content_design);
  g_panel_viewport_height = content_design - kPanelPadding * 2;
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
  // 横向与纵向都用前面算好的「窗口 ∩ 工作区」边界（已各收一个阴影边距）。
  const int left_limit = limit_left;
  const int right_limit = std::max(left_limit, limit_right - panel_width);
  const int body_x =
      std::clamp(anchor.x - panel_width / 2, left_limit, right_limit);
  const int top_limit = limit_top;
  const int bottom_limit = std::max(top_limit, limit_bottom - content);
  // 贴边方向由调用方给出：底部控件条向上展开，顶栏向下展开。两端各夹一次，
  // 保证面板连阴影一起完整落在播放器窗口内。
  int body_y = anchor.open_above ? anchor.y - content - 8 : anchor.y + 8;
  body_y = std::min(std::max(body_y, top_limit), bottom_limit);
  SetWindowPos(g_panel, HWND_TOP, body_x - shadow,
               body_y - shadow,
               panel_width + shadow * 2,
               content + shadow * 2,
               SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
  InvalidateRect(g_panel, nullptr, FALSE);
  SetForegroundWindow(g_panel);
  SetFocus(g_panel);
  HideHint();
}

// ------------------------------------------------------------ 提示浮层
//
// 调整音量 / 亮度 / 倍速 / 快进退时给一行实时反馈。
//
// 以前这些「实时提示」全部是转调 mpv 自己的 show-text，弹出来的是 mpv 的字体、
// mpv 的位置、mpv 的样式，和 Mova 的玻璃面板是两套语言。改成自绘之后，提示与
// 面板、控件条用同一支字体、同一组灰阶、同一圈内描边。

constexpr wchar_t kHintClass[] = L"MovaNativePlayerHint";
constexpr int kHintMaxTextWidth = 420;
// 提示是完整胶囊（圆角 = 高/2）：小面积的液态玻璃在应用里就是胶囊与圆片，
// 方角看起来像第三种皮肤。四周留一圈透明边给柔影 —— 应用侧的浮层靠背景模糊
// 从画面里浮起来，原生没有模糊，分离感只能靠这层影子。
constexpr int kHintMargin = 18;
// 「标题 + 行内值」这一行的分栏尺寸。**量宽与绘制必须共用这三个数**：量的时候替
// 它们预留，画的时候按它们扣减。
//
// ⚠️ 以前 `MeasureHint` 把 gap 算进值的槽宽、`PaintHint` 又从整行里再减一次 gap，
// 这个 14 被扣了两遍 —— 标题的盒子永远比它自己需要的窄 4~5px，于是 GDI+ 的省略号
// 修剪每次都生效，两字标题只剩一个字。
constexpr int kHintValueGap = 14;
// 紧贴墨迹量出来的宽度，右对齐到边缘时最后一笔会被切掉半个像素，给一点余量。
constexpr int kHintValueSlack = 2;
constexpr int kHintTitleSlack = 2;
constexpr ULONGLONG kToastHoldMilliseconds = 1500;
// 提示里的强调色：用在「要发生的事」上（跳过片头片尾的倒计时）。取应用侧
// `YingjiColors.success`（#8EE49C），和 App 里的成功态是同一个绿。
constexpr BYTE kHintAccentRed = 0x8E;
constexpr BYTE kHintAccentGreen = 0xE4;
constexpr BYTE kHintAccentBlue = 0x9C;

HintMode g_hint_mode = HintMode::Hidden;
std::wstring g_hint_text;
std::wstring g_hint_detail;
wchar_t g_hint_icon = 0;
float g_hint_fraction = -1.0f;
bool g_hint_accent = false;
// 行内那个值（"100%"）占的宽度，**设计稿单位**。
//
// ⚠️ 必须在 MeasureHint 里量一次就存下来，绘制端不能自己再量：MeasureHint 用的是
// 一块没有变换的 DC（量出来就是设计稿单位），而 PaintHint 拿到的 graphics 已经
// 按 UiScale 放大过 —— 同一句话在两处量出的数不一样，绘制端就会多扣一段宽度，
// 把标题挤到只剩一个字。
int g_hint_value_width = 0;
/// 提示标题的**紧贴**宽度（设计稿单位），同样由 MeasureHint 量一次。
///
/// 「标题 + 右对齐的值」这一行只能靠这个数来分栏：绘制端如果自己去量，量到的
/// 是另一套单位；而如果只是把剩下的宽度全给标题、再靠 GDI+ 的省略号修剪兜底，
/// 一旦盒子正好等于字宽，字符会被整块丢掉（`EllipsisCharacter` 连省略号都放不
/// 下时只画第一个字）。有了这个数就能提前判断"放得下"，放得下就干脆不修剪。
int g_hint_title_width = 0;
ULONGLONG g_hint_until = 0;
// 拖动音量条 / 进度条时，只在整数百分比变化时重建浮层，否则每个鼠标事件都会
// 重新排版一次。
int g_hint_seek_percent = -1;
int g_hint_volume_percent = -1;

Gdiplus::Font MakeHintFont() {
  return MakeInterfaceFont(13.0f, Gdiplus::FontStyleRegular);
}

/// 提示里的「明细」有两种用法，排版完全不同，必须先分清：
///
///   * **数值**（"42%"、"13:37 / 21:21"）—— 放标题行**右侧**、用主字号，
///     像 App 音量胶囊右边那个百分比（参考图）；
///   * **说明**（"打开菜单可取消"）—— 另起一行、小一号、灰一档。
///
/// 判据是长度而不是调用方多传一个参数：既要 MeasureHint 与 PaintHint 两处一致，
/// 又不想给十来处调用点都加一个开关。
bool HintDetailIsValue(const std::wstring& detail) {
  if (detail.empty() || detail.size() > 12) return false;
  return detail.find(L' ') == std::wstring::npos;
}

/// 用**与绘制端完全相同**的 `StringFormat` 量一行字要占多宽。
///
/// ⚠️ 不能直接用 `MeasurePanelText`：它走 `GenericTypographic`（紧贴墨迹），而 GDI+
/// 的**默认** `StringFormat` 会在左右各留约 1/6 em 的空白 —— 绘制端用的正是默认
/// 格式，于是「量到的 26」拿去画「实际要 30 的字」，差出半个字。拿这个数排
/// 「标题 + 值」左右分栏，标题就被挤掉一整块（`EllipsisCharacter` 放不下省略号时
/// 连字一起丢）。两处共用同一套格式，量多少就占多少。
float MeasureHintText(Gdiplus::Graphics& graphics, const wchar_t* text,
                      const Gdiplus::Font& font) {
  Gdiplus::StringFormat format;
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  Gdiplus::Matrix transform;
  graphics.GetTransform(&transform);
  graphics.ResetTransform();
  Gdiplus::RectF box;
  graphics.MeasureString(text, -1, &font, Gdiplus::PointF(0, 0), &format, &box);
  graphics.SetTransform(&transform);
  return box.Width;
}

void MeasureHint(const std::wstring& text, const std::wstring& detail,
                 wchar_t icon, bool progress, int* width, int* height) {
  const bool inline_value = HintDetailIsValue(detail);
  const bool second_row = !detail.empty() && !inline_value;
  HDC dc = CreateCompatibleDC(nullptr);
  int text_width = 0;
  int value_width = 0;
  {
    Gdiplus::Graphics graphics(dc);
    auto font = MakeHintFont();
    auto detail_font = MakeInterfaceFont(11.0f, Gdiplus::FontStyleRegular);
    g_hint_title_width =
        static_cast<int>(std::ceil(MeasureHintText(graphics, text.c_str(),
                                                   font)));
    if (inline_value) {
      g_hint_value_width = static_cast<int>(
          std::ceil(MeasureHintText(graphics, detail.c_str(), font)));
      // 值的槽 = 间距 + 值本身 + 余量。绘制端拿同一个槽去扣，gap 只算这一次。
      value_width = kHintValueGap + g_hint_value_width + kHintValueSlack;
    } else {
      g_hint_value_width = 0;
    }
    // 标题这一栏按**绘制端实际会用的宽度**预留（紧贴宽 + 余量），而不是按原始
    // 测量值：绘制端的盒子就是「紧贴宽 + 余量」，两边必须完全相等，否则
    // `tight <= title_width` 这个判断会差几像素、把标题交给省略号修剪。
    text_width = g_hint_title_width + kHintTitleSlack;
    if (second_row) {
      text_width =
          std::max(text_width, static_cast<int>(MeasureHintText(
                                   graphics, detail.c_str(), detail_font)));
    }
    text_width = std::min(text_width, kHintMaxTextWidth);
  }
  DeleteDC(dc);
  // 内容高：单行 44（胶囊），带说明 58；带进度线再加 16。
  const int content_left = 15 + (icon != 0 ? 26 : 0);
  const int body_height = second_row ? 58 : 44;
  *width = content_left + text_width + value_width + 15 + kHintMargin * 2;
  *height = body_height + (progress ? 16 : 0) + kHintMargin * 2;
  if (*width < 96 + kHintMargin * 2) *width = 96 + kHintMargin * 2;
}

void PaintHint(Gdiplus::Graphics& graphics, int width, int height, int icon,
               const std::wstring& text, const std::wstring& detail,
               float fraction, bool accent) {
  ConfigureGlassGraphics(graphics);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
  const float margin = static_cast<float>(kHintMargin);
  const Gdiplus::RectF body = PixelSnapRect(Gdiplus::RectF(
      margin, margin, static_cast<float>(width) - margin * 2.0f,
      static_cast<float>(height) - margin * 2.0f));
  const bool inline_value = HintDetailIsValue(detail);
  const bool second_row = !detail.empty() && !inline_value;
  const bool has_line = fraction >= 0.0f;
  const float body_radius = body.Height / 2.0f;
  Gdiplus::GraphicsPath path;
  AddRoundedRectPath(path, body, body_radius);
  for (int step = 5; step >= 1; --step) {
    const float spread = static_cast<float>(step) * 1.6f;
    Gdiplus::GraphicsPath ring;
    AddRoundedRectPath(ring,
                       Gdiplus::RectF(body.X - spread, body.Y - spread + 2.0f,
                                      body.Width + spread * 2.0f,
                                      body.Height + spread * 2.0f),
                       body_radius + spread);
    Gdiplus::SolidBrush shadow(Gdiplus::Color(BYTE{6}, 0, 0, 0));
    graphics.FillPath(&shadow, &ring);
  }
  // 与应用侧同一套材质：基色 frost、浓度跟着「外观 → 模糊程度」走、只沉底边的
  // 厚度渐变、白 .16 的内描边。以前这里是一块 168~196 的海军蓝近黑。
  // 提示压在画面正中间，是最需要背板模糊的一块：同样的浓度配上被糊过的画面才不是
  // 一块黑板（用户原话：「还有提示也是这样」）。
  FillGlassSurface(graphics, path, body, GlassPanelAlpha(false),
                   GlassPanelAlpha(true), true);
  StrokeGlassEdge(graphics, path);

  const PanelSkin skin;
  const float pad = 15.0f;
  const float text_left = body.X + pad + (icon != 0 ? 26.0f : 0.0f);
  const float text_width =
      std::max(0.0f, body.GetRight() - pad - text_left);
  // 竖排节奏：单行居中；带说明时标题在 11、说明在 29（行距 18）。
  const float title_y = second_row || has_line ? body.Y + 11.0f
                                               : body.Y + (body.Height - 18.0f) / 2.0f;
  Gdiplus::StringFormat format;
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  if (icon != 0) {
    const Gdiplus::Color ink =
        accent ? Gdiplus::Color(BYTE{250}, kHintAccentRed, kHintAccentGreen,
                                kHintAccentBlue)
               : Gdiplus::Color(BYTE{240}, 236, 238, 245);
    DrawGlyph(graphics, static_cast<wchar_t>(icon), body.X + pad + 8.0f,
              title_y + 9.0f, 16.0f, ink, true);
  }
  float title_width = text_width;
  if (inline_value) {
    // 值的槽宽来自 MeasureHint（设计稿单位，见 g_hint_value_width 的说明）。
    const float value_box =
        std::min(text_width, static_cast<float>(std::max(1, g_hint_value_width) +
                                                kHintValueSlack));
    format.SetAlignment(Gdiplus::StringAlignmentFar);
    DrawGlassText(graphics, detail.c_str(), skin.title,
                  Gdiplus::RectF(text_left + text_width - value_box, title_y,
                                 value_box, 18.0f),
                  format, skin.ink);
    format.SetAlignment(Gdiplus::StringAlignmentNear);
    title_width =
        std::max(0.0f, text_width - value_box - static_cast<float>(kHintValueGap));
  }
  // 标题的盒子取「MeasureHint 量出的紧贴宽 + 余量」—— 与 MeasureHint 预留的那一栏
  // **是同一个数**，所以放得下是必定成立的，可以把省略号修剪关掉让字形原样排出来。
  // 只有真的超长（被 kHintMaxTextWidth 截住）时才退回修剪。
  if (g_hint_title_width > 0) {
    const float tight =
        static_cast<float>(g_hint_title_width + kHintTitleSlack);
    if (tight <= title_width) {
      title_width = tight;
      format.SetTrimming(Gdiplus::StringTrimmingNone);
    }
  }
  DrawGlassText(graphics, text.c_str(), skin.title,
                Gdiplus::RectF(text_left, title_y, title_width, 18.0f), format,
                skin.ink);
  // 第二行说明还要靠修剪兜底，画完标题就还原。
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  if (second_row) {
    DrawGlassText(graphics, detail.c_str(), skin.detail,
                  Gdiplus::RectF(text_left, body.Y + 29.0f, text_width, 15.0f),
                  format, skin.muted, BYTE{124});
  }
  if (!has_line) return;
  // 进度线：值与轨道都是**同一条白**的两档 —— 以前值是 (110,168,255) 的蓝，
  // 整屏唯一的强调色不该是蓝。强调态（跳过倒计时）换成应用侧的成功绿。
  const float line_left = body.X + pad;
  const float line_width = std::max(40.0f, body.Width - pad * 2.0f);
  const float line_y = body.GetBottom() - 11.0f;
  Gdiplus::Pen track(Gdiplus::Color(BYTE{96}, 255, 255, 255), 4.0f);
  ConfigureControlPen(track);
  graphics.DrawLine(&track, line_left, line_y, line_left + line_width, line_y);
  const Gdiplus::Color value_ink =
      accent ? Gdiplus::Color(255, kHintAccentRed, kHintAccentGreen,
                              kHintAccentBlue)
             : Gdiplus::Color(255, 250, 250, 252);
  Gdiplus::Pen value(value_ink, 4.0f);
  ConfigureControlPen(value);
  graphics.DrawLine(&value, line_left, line_y,
                    line_left + line_width * std::clamp(fraction, 0.0f, 1.0f),
                    line_y);
}

void HideHint() {
  g_hint_mode = HintMode::Hidden;
  g_hint_fraction = -1.0f;
  g_hint_accent = false;
  if (g_hint) ShowWindow(g_hint, SW_HIDE);
}

void ShowHint(const std::wstring& text, const std::wstring& detail,
              wchar_t icon, HintMode mode, float fraction, int anchor_x,
              bool accent) {
  if (!g_hint || text.empty() || mode == HintMode::Hidden) {
    HideHint();
    return;
  }
  int width = 0;
  int height = 0;
  MeasureHint(text, detail, icon, fraction >= 0.0f, &width, &height);
  // MeasureHint 给的是设计稿尺寸，窗口与位置都按缩放后的物理大小摆放。
  width = Scaled(width);
  height = Scaled(height);
  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  // 提示挂在**播放器窗口**的水平中心，而不是整个屏幕的中心：窗口模式下播放器
  // 只占桌面一块，按屏幕居中会让提示飘到窗口外面去。再与屏幕工作区求一次交，
  // 全屏时两者等价。
  RECT frame{};
  if (g_window) GetWindowRect(g_window, &frame);
  if (frame.right <= frame.left) frame = work_area;
  const int limit_left =
      std::max(static_cast<int>(work_area.left), static_cast<int>(frame.left)) + 8;
  const int limit_right =
      std::min(static_cast<int>(work_area.right), static_cast<int>(frame.right)) -
      8;
  const int dock_top = DockTopScreen();
  int x = limit_left + (limit_right - limit_left - width) / 2;
  x = std::clamp(x, limit_left, std::max(limit_left, limit_right - width));
  const int gap = 16;
  int y = dock_top - height - gap;
  y = std::max(y, std::max(static_cast<int>(work_area.top),
                           static_cast<int>(frame.top)) + 8);
  g_hint_mode = mode;
  g_hint_text = text;
  g_hint_detail = detail;
  g_hint_icon = icon;
  g_hint_fraction = fraction;
  g_hint_accent = accent;
  g_hint_until = GetTickCount64() + kToastHoldMilliseconds;
  SetWindowPos(g_hint, HWND_TOP, x, y, width, height,
               SWP_SHOWWINDOW | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  InvalidateRect(g_hint, nullptr, FALSE);
}

// ===================== 弹幕叠加层 =====================
// 应用侧拉取弹幕后写入临时文本文件，原生侧读入并在此分层窗口上按播放时间渲染。
// 文件每行：<time秒>\t<mode>\t<color>\t<base64文本>
//   mode: 1 滚动, 4/5 顶部, 6 底部；color: 0xRRGGBB, -1 表示默认白。
// 高精度毫秒读数（QPC）。定义在本文件下方（见 NowMs）。
// 弹幕的动画时钟、位置插值与每帧的 dt 都靠它 —— 这三处都要亚毫秒精度，
// 用 GetTickCount64（粒度 15.6ms）会把动画量化成 15.6ms 一跳的台阶。
double NowMs();

// 弹幕用的播放位置：在 mpv 最后一次回报的位置上按墙钟往前推。
//
// mpv 的 time-pos 属性是按它自己的节拍回报的（实测几十毫秒一次），直接拿它判断
// 「这条弹幕到点了吗」，会让同一批弹幕在同一个上报点上一起冒出来，出现「一阵
// 一阵」的观感。按墙钟插值之后，到点误差只剩一帧。
double DanmakuPlayhead() {
  const double base = g_position.load();
  if (g_paused.load() || g_buffering.load()) return base;
  const double tick = g_position_tick.load();
  if (tick <= 0.0) return base;
  const double elapsed = (NowMs() - tick) / 1000.0;
  // 上报停住时（缓冲 / 卡顿）不要一路推下去，最多补半秒。
  return base + std::clamp(elapsed, 0.0, 0.5) * g_speed.load();
}
// 弹幕动画自己的时间轴：暂停 / 缓冲时停走，所以暂停画面里的弹幕是静止的
// （以前用墙钟，暂停后弹幕还在飘，位置和画面就对不上了）。它同时决定了「这一帧
// 需不需要重绘」—— 停走的时候没有东西在动，不必每帧把整层 memset 再合成一遍。
double DanmakuAnimationClock() {
  // 时间源必须是高精度计数器（QPC），不能用 GetTickCount64：后者的粒度是系统
  // 时钟节拍（默认 15.6ms），而弹幕位置正是 (时钟 - 出现时刻) × 速度。以
  // 240px/s 为例，15.6ms 一跳就是每步 3.75px，可帧间隔只有 16.3ms —— 绝大多数
  // 帧算出来「一点没动」，偶尔又跳两倍，滚动起来就是「一顿一顿」。
  // 换成 QPC 之后步长与帧间隔一致，位置误差只剩亚像素。
  const double tick = NowMs();
  if (g_danmaku_clock_tick == 0.0) {
    g_danmaku_clock_tick = tick;
    return g_danmaku_clock;
  }
  const double delta = (tick - g_danmaku_clock_tick) / 1000.0;
  g_danmaku_clock_tick = tick;
  // 播放中才推进：暂停与缓冲时画面本来就不动，弹幕也该跟着停。
  if (!g_paused.load() && !g_buffering.load()) {
    g_danmaku_clock += std::clamp(delta, 0.0, 0.5);
  }
  return g_danmaku_clock;
}

// 高精度毫秒读数，只用于弹幕帧耗时的量化（见 MOVA_TRACE_DANMAKU）。
// GetTickCount64 的粒度是 15.6ms，量不出「一帧画了几毫秒」。
double NowMs() {
  static const double k_frequency = [] {
    LARGE_INTEGER value{};
    QueryPerformanceFrequency(&value);
    return static_cast<double>(value.QuadPart);
  }();
  LARGE_INTEGER counter{};
  QueryPerformanceCounter(&counter);
  return static_cast<double>(counter.QuadPart) * 1000.0 / k_frequency;
}

// 采一次合成器时序（见 g_dwm_compose_ms）。跟着 NowMs 放，是因为它要用
// NowMs 而两者同属一个匿名命名空间。
void SampleCompositionTiming() {
  DWM_TIMING_INFO timing{};
  timing.cbSize = sizeof(timing);
  if (FAILED(DwmGetCompositionTimingInfo(nullptr, &timing))) return;
  g_dwm_refresh_ms = QpcToMs(timing.qpcRefreshPeriod);
  g_dwm_compose_ms = QpcToMs(timing.rateCompose.uiDenominator);
}

// ---- 帧节拍：让弹幕层的「每一帧在屏停留多久」对齐合成器的整数拍 ----
//
// 见 docs/specs/2026-09-22-danmaku-frame-pacing.md。要点：位置算得准（QPC）
// 不等于像素投到屏幕上的时机均匀；只要帧节拍与刷新率不是整数比，位移步长就会
// 周期性变长变短。用户选定 1:1（满刷新）。

// 面板一个刷新周期的毫秒数。先问 DWM（`qpcRefreshPeriod` 是合成器真正在用的
// 值，比分辩率标称值可信：可变刷新率 / 驱动覆盖下两者会不一致），拿不到再退回
// EnumDisplaySettings 的 dmDisplayFrequency，都没有就返回 0（调用方退回旧路径）。
double QueryRefreshPeriodMs() {
  DWM_TIMING_INFO timing{};
  timing.cbSize = sizeof(timing);
  if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &timing)) &&
      timing.qpcRefreshPeriod > 0) {
    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    if (frequency.QuadPart > 0) {
      const double period = static_cast<double>(timing.qpcRefreshPeriod) *
                            1000.0 / static_cast<double>(frequency.QuadPart);
      // 1~1000Hz 之外的值当异常（远程桌面 / 驱动没上报），宁可退回标称值。
      if (period >= 1.0 && period <= 1000.0) return period;
    }
  }
  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &mode) &&
      mode.dmDisplayFrequency > 1) {
    return 1000.0 / static_cast<double>(mode.dmDisplayFrequency);
  }
  return 0.0;
}

// 播放器窗口当前在哪块屏上、那块屏自己报多少 Hz。
//
// QueryRefreshPeriodMs 问的是 **主** 显示器（DwmGetCompositionTimingInfo(NULL)
// 与 EnumDisplaySettings(NULL) 都只看主屏）。窗口被拖到另一块屏上时，「按哪块
// 面板的周期分频」就会错：拿 170Hz 的节拍去驱动一块 144Hz 的屏，每一帧停留的
// 拍数又变成非整数，症状和「定时器没对齐刷新率」一模一样。所以把这块信息一起
// 报出来，免得在错误的刷新率上做推理。
void FormatPlayerMonitor(char* text, size_t size) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  const HMONITOR monitor = MonitorFromWindow(
      g_window ? g_window : nullptr, MONITOR_DEFAULTTONEAREST);
  if (!monitor || !GetMonitorInfoW(monitor, &info)) {
    std::snprintf(text, size, "monitor=? hz=0 primary=?");
    return;
  }
  char name[64]{};
  WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, name, sizeof(name),
                      nullptr, nullptr);
  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  const bool mode_ok =
      EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode);
  std::snprintf(text, size, "monitor=%s hz=%u primary=%s", name,
                mode_ok ? mode.dmDisplayFrequency : 0u,
                (info.dwFlags & MONITORINFOF_PRIMARY) ? "yes" : "no");
}

// 每几个刷新周期出一帧。
//
// 目标是把每帧的产出周期取成**面板刷新周期的整数倍**，这样每帧在屏停留的拍数
// 恒定、位移步长均匀。上界取 90Hz：再往上（170Hz 的 1:1）要求一轮循环里 flush
// 之外的工作量小于一个刷新周期，本机实测 `o ≈ 6.6ms > T = 5.882ms` 做不到
// （见 docs/specs/2026-09-22-danmaku-frame-pacing.md），硬锁只会得到更抖的结果。
// 所以 60Hz:1x、120/144/165/170Hz:2x、240Hz:3x。分频必须**固定**：运行中改分频
// 等于中途换停留时长，本身就会顿一下。
int FrameDivisorFor(double refresh_hz) {
  if (!(refresh_hz > 0.0)) return 0;
  const double divisor = std::ceil(refresh_hz / 90.0);
  return static_cast<int>(divisor < 1.0 ? 1.0 : divisor);
}

// 拆掉当前的高精度节拍定时器。
void DisarmPacingTimer() {
  if (g_pacing_timer) {
    CloseHandle(g_pacing_timer);
    g_pacing_timer = nullptr;
  }
  g_pacing_period_ms = 0.0;
  g_pacing_tick = 0;
}

// 按**绝对日程**排下一次 tick。
//
// 不用 `SetWaitableTimer` 的 `lPeriod`（单位是整毫秒，11.76ms 只能喂 12/11 交替
// → 又造一个错拍），而是每次都用 100ns 精度的相对到期时间重排；而且目标时刻一律
// 从锚点算（`anchor + tick × period`）——用「从现在起一个 period」会把每次的唤醒
// 延迟逐轮累加成漂移。
void ArmNextPacingTick() {
  if (!g_pacing_timer || !(g_pacing_period_ms > 0.0)) return;
  const double target_ms = g_pacing_anchor_ms + g_pacing_tick * g_pacing_period_ms;
  double delay_ms = target_ms - NowMs();
  if (delay_ms < 0.05) {
    // 迟到了就立刻到点。但**只有真的漏了不止半拍**才挪锚点：单纯「刚好压线」也挪，
    // 等于把这一拍的迟到量固化进后续所有日程，实测周期会变成 11.83ms 而不是
    // 11.764ms（+0.6%），相位于是缓慢滑过拍边界、部分帧掉到 3 拍。
    // 不挪的话，下一次的 delay 会自动少一截，把这点迟到补回来。
    if (delay_ms < -g_pacing_period_ms * 0.5) {
      // 系统卡顿导致真的漏拍：把日程整体挪到当前这一拍，不补一串已经过去的 tick。
      g_pacing_anchor_ms = NowMs() - g_pacing_tick * g_pacing_period_ms;
    }
    delay_ms = 0.05;
  }
  LARGE_INTEGER due{};
  due.QuadPart = -static_cast<LONGLONG>(delay_ms * 10000.0);  // 负 = 相对时间
  SetWaitableTimer(g_pacing_timer, &due, 0, nullptr, nullptr, FALSE);
}

// 建（或重建）节拍定时器，并把相位对到当前合成边界上。
void RebuildPacingTimer() {
  DisarmPacingTimer();
  if (g_frame_divisor <= 0 || !(g_refresh_period_ms > 0.0)) return;
  // 高精度模式（Win10 1803+）必须有：没有它定时器精度只有系统时钟节拍
  // （~15.6ms），11.76ms 的周期毫无意义。拿不到就退回普通定时器，至少不比原路径差。
  g_pacing_timer = CreateWaitableTimerExW(
      nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  if (!g_pacing_timer) {
    g_pacing_timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
  }
  if (!g_pacing_timer) return;
  g_pacing_period_ms = g_frame_divisor * g_refresh_period_ms;
  // 对相位：`DwmFlush` 返回时刚过一个合成边界，从这里起算，之后每一帧都落在
  // 「边界之后一点点」，于是会在下一个边界被合成，正好停 divisor 拍。
  DwmFlush();
  g_pacing_anchor_ms = NowMs();
  g_pacing_tick = 1;
  ArmNextPacingTick();
}

// 重算帧节拍。启动时与 WM_DISPLAYCHANGE（换显示器 / 改刷新率 / 开关全屏）时调。
void RefreshFramePacing() {
  g_refresh_period_ms = QueryRefreshPeriodMs();
  g_frame_divisor =
      g_refresh_period_ms > 0.0
          ? FrameDivisorFor(1000.0 / g_refresh_period_ms)
          : 0;
  // 拿不到刷新周期就退回定时器路径（g_frame_divisor == 0 / 定时器建不出来），
  // 行为与本改动之前一致 —— 老系统 / 远程桌面下不会变得更差。
  RebuildPacingTimer();
  char monitor[160]{};
  FormatPlayerMonitor(monitor, sizeof(monitor));
  char text[320]{};
  const int length = std::snprintf(
      text, sizeof(text),
      "MOVA_FRAME_PACING=refresh=%.3fms divisor=%d hz=%.1f period=%.3fms %s|\r\n",
      g_refresh_period_ms, g_frame_divisor,
      g_refresh_period_ms > 0.0 ? 1000.0 / g_refresh_period_ms : 0.0,
      g_pacing_period_ms, monitor);
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output && output != INVALID_HANDLE_VALUE && length > 0) {
    DWORD written = 0;
    WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
  }
}

// 只有画面真的在动、而且窗口露着的时候才需要按刷新率走。
//
// 暂停 / 缓冲时弹幕动画时钟本来就不推进（见 DanmakuAnimationClock），没有东西
// 需要按 170Hz 重新推进；窗口最小化 / 不可见时同理。这两种情况继续 170Hz 唤醒
// 只是白烧 CPU 与电，交回 16ms 定时器就够（与改动前的行为一致）。
bool FramePacingWanted() {
  if (g_frame_divisor <= 0) return false;
  if (!g_window || !IsWindowVisible(g_window) || IsIconic(g_window)) return false;
  if (g_paused.load() || g_buffering.load()) return false;
  return true;
}

static int DanmakuBase64Value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

static std::string DanmakuBase64Decode(const std::string& in) {
  std::string out;
  int buf = 0, bits = 0;
  for (const char c : in) {
    const int v = DanmakuBase64Value(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<char>((buf >> bits) & 0xFF));
    }
  }
  return out;
}

// 按时间找到第一个不早于 seconds 的条目（条目在 LoadDanmaku 里已排好序）。
size_t DanmakuLowerBound(double seconds) {
  size_t low = 0, high = g_danmaku_items.size();
  while (low < high) {
    const size_t mid = low + (high - low) / 2;
    if (g_danmaku_items[mid].time < seconds) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

// 把已解析的条目整体换上去。调用方只在主线程（窗口消息）里用，所以不必加锁。
void AdoptDanmakuItems(std::vector<DanmakuItem> items) {
  g_danmaku_items = std::move(items);
  // 按时间排序：每帧只需要从光标往前推，不必整集扫一遍；跳转后也能二分定位。
  std::stable_sort(g_danmaku_items.begin(), g_danmaku_items.end(),
                   [](const DanmakuItem& left, const DanmakuItem& right) {
                     return left.time < right.time;
                   });
  g_danmaku_live.clear();
  g_danmaku_cursor = 0;
  g_danmaku_last_position = -1.0;
  g_danmaku_dropped = 0;
  ResetDanmakuLaneFree();
  g_danmaku_loaded = !g_danmaku_items.empty();
}

void LoadDanmaku() {
  g_danmaku_items.clear();
  g_danmaku_live.clear();
  g_danmaku_cursor = 0;
  g_danmaku_last_position = -1.0;
  g_danmaku_dropped = 0;
  ResetDanmakuLaneFree();
  g_danmaku_loaded = false;
  if (g_danmaku_path.empty()) return;
  std::ifstream file(g_danmaku_path);
  if (!file) return;
  std::vector<DanmakuItem> items;
  std::string line;
  while (std::getline(file, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
      line.pop_back();
    if (line.empty()) continue;
    const size_t t1 = line.find('\t');
    if (t1 == std::string::npos) continue;
    const size_t t2 = line.find('\t', t1 + 1);
    if (t2 == std::string::npos) continue;
    const size_t t3 = line.find('\t', t2 + 1);
    if (t3 == std::string::npos) continue;
    DanmakuItem item;
    item.time = std::strtod(line.c_str(), nullptr);
    item.mode = std::atoi(line.c_str() + t1 + 1);
    item.color = std::atoi(line.c_str() + t2 + 1);
    const std::string utf8 = DanmakuBase64Decode(line.substr(t3 + 1));
    item.text = Wide(utf8);
    items.push_back(std::move(item));
  }
  AdoptDanmakuItems(std::move(items));
}

// 把一条弹幕的文字（连同阴影）栅格化成一张刚好包住它的小位图，只做一次。
// 返回 false 表示这一帧的预算已经用完，调用方下一帧再试。
bool EnsureDanmakuTexture(DanmakuItem& item, Gdiplus::Graphics& measure,
                          const Gdiplus::Font& font, float font_size,
                          const Gdiplus::StringFormat& format, double deadline) {
  if (item.texture) return true;
  if (NowMs() >= deadline) return false;
  Gdiplus::RectF bounds;
  measure.MeasureString(item.text.c_str(), -1, &font, Gdiplus::PointF(0, 0),
                        &format, &bounds);
  item.text_width = bounds.Width;
  item.font_size = font_size;
  const int box_width =
      static_cast<int>(std::ceil(std::max(1.0f, bounds.Width))) + 1 +
      kDanmakuTexturePad * 2;
  const int box_height =
      static_cast<int>(std::ceil(font_size * 1.4f)) + kDanmakuTexturePad * 2;
  auto texture = std::make_shared<DanmakuTexture>();
  if (!texture->Create(box_width, box_height)) return false;
  {
    Gdiplus::Graphics graphics(texture->dc[0]);
    ConfigureGlassGraphics(graphics);
    // 与图标字形同一个理由：网格拟合会把小字号轮廓拉变形，文字用灰度抗锯齿
    // （用完即弃，不影响别的绘制）。外观与逐帧 DrawString 的时代保持一致。
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    const Gdiplus::Color color =
        item.color >= 0
            ? Gdiplus::Color(255, static_cast<BYTE>((item.color >> 16) & 0xFF),
                             static_cast<BYTE>((item.color >> 8) & 0xFF),
                             static_cast<BYTE>(item.color & 0xFF))
            : Gdiplus::Color(255, 255, 255, 255);
    Gdiplus::SolidBrush brush(color);
    // 阴影按 0.55 的不透明度画进位图，整体的「不透明度」设置由贴图时的
    // SourceConstantAlpha 施加 —— 这样拖不透明度滑块不必重新栅格化。
    Gdiplus::SolidBrush shadow(Gdiplus::Color(140, 0, 0, 0));
    const float pad = static_cast<float>(kDanmakuTexturePad);
    const Gdiplus::PointF origin(pad, pad);
    graphics.DrawString(item.text.c_str(), -1, &font,
                        Gdiplus::PointF(origin.X + 1.2f, origin.Y + 1.2f),
                        &format, &shadow);
    graphics.DrawString(item.text.c_str(), -1, &font, origin, &format, &brush);
    graphics.Flush(Gdiplus::FlushIntentionSync);
  }
  // GDI+ DrawString 是这条路径里最贵的步骤，不能为了 4 个亚像素相位重复调用
  // 4 次（密集弹幕持续进入时会挤占 paint 的提交相位）。只栅格化 phase 0，另外
  // 三张直接对预乘 BGRA 做水平线性移位；每条只是几万次整数运算，且结果仍能被
  // 后续每帧的单次 AlphaBlend 复用。
  const size_t stride = static_cast<size_t>(texture->width) * 4;
  for (int phase = 1; phase < DanmakuTexture::kPhases; ++phase) {
    const int right_weight = phase;
    const int left_weight = DanmakuTexture::kPhases - phase;
    for (int row = 0; row < texture->height; ++row) {
      const BYTE* source = texture->bits[0] + static_cast<size_t>(row) * stride;
      BYTE* target = texture->bits[phase] + static_cast<size_t>(row) * stride;
      for (int column = 0; column < texture->width; ++column) {
        for (int channel = 0; channel < 4; ++channel) {
          const int here = source[static_cast<size_t>(column) * 4 + channel];
          const int before = column == 0
                                 ? 0
                                 : source[(static_cast<size_t>(column) - 1) * 4 +
                                          channel];
          target[static_cast<size_t>(column) * 4 + channel] =
              static_cast<BYTE>((here * left_weight + before * right_weight +
                                 DanmakuTexture::kPhases / 2) /
                                DanmakuTexture::kPhases);
        }
      }
    }
  }
  item.texture = std::move(texture);
  return true;
}

// 把栅格化好的弹幕贴到弹幕层上：一次 AlphaBlend 就够。滚动弹幕有一半时间在
// 屏幕外，所以这里要先和自己的窗口求交，把交给 GDI 的矩形裁掉（别指望内存 DC
// 帮你裁剪 —— 它的裁剪区是设备面，不是这块 DIB）。
void BlendDanmakuTexture(const PanelSurface& surface,
                         const DanmakuTexture& texture, float x, int y, int pad,
                         BYTE alpha, int layer_width, int layer_height) {
  int destination_x = static_cast<int>(std::floor(x));
  const float fraction = x - static_cast<float>(destination_x);
  int phase = static_cast<int>(std::lround(
      fraction * static_cast<float>(DanmakuTexture::kPhases)));
  if (phase == DanmakuTexture::kPhases) {
    phase = 0;
    ++destination_x;
  }
  destination_x -= pad;
  int destination_y = y - pad;
  int source_x = 0;
  int source_y = 0;
  int copy_width = texture.width;
  int copy_height = texture.height;
  if (destination_x < 0) {
    source_x = -destination_x;
    copy_width += destination_x;
    destination_x = 0;
  }
  if (destination_y < 0) {
    source_y = -destination_y;
    copy_height += destination_y;
    destination_y = 0;
  }
  copy_width = std::min(copy_width, layer_width - destination_x);
  copy_height = std::min(copy_height, layer_height - destination_y);
  if (copy_width <= 0 || copy_height <= 0) return;
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = alpha;
  blend.AlphaFormat = AC_SRC_ALPHA;
  AlphaBlend(surface.dc, destination_x, destination_y, copy_width, copy_height,
             texture.dc[phase], source_x, source_y, copy_width, copy_height,
             blend);
}

void CreateDanmakuWindow(HINSTANCE instance) {
  if (g_danmaku) return;
  g_danmaku = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
      kDanmakuClass, L"", WS_POPUP, 0, 0, 1, 1, g_window, nullptr, instance,
      nullptr);
}

void PositionDanmaku() {
  if (!g_window || !g_danmaku) return;
  RECT client{};
  GetClientRect(g_window, &client);
  POINT origin{0, 0};
  ClientToScreen(g_window, &origin);
  // 压在视频之上显示。SWP_SHOWWINDOW 不能少：窗口创建时不带 WS_VISIBLE
  // （与 controls / top_bar / hint 一致），不显式显示就永远是一片空白。
  // 窗口是 WS_EX_TRANSPARENT（鼠标穿透），且只在上部 g_danmaku_area 区域内
  // 绘制，因此不会遮挡底部控制条，也不影响鼠标交互。
  // 顶栏是常驻信息区，弹幕从它下面开始。此前弹幕窗口 y=0，顶部固定弹幕会直接
  // 压住标题、网速和窗口按钮。
  const int safe_top = Scaled(kTopBarTopMargin + kTopBarHeight + 8);
  // 窗口只覆盖弹幕区域（画面上部 area），不铺满整个客户区：每帧要清零并
  // UpdateLayeredWindow 的像素越少，60fps 下越稳。底部控制条区域本来就不画
  // 弹幕，让它留在窗口外面既省开销，也彻底排除遮挡按钮的可能。
  const int area_bottom = static_cast<int>((client.bottom - client.top) *
                                           g_danmaku_area);
  SetWindowPos(g_danmaku, HWND_TOP, origin.x, origin.y + safe_top,
               client.right - client.left,
               std::max(1, area_bottom - safe_top),
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  InvalidateRect(g_danmaku, nullptr, FALSE);
}

void PaintDanmaku() {
  if (!g_danmaku) return;
  const double paint_start = NowMs();
  if (g_danmaku_paint_last > 0.0) {
    const double gap = paint_start - g_danmaku_paint_last;
    g_danmaku_gap_ms = std::max(g_danmaku_gap_ms, gap);
    g_danmaku_gap_sum_ms += gap;
    ++g_danmaku_gap_count;
    if (gap > 20.0) ++g_danmaku_gap_late20;
    if (gap > 33.0) ++g_danmaku_gap_late33;
    // 这一帧在屏停留了几个刷新周期（见 g_danmaku_dwell）。>4 归到最后一档。
    if (g_refresh_period_ms > 0.0) {
      const long long periods =
          std::lround(gap / g_refresh_period_ms);
      const int bucket = static_cast<int>(
          periods < 1 ? 1 : (periods > 4 ? 4 : periods));
      ++g_danmaku_dwell[bucket];
    }
  }
  g_danmaku_paint_last = paint_start;
  // 相对**本拍 tick 时刻**滞后了多少。tick 整齐而 dwell 散，就是这里在漂：
  // WM_PAINT 是低优先级消息，要等消息队列排空才派发，滞后量于是跟着消息负载走，
  // 每帧的「提交相位」相对合成边界来回过线，屏上停留的拍数就在 1/3 之间跳。
  if (g_tick_now_ms > 0.0) {
    const double phase = paint_start - g_tick_now_ms;
    g_paint_phase_sum_ms += phase;
    if (g_paint_phase_count == 0) {
      g_paint_phase_min_ms = phase;
      g_paint_phase_max_ms = phase;
    } else {
      g_paint_phase_min_ms = std::min(g_paint_phase_min_ms, phase);
      g_paint_phase_max_ms = std::max(g_paint_phase_max_ms, phase);
    }
    ++g_paint_phase_count;
  }
  RECT rect{};
  GetClientRect(g_danmaku, &rect);
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return;
  // 复用位图：每帧 CreateDIBSection + new Bitmap 在 60fps 下是主要开销，
  // 尺寸没变时只做一次 memset。
  if (!g_danmaku_surface) g_danmaku_surface = new PanelSurface();
  if (!g_danmaku_surface->Matches(width, height)) {
    if (!g_danmaku_surface->Create(width, height)) return;
  } else {
    g_danmaku_surface->Clear();
  }
  PanelSurface& surface = *g_danmaku_surface;
  Gdiplus::Graphics graphics(surface.target);
  ConfigureGlassGraphics(graphics);

  const float ui = UiScale();
  const float font_size = static_cast<float>(g_danmaku_font_size) * ui;
  const BYTE alpha =
      static_cast<BYTE>(std::clamp(g_danmaku_opacity, 0.15, 1.0) * 255);
  // 字体复用；字号变化时所有栅格化缓存（连同在屏条目的文本宽度）都作废，弹幕
  // 层从当前位置重新铺一遍。
  if (!g_danmaku_font || std::abs(g_danmaku_font_px - font_size) > 0.01f) {
    delete g_danmaku_font;
    g_danmaku_font =
        new Gdiplus::Font(MakeInterfaceFont(font_size, Gdiplus::FontStyleBold));
    g_danmaku_font_px = font_size;
    for (auto& item : g_danmaku_items) {
      item.texture.reset();
      item.text_width = -1.0f;
      item.font_size = -1.0f;
      item.live = false;
      item.lane = -1;
    }
    g_danmaku_live.clear();
    g_danmaku_cursor = 0;
    g_danmaku_last_position = -1.0;
    ResetDanmakuLaneFree();
  }
  const Gdiplus::Font& font = *g_danmaku_font;
  const Gdiplus::StringFormat format;

  const double now = DanmakuAnimationClock();
  const double pos = DanmakuPlayhead();
  // 窗口高度已经等于弹幕区域高度（见 PositionDanmaku），这里不再二次缩放。
  const float area_height = static_cast<float>(height);
  const float lane_h = font_size * 1.5f;
  const int lanes = std::max(1, static_cast<int>(area_height / lane_h));
  const int usable_lanes = std::max(
      1, static_cast<int>(lanes * (0.4 + 0.6 * g_danmaku_density)));
  if (g_danmaku_lane_free.size() < static_cast<size_t>(usable_lanes))
    g_danmaku_lane_free.resize(static_cast<size_t>(usable_lanes), 0.0);
  // 滚动弹幕**统一速度**（像素/秒）。以前写成「速度 = (窗口宽 + 文字宽) / 8」，
  // 观感上每条都正好 8 秒穿越，代价是同一条轨道上前后的速度不一样 —— 后面那条
  // 更快就会追上前面的糊在一起。同速之后，同轨两条的间距恒定，永不追尾，轨道
  // 才能安全地「尾巴一离开右边缘就让给下一条」。
  const float speed_px = static_cast<float>(width) /
                         static_cast<float>(kDanmakuScrollBaseSeconds) *
                         static_cast<float>(g_danmaku_speed);

  const double raster_deadline = NowMs() + kDanmakuRasterBudgetMs;

  // 跳转检测：位置大幅跳变时重置已播标记与在屏弹幕，避免「倒退后旧弹幕仍飘着」，
  // 也避免快进时把整段历史当成「刚过去」补播出来。
  if (g_danmaku_last_position >= 0 &&
      std::abs(pos - g_danmaku_last_position) > 2.0) {
    for (auto& item : g_danmaku_items) {
      item.live = false;
      item.appear = -1;
      item.lane = -1;
      item.played = false;
      item.texture.reset();
    }
    g_danmaku_live.clear();
    g_danmaku_cursor = DanmakuLowerBound(pos - kDanmakuCatchupSeconds);
    ResetDanmakuLaneFree();
  } else if (g_danmaku_last_position < 0) {
    // 刚读入弹幕（或者是断点续播落在中段）：直接把光标挪到当前位置附近。光标
    // 之前的条目永远不会被光顾，不必逐个标记成「已播」——整集几万条那样扫一遍
    // 就是起播时的一次卡顿。
    g_danmaku_cursor = DanmakuLowerBound(pos - kDanmakuCatchupSeconds);
  }
  g_danmaku_last_position = pos;

  // 激活：条目按时间排序，光标只会往前走，所以整集摊下来是 O(N)。落在补播
  // 窗口里的（快进 / 跳转之后刚到的那一批）直接按「本该出现的位置」摆好，而不是
  // 全部从右边挤进来。栅格化有每帧预算，超了就把条目留到下一帧再激活 —— 晚一
  // 两帧显示看不出来，卡一帧却很明显。
  const double catchup = pos - kDanmakuCatchupSeconds;
  while (g_danmaku_cursor < g_danmaku_items.size()) {
    DanmakuItem& item = g_danmaku_items[g_danmaku_cursor];
    if (item.time > pos) break;
    if (item.live) {
      // 在屏条目已经在 g_danmaku_live 里，交给下面的绘制循环。
    } else if (item.time < catchup) {
      // 早就该过去了：不补播，直接标记掉（否则一次快进就是几百条同屏）。
      item.played = true;
    } else if (!item.played) {
      if (!EnsureDanmakuTexture(item, graphics, font, font_size, format,
                                raster_deadline)) {
        break;  // 预算用完，下一帧接着来
      }
      // 出现时刻按「它本该出现的播放时间」倒推：补播的条目会直接出现在屏幕
      // 中间，而不是排成一排从右边涌进来。
      double appear = now - std::max(0.0, pos - item.time);
      // 占一条轨道。两条规则缺一条就会重叠：
      //
      // 1) 挑「最早能空出来」的那条轨道（不是永远挑 0 号，也不是挑最空的那条）；
      // 2) 空出来之前不放 —— 何时空出来由 hold 决定。滚动弹幕是**尾巴离开右边缘
      //    再让开 kDanmakuLaneGapPx** 的时刻（appear + (文字宽 + 间距) / 速度），
      //    顶/底弹幕是停留结束的时刻。
      //
      // 以前的实现把整段「穿越 8 秒」都算成占用（容量只剩每轨 1 条 / 8 秒，16
      // 条轨道顶不住每秒十几条），而且 lane_free 只在绘制循环里更新 —— 同一帧里
      // 一起激活的条目看到的都是旧值，并列时就都挑到 0 号轨道。两条叠加，密集
      // 弹幕必然糊成一片（实测 109 条同屏时 99 条互相叠压）。
      const bool fixed = item.mode == 4 || item.mode == 5 || item.mode == 6;
      const double hold =
          fixed ? kDanmakuExitSeconds
                : std::max(0.6, static_cast<double>(item.text_width +
                                                    kDanmakuLaneGapPx) /
                                    std::max(1.0f, speed_px));
      int best = 0;
      double best_free = g_danmaku_lane_free[0];
      for (int lane = 1; lane < usable_lanes; ++lane) {
        if (g_danmaku_lane_free[static_cast<size_t>(lane)] < best_free) {
          best_free = g_danmaku_lane_free[static_cast<size_t>(lane)];
          best = lane;
        }
      }
      // 顶/底弹幕没有「从右边进入」这个动作：推迟等于提前显示（它会立刻出现在
      // 轨道正中），所以轨道不空就丢掉，绝不排队。
      if (fixed && best_free > appear) {
        item.played = true;
        ++g_danmaku_dropped;
      } else if (best_free > appear + kDanmakuMaxDelaySeconds) {
        // 连最早空出来的那条轨道都要等太久：这一条丢掉。同屏已经满了，叠上去
        // 只会让两边都看不清；真实播放器到了同屏上限也是丢。
        item.played = true;
        ++g_danmaku_dropped;
      } else {
        if (best_free > appear) appear = best_free;  // 排队：等这条轨道空出来
        item.appear = appear;
        item.lane = best;
        item.free_at = appear + hold;
        g_danmaku_lane_free[static_cast<size_t>(best)] = item.free_at;
        item.live = true;
        g_danmaku_live.push_back(&item);
      }
    }
    ++g_danmaku_cursor;
  }

  int live_count = 0;
  int drawn_count = 0;
  int overlap = 0;
  int mixed = 0;
  // 这一帧压得最深的一对（诊断用）：只数条数分不清「浮点贴边」和「真的糊住」，
  // 把最深那一对的几何留下来，一次就能定性。
  float worst_depth = 0.0f;
  int worst_lane = -1;
  float worst_a0 = 0.0f;
  float worst_a1 = 0.0f;
  float worst_b0 = 0.0f;
  float worst_b1 = 0.0f;
  // 轨道占用区间（诊断用），按弹幕**类型**分成两组：
  //   lane_spans —— 滚动弹幕占的横向区间。滚动弹幕互相压住是**我们能控制的缺陷**，
  //                 轨道分配只要严密就应该恒为 0；
  //   lane_fixed —— 顶/底固定弹幕占的横向区间（在轨道正中停 4 秒）。滚动弹幕从它
  //                 上面飘过去是所有播放器的正常行为，只作参考（mixed），不算 BAD。
  // 两者必须分开：混在一起的话「滚动穿固定」会被算进 overlap，指标虚高、看不出
  // 真缺陷到底修好没有。
  static std::vector<std::vector<std::pair<float, float>>> lane_spans;
  static std::vector<std::vector<std::pair<float, float>>> lane_fixed;
  lane_spans.resize(static_cast<size_t>(usable_lanes));
  lane_fixed.resize(static_cast<size_t>(usable_lanes));
  for (auto& spans : lane_spans) spans.clear();
  for (auto& spans : lane_fixed) spans.clear();
  // 固定弹幕先统一扫一遍：它们都停在轨道正中，位置与「在屏多久」无关，先记下占位
  // 区间，主循环里的滚动弹幕才能检出「穿过」，而且不受遍历顺序影响（否则同一帧里
  // 排在后面的固定弹幕就检不出来）。
  for (const DanmakuItem* pointer : g_danmaku_live) {
    const DanmakuItem& item = *pointer;
    const bool top_item = item.mode == 4 || item.mode == 5;
    const bool bottom_item = item.mode == 6;
    if (!top_item && !bottom_item) continue;
    // 底弹幕的 lane 是**从下往上**数的（绘制时 y = 高 - (lane+1)*行高），换算成
    // 与滚动弹幕同一套「从上往下」的行号才能正确比对，否则会把屏幕另一头、根本
    // 碰不到的条目算成「穿过」。
    int row = bottom_item ? usable_lanes - 1 - item.lane : item.lane;
    if (row < 0 || row >= static_cast<int>(lane_fixed.size())) continue;
    if (top_item ? !g_danmaku_top : !g_danmaku_bottom) continue;
    if (now - item.appear > kDanmakuExitSeconds) continue;
    const float fixed_tw = item.text_width > 0.0f ? item.text_width : 0.0f;
    const float fixed_x = (width - fixed_tw) / 2.0f;
    if (fixed_x < static_cast<float>(width) && fixed_x + fixed_tw > 0.0f)
      lane_fixed[static_cast<size_t>(row)].emplace_back(fixed_x,
                                                        fixed_x + fixed_tw);
  }
  size_t write = 0;
  for (size_t index = 0; index < g_danmaku_live.size(); ++index) {
    DanmakuItem* pointer = g_danmaku_live[index];
    DanmakuItem& item = *pointer;
    const bool top = item.mode == 4 || item.mode == 5;
    const bool bottom = item.mode == 6;
    const float tw = item.text_width > 0.0f ? item.text_width : 0.0f;
    float x = 0;
    float y = 0;
    bool keep = true;
    if (top || bottom) {
      keep = top ? g_danmaku_top : g_danmaku_bottom;
      x = (width - tw) / 2.0f;
      y = top ? item.lane * lane_h + (lane_h - font_size) / 2.0f
              : area_height - (item.lane + 1) * lane_h +
                    (lane_h - font_size) / 2.0f;
      if (now - item.appear > kDanmakuExitSeconds) keep = false;
    } else {
      keep = g_danmaku_scroll;
      x = width - static_cast<float>((now - item.appear) * speed_px);
      y = item.lane * lane_h + (lane_h - font_size) / 2.0f;
      if (x + tw < 0.0f) keep = false;
    }
    if (!keep) {
      item.live = false;
      item.played = true;
      item.lane = -1;
      item.texture.reset();
      continue;  // 不写回在屏列表：这一条到此结束
    }
    ++live_count;
    // 只统计**真的画在屏上**的条目：排队等轨道的条目此刻还在右边缘之外
    // （x >= width），它们互相之间不算重叠，否则指标会把「排队」误报成「叠压」。
    // 固定弹幕的占位已在上面的预扫里收集，这里只判滚动弹幕。
    if (!top && !bottom && x < static_cast<float>(width) && x + tw > 0.0f &&
        item.lane >= 0 && item.lane < static_cast<int>(lane_spans.size())) {
      const size_t lane = static_cast<size_t>(item.lane);
      for (const auto& span : lane_spans[lane]) {
        if (x < span.second && span.first < x + tw) {
          ++overlap;  // 压住同轨另一条滚动弹幕：真缺陷
          // 压进去多少像素：左右两个交叠边界之差。贴边（<1px）是浮点误差，
          // 几十像素才是肉眼可见的糊。
          const float depth =
              std::min(x + tw, span.second) - std::max(x, span.first);
          if (depth > worst_depth) {
            worst_depth = depth;
            worst_lane = item.lane;
            worst_a0 = x;
            worst_a1 = x + tw;
            worst_b0 = span.first;
            worst_b1 = span.second;
          }
          break;
        }
      }
      lane_spans[lane].emplace_back(x, x + tw);
      for (const auto& span : lane_fixed[lane]) {
        if (x < span.second && span.first < x + tw) {
          ++mixed;  // 从固定弹幕上飘过去：正常行为，只作参考
          break;
        }
      }
    }
    if (item.texture) {
      // 文字已经栅格化好了，这一帧只做一次带 alpha 的贴图。
      BlendDanmakuTexture(surface, *item.texture, x,
                          std::lround(y), kDanmakuTexturePad, alpha, width,
                          height);
      ++drawn_count;
    }
    g_danmaku_live[write++] = pointer;
  }
  g_danmaku_live.resize(write);
  graphics.Flush(Gdiplus::FlushIntentionSync);
  const double draw_end = NowMs();
  g_danmaku_draw_ms += draw_end - paint_start;
  POINT source{0, 0};
  SIZE size{width, height};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(g_danmaku, nullptr, nullptr, &size, surface.dc, &source,
                      0, &blend, ULW_ALPHA);
  g_danmaku_post_ms += NowMs() - draw_end;
  ++g_danmaku_frames;
  ++g_danmaku_paint_total;
  g_danmaku_overlap_max = std::max(g_danmaku_overlap_max, overlap);
  g_danmaku_mixed_max = std::max(g_danmaku_mixed_max, mixed);
  g_danmaku_lanes = usable_lanes;
  if (worst_depth > g_danmaku_overlap_depth) {
    g_danmaku_overlap_depth = worst_depth;
    g_danmaku_overlap_lane = worst_lane;
    g_danmaku_overlap_a0 = worst_a0;
    g_danmaku_overlap_a1 = worst_a1;
    g_danmaku_overlap_b0 = worst_b0;
    g_danmaku_overlap_b1 = worst_b1;
  }
  // 这一帧要的东西都画完了：下一次重绘由「动画中」或「有变化」来触发
  // （见 TickFrame 与 DanmakuAnimationClock 的说明）。
  g_danmaku_dirty = false;
  // 与面板同一套诊断：弹幕层也是 layered 窗口，抓屏会被压在上面的窗口顶掉，
  // 需要时就把它自己的位图导出来核对（MOVA_TRACE_PANEL=<目录>）。挑「铺满之后
  // 的稳态」两帧 —— 起播那一瞬整层只有几条贴在右边缘，看不出排版问题。只导两帧、
  // 而且层位图一张就好几 MB。
  static int traced = 0;
  if (traced < 2 &&
      g_danmaku_paint_total >= kDanmakuTraceSpacingFrames * (traced + 1)) {
    ++traced;
    TracePanelSurface(surface, L"danmaku");
  }
  // 诊断开关：设 MOVA_TRACE_DANMAKU=1 后每 60 帧回报一行。
  //   live / drawn / size / pos：屏上几条、有几条贴上了、层尺寸、播放位置 ——
  //     分清是数据侧不再激活还是窗口侧没渲染；
  //   draw / post / gap：文字绘制、清屏+合成、相邻两帧最大间隔 —— 「一顿一顿」
  //     时看这三个就知道是画得太慢，还是定时器被别的东西堵住；
  //   avg / late20 / late33：这一窗口（60 帧）的平均帧间隔，以及超过 20ms / 33ms
  //     的帧数 —— 均值贴 16.7 说明节拍正常，只有最大值高是偶发；均值本身就
  //     18ms 以上才是系统性掉帧；
  //   overlap / mixed / lanes：同轨重叠条数、穿过固定弹幕的条数与可用轨道数 ——
  //     「叠在一起看不清」的直接度量。overlap（滚动压滚动）应恒为 0；mixed（滚动
  //     穿固定）是正常现象，只作参考；
  //   depth / olane / orect：最深那一对压进去多少像素、在哪条轨道、两段的左右边界
  //     —— 只数条数分不清「浮点贴边」和「真的糊住」，深度才说明问题；
  //   drop：mpv 自己丢掉的解码帧数 —— 和 gap 对照可以分清「弹幕在抖」还是
  //     「视频本身在抖」；
  //   refresh / div：面板刷新周期与分频（一个 tick = div × refresh）—— 判 dwell 的前提；
  //   compose：DWM 自报的目标合成节奏（rateCompose）。它和 refresh 不一致时说明
  //     DWM 自己降频了，那时怎么调节拍都没用，先去查合成设置；
  //   dwell1..4：相邻两帧之间隔了几个刷新周期的分布。**这是判「平滑」的主指标**：
  //     理想是全部落在同一个整数拍上（本机 170Hz / div=2 → 全部落 2 拍）。
  //     均值类指标（avg / late20 / late33）对「每帧停留时长不相等」是无感的，
  //     以前正是因此把「170Hz 面板 + 16ms 定时器」判成了合格。
  static const bool trace_draw = [] {
    wchar_t buffer[8]{};
    return GetEnvironmentVariableW(L"MOVA_TRACE_DANMAKU", buffer, 8) > 0;
  }();
  if (trace_draw && g_danmaku_frames >= 60) {
    // 就在要打印的这一刻采一次合成器时序：compose 是「此刻」的节奏，早采没意义，
    // 而放在主循环里周期性采又要多一套节流状态（还没了用处）。
    SampleCompositionTiming();
    const double frames = g_danmaku_frames;
    const int dropped = std::max(0, std::atoi(MpvString("frame-drop-count").c_str()));
    char text[768]{};
    const int length = std::snprintf(
        text, sizeof(text),
        "MOVA_DANMAKU_DRAW=live=%d drawn=%d size=%dx%d pos=%.2f "
        "draw=%.2f post=%.2f gap=%.2f frames=%d"
        " overlap=%d mixed=%d lanes=%d dropped=%d drop=%d"
        " depth=%.1f olane=%d orect=%.0f,%.0f,%.0f,%.0f"
        " avg=%.2f late20=%d late33=%d"
        " refresh=%.3f div=%d compose=%.2f dwell=%d,%d,%d,%d tick=%.2f/%d"
        " tickdwell=%d,%d,%d,%d tkmax=%.2f ptph=%.2f ptjit=%.2f mw=%d|\r\n",
        live_count, drawn_count, width, height, pos, g_danmaku_draw_ms / frames,
        g_danmaku_post_ms / frames, g_danmaku_gap_ms, g_danmaku_frames,
        g_danmaku_overlap_max, g_danmaku_mixed_max, g_danmaku_lanes,
        g_danmaku_dropped, dropped, g_danmaku_overlap_depth,
        g_danmaku_overlap_lane, g_danmaku_overlap_a0, g_danmaku_overlap_a1,
        g_danmaku_overlap_b0, g_danmaku_overlap_b1,
        g_danmaku_gap_count > 0 ? g_danmaku_gap_sum_ms / g_danmaku_gap_count
                                : 0.0,
        g_danmaku_gap_late20, g_danmaku_gap_late33, g_refresh_period_ms,
        g_frame_divisor, g_dwm_compose_ms, g_danmaku_dwell[1],
        g_danmaku_dwell[2], g_danmaku_dwell[3], g_danmaku_dwell[4],
        g_tick_count > 0 ? g_tick_sum_ms / g_tick_count : 0.0, g_tick_count,
        g_tick_dwell[1], g_tick_dwell[2], g_tick_dwell[3], g_tick_dwell[4],
        g_tick_gap_max,
        g_paint_phase_count > 0 ? g_paint_phase_sum_ms / g_paint_phase_count
                                : 0.0,
        g_paint_phase_count > 0
            ? g_paint_phase_max_ms - g_paint_phase_min_ms
            : 0.0,
        g_msg_wakes);
    const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output && output != INVALID_HANDLE_VALUE && length > 0) {
      DWORD written = 0;
      WriteFile(output, text, static_cast<DWORD>(length), &written, nullptr);
    }
    g_danmaku_draw_ms = 0.0;
    g_danmaku_post_ms = 0.0;
    g_danmaku_gap_ms = 0.0;
    g_danmaku_gap_sum_ms = 0.0;
    g_danmaku_gap_count = 0;
    g_danmaku_gap_late20 = 0;
    g_danmaku_gap_late33 = 0;
    for (int& bucket : g_danmaku_dwell) bucket = 0;
    g_tick_sum_ms = 0.0;
    g_tick_count = 0;
    for (int& bucket : g_tick_dwell) bucket = 0;
    g_tick_gap_max = 0.0;
    g_paint_phase_sum_ms = 0.0;
    g_paint_phase_count = 0;
    g_msg_wakes = 0;
    g_danmaku_frames = 0;
    g_danmaku_overlap_max = 0;
    g_danmaku_mixed_max = 0;
    g_danmaku_overlap_depth = 0.0;
    g_danmaku_overlap_lane = -1;
  }
}

// 弹幕位图与字体都是 GDI+ 对象，而 GdiplusShutdown 会卸载 gdiplus.dll。
// 必须在那之前释放，否则进程收尾时析构会踩到已失效的 Gdip*（0xC0000005）。
void ReleaseDanmakuSurface() {
  delete g_danmaku_surface;
  g_danmaku_surface = nullptr;
  delete g_danmaku_font;
  g_danmaku_font = nullptr;
  g_danmaku_font_px = -1.0f;
}

LRESULT CALLBACK DanmakuProc(HWND window, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      BeginPaint(window, &paint);
      PaintDanmaku();
      EndPaint(window, &paint);
      return 0;
    }
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
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
        // 与面板同一套做法：物理窗口 + ScaleTransform，内部按设计稿绘制。
        const float scale = UiScale();
        graphics.ScaleTransform(scale, scale);
        // 同面板：提示窗口自己的屏幕位置，供背板取像素（见 DrawGlassBackdrop）。
        RECT window_rect{};
        if (GetWindowRect(window, &window_rect)) {
          g_glass_window_origin.x = window_rect.left;
          g_glass_window_origin.y = window_rect.top;
        }
        PaintHint(graphics, static_cast<int>(rect.right / scale),
                  static_cast<int>(rect.bottom / scale), g_hint_icon,
                  g_hint_text, g_hint_detail, g_hint_fraction, g_hint_accent);
        graphics.Flush(Gdiplus::FlushIntentionSync);
        POINT source{0, 0};
        SIZE size{rect.right, rect.bottom};
        BLENDFUNCTION blend{};
        blend.BlendOp = AC_SRC_OVER;
        blend.SourceConstantAlpha = 255;
        blend.AlphaFormat = AC_SRC_ALPHA;
        UpdateLayeredWindow(window, nullptr, nullptr, &size, surface.dc,
                            &source, 0, &blend, ULW_ALPHA);
        // 提示同样是 layered 窗口：抓屏拿不到，导出成 BMP 才能离线核对
        // 「底色是不是又变回一块黑」。
        TracePanelSurface(surface, L"hint");
      }
      EndPaint(window, &paint);
      return 0;
    }
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

// 调整类操作的统一说法：一行标题 + 一行明细 +（可选）一条进度。音量与亮度这
// 类有量纲的调整，进度条让「现在是多亮、多响」一眼可见。
void ShowAdjustHint(const std::wstring& title, const std::wstring& detail,
                    wchar_t icon, float fraction, bool accent) {
  ShowHint(title, detail, icon, HintMode::Toast, fraction, 0, accent);
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
      // 顶栏也用 `UpdateLayeredWindow` 逐像素呈现：键色（LWA_COLORKEY）只有
      // 「透明 / 不透明」两档，画不出半透明的玻璃圆片 —— 右上角那三个窗口按钮
      // 永远是实心深灰，和「所有控件都要液态玻璃」对不上。见 PresentTopBarSurface。
      BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      EndPaint(window, &paint);
      const int pixel_width = rect.right - rect.left;
      const int pixel_height = rect.bottom - rect.top;
      if (pixel_width <= 0 || pixel_height <= 0) return 0;
      if (!g_top_surface) g_top_surface = new PanelSurface();
      if (g_top_surface->width != pixel_width ||
          g_top_surface->height != pixel_height) {
        if (!g_top_surface->Create(pixel_width, pixel_height)) return 0;
      } else {
        g_top_surface->Clear();
      }
      {
        SyncGlassWindowOrigin(window);
        Gdiplus::Graphics graphics(g_top_surface->target);
        ConfigureGlassGraphics(graphics);
        // 整块面从「完全透明」开始：没画到的地方是真的透明（以前靠键色）。
        graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
        // 顶栏窗口保持全宽，内部按设计稿坐标绘制、ScaleTransform 放大到物理：
        // 窗口变小时字号与按钮等比缩小，相对布局关系不变。
        const float ui_scale = UiScale();
        graphics.ScaleTransform(ui_scale, ui_scale);
        rect.right = static_cast<LONG>(std::lround(rect.right / ui_scale));
        rect.bottom = static_cast<LONG>(std::lround(rect.bottom / ui_scale));
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
        const Gdiplus::RectF chip = PixelSnapRect(Gdiplus::RectF(
            static_cast<float>(rect.right) - 156.0f - chip_width,
            (rect.bottom - chip_height) / 2.0f, chip_width, chip_height));
        Gdiplus::GraphicsPath chip_path;
        AddRoundedRectPath(chip_path, chip, chip_height / 2.0f);
        FillGlassSurface(graphics, chip_path, chip, GlassChromeAlpha(false),
                         GlassChromeAlpha(true), true);
        StrokeGlassEdge(graphics, chip_path);
        DrawGlyph(graphics, L'\xF0C3', chip.X + chip_padding + chip_icon / 2.0f,
                  chip.Y + chip_height / 2.0f, chip_icon,
                  g_buffering.load() ? Gdiplus::Color(BYTE{200}, 255, 255, 255)
                                     : Gdiplus::Color(BYTE{235}, 255, 255, 255),
                  false, true);
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
          // 常驻的液态玻璃圆片：和控件条上的按钮同一套底。以前这里是 188 的实心
          // 深灰 + 一圈描边，压在画面上就是一排黑点 —— 用户说的「右上角几个控件
          // 也要液态玻璃」指的就是它们。
          const Gdiplus::RectF disc =
              PixelSnapRect(Gdiplus::RectF(x - 18, 11, 36, 36));
          Gdiplus::GraphicsPath disc_path;
          AddRoundedRectPath(disc_path, disc, disc.Width / 2.0f);
          FillGlassSurface(graphics, disc_path, disc, GlassDiscAlpha(false),
                           GlassDiscAlpha(true), true);
          StrokeGlassEdge(graphics, disc_path);
          if (hover_amount > 0.001f) {
            const BYTE alpha = static_cast<BYTE>(hover_amount *
                                                 (button == 3 ? 210 : 74));
            Gdiplus::SolidBrush hover(button == 3
                                          ? Gdiplus::Color(alpha, 255, 69, 58)
                                          : Gdiplus::Color(alpha, 126, 174, 255));
            const float inset = (1.0f - hover_amount) * 3.0f;
            graphics.FillEllipse(&hover,
                                 Gdiplus::RectF(disc.X + inset, disc.Y + inset,
                                                disc.Width - inset * 2,
                                                disc.Height - inset * 2));
          }
          // 和应用标题栏 YingjiMotionIconButton 同一条规则：图标字号 = 直径 × 0.43。
          constexpr float kWindowIcon = 36.0f * 0.43f;
          const Gdiplus::Color ink(BYTE{238}, 244, 244, 247);
          if (button == 1) {
            DrawGlyph(graphics, L'\xEDAD', x, 29.0f, kWindowIcon, ink, false,
                      true);
          } else if (button == 2) {
            const bool zoomed = IsZoomed(g_window) != 0;
            DrawGlyph(graphics, zoomed ? L'\xE9F6' : L'\xED57', x, 29.0f,
                      kWindowIcon, ink, false, true);
          } else {
            DrawGlyph(graphics, L'\xEAB2', x, 29.0f, kWindowIcon, ink, false,
                      true);
          }
        }
        graphics.Flush(Gdiplus::FlushIntentionSync);
      }
      PresentTopBarSurface();
      return 0;
    }
    case WM_MOUSEMOVE: {
      // 鼠标移动不在这里刷新计时器：mpv 嵌入后会周期性重投 WM_MOUSEMOVE，
      // 光标静止时也收得到（实测约每 500 ms 一次，坐标一字不差），无条件
      // 刷新会让控件永远不隐藏。移动由 timer 里基于真实位移的轮询负责。
      TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT), TME_LEAVE, window, 0};
      TrackMouseEvent(&tracking);
      RECT rect{};
      GetClientRect(window, &rect);
      const float scale = UiScale();
      const int hover =
          TopHit(static_cast<int>(GET_X_LPARAM(lparam) / scale),
                 static_cast<int>(rect.right / scale));
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
      const float scale = UiScale();
      const int hit = TopHit(static_cast<int>(GET_X_LPARAM(lparam) / scale),
                             static_cast<int>(rect.right / scale));
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
      // 用 ULW 呈现，绘制目标是自己那块 32bpp 预乘 ARGB 的离屏面，不再画到窗口
      // DC 上。BeginPaint/EndPaint 仍然要走一遍（负责清掉系统的重绘标记）。
      BeginPaint(window, &paint);
      RECT rect{};
      GetClientRect(window, &rect);
      const int pixel_width = rect.right - rect.left;
      const int pixel_height = rect.bottom - rect.top;
      EndPaint(window, &paint);
      if (pixel_width <= 0 || pixel_height <= 0) return 0;
      if (!g_controls_surface) g_controls_surface = new PanelSurface();
      if (g_controls_surface->width != pixel_width ||
          g_controls_surface->height != pixel_height) {
        if (!g_controls_surface->Create(pixel_width, pixel_height)) return 0;
      } else {
        // 尺寸没变就复用同一块 DIB：省掉每次重画都新建位图 + GDI+ Bitmap。
        g_controls_surface->Clear();
      }
      {
        SyncGlassWindowOrigin(window);
        Gdiplus::Graphics graphics(g_controls_surface->target);
        ConfigureGlassGraphics(graphics);
        // 整块面从「完全透明」开始 —— 这就是「控件背景没了」的实现：没画到的地方
        // 是真的透明，视频原样透出来，而不是被常量 alpha 压成 91% 的黑板。
        graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
      // 控件条窗口已经是缩放后的物理大小；内部布局仍全部是设计稿坐标，
      // 一次 ScaleTransform 换过去，按钮、字号、进度条就都跟着窗口走。
      const float ui_scale = UiScale();
      graphics.ScaleTransform(ui_scale, ui_scale);
      rect.right = static_cast<LONG>(std::lround(rect.right / ui_scale));
      rect.bottom = static_cast<LONG>(std::lround(rect.bottom / ui_scale));
      // 控件条不再有底板、圆角与描边 —— 它就是「一条通屏进度条 + 一排玻璃圆片」。
      // 所以这里既不 SetClip，也不铺任何整块压暗（用户看到的「下面的控件背景框」
      // 就是那道 10→124 的 scrim，已删除）。
      // ⚠️ 只保留一层 6/255（上下淡出）的全底色，理由见 kDockHitBandAlpha：
      // 逐像素 alpha 下 alpha=0 的像素会点击穿透，而进度条拖动 / 悬停预览 / 按钮
      // 点击全靠这个窗口收鼠标。6/255 的压暗肉眼不可见，命中行为与以前完全一致。
      // ⚠️ 全部走 INT：`Gdiplus::Point` 只收 INT，`FillRectangle` 同时有 INT 与
      // REAL 两个重载，混着传 float 会 C2666 二义 + C4244，而本工程开了 /WX。
      const int dock_right = static_cast<int>(rect.right);
      const int dock_bottom = static_cast<int>(rect.bottom);
      if (dock_right > 0 && dock_bottom > 0) {
        // 上下两端各自淡出（而不是一整块平铺的 6/255）：这条带子铺满整个屏幕
        // 宽度，如果上下留一条硬边，2% 的亮度台阶在亮画面上仍可能被看出来。
        // 淡出之后整条窗口没有任何可见边界，命中测试却全程有效。
        const BYTE band = static_cast<BYTE>(kDockHitBandAlpha);
        const int fade = std::max(1, std::min(dock_bottom / 3, 30));
        const int tail_top = std::max(fade, dock_bottom - fade);
        Gdiplus::LinearGradientBrush head(
            Gdiplus::Point(0, 0), Gdiplus::Point(0, fade),
            Gdiplus::Color(static_cast<BYTE>(band / 2), 0, 0, 0),
            Gdiplus::Color(band, 0, 0, 0));
        graphics.FillRectangle(&head, 0, 0, dock_right, fade);
        if (tail_top > fade) {
          Gdiplus::SolidBrush mid(Gdiplus::Color(band, 0, 0, 0));
          graphics.FillRectangle(&mid, 0, fade, dock_right, tail_top - fade);
        }
        Gdiplus::LinearGradientBrush tail(
            Gdiplus::Point(0, tail_top), Gdiplus::Point(0, dock_bottom),
            Gdiplus::Color(band, 0, 0, 0), Gdiplus::Color(0, 0, 0, 0));
        graphics.FillRectangle(&tail, 0, tail_top, dock_right,
                               dock_bottom - tail_top);
      }
      const float width = static_cast<float>(rect.right);
      const double duration = g_duration.load();
      const double position = g_position.load();
      const float fraction = duration > 0
                                 ? static_cast<float>(std::min(1.0, position / duration))
                                 : 0.0f;
      // 进度条通屏：x 从 0 到窗口宽度（＝屏幕左右边缘），不再有 24px 内缩。
      //
      // 三段必须是**同一条白的三档亮度**，一眼能分出「看到哪」和「缓冲到哪」：
      //   未缓存 34 → 已缓存 96 → 已播放 250。
      // 以前已播放是 (110,168,255) 的蓝，还和悬停高亮同色 —— 全屏唯一的强调色
      // 不该是蓝，用户说的「进度条是蓝的、分不清缓存」就是它。未缓存那一档压到
      // 亮画面上几乎看不见，所以底下垫一层 96 的黑，深浅画面都读得出来。
      const float cached = static_cast<float>(
          std::clamp(g_cache_fraction.load(), 0.0, 1.0));
      const float played = std::clamp(fraction, 0.0f, 1.0f);
      Gdiplus::Pen base(Gdiplus::Color(BYTE{96}, 0, 0, 0), 5.0f);
      ConfigureControlPen(base);
      graphics.DrawLine(&base, 0.0f, kSeekLineY, width, kSeekLineY);
      // 未缓存一档给 52：34 压在深色画面上几乎看不见（黑底加黑托底＝还是黑），
      // 52 仍然明显暗于已缓存的 96，三档的区别不会糊在一起。
      Gdiplus::Pen track(Gdiplus::Color(BYTE{52}, 255, 255, 255), 4.0f);
      ConfigureControlPen(track);
      graphics.DrawLine(&track, 0.0f, kSeekLineY, width, kSeekLineY);
      if (cached > 0.01f) {
        Gdiplus::Pen cache_progress(Gdiplus::Color(BYTE{96}, 255, 255, 255),
                                    4.0f);
        ConfigureControlPen(cache_progress);
        graphics.DrawLine(&cache_progress, 0.0f, kSeekLineY, width * cached,
                          kSeekLineY);
      }
      if (played > 0.01f) {
        Gdiplus::Pen progress(Gdiplus::Color(BYTE{250}, 255, 255, 255), 4.0f);
        ConfigureControlPen(progress);
        graphics.DrawLine(&progress, 0.0f, kSeekLineY, width * played,
                          kSeekLineY);
      }
      const float played_x = width * fraction;
      const double hover_fraction = g_seek_hover.load();
      const bool hovering_seek = hover_fraction >= 0;
      Gdiplus::SolidBrush thumb(Gdiplus::Color(255, 245, 248, 255));
      const float thumb_size = hovering_seek ? 12.0f : 8.0f;
      graphics.FillEllipse(
          &thumb, Gdiplus::RectF(played_x - thumb_size / 2,
                                 kSeekLineY - thumb_size / 2, thumb_size,
                                 thumb_size));
      if (hovering_seek && duration > 0) {
        const float hover_x = width * static_cast<float>(hover_fraction);
        Gdiplus::Pen marker(Gdiplus::Color(190, 255, 255, 255), 1.0f);
        graphics.DrawLine(&marker, hover_x, kSeekLineY - 4.0f, hover_x,
                          kSeekLineY + 4.0f);
        const int preview_seconds =
            static_cast<int>(duration * hover_fraction);
        wchar_t preview[24]{};
        swprintf_s(preview, L"%02d:%02d", preview_seconds / 60,
                   preview_seconds % 60);
        const float bubble_x = std::clamp(hover_x - 25.0f, 2.0f, width - 52.0f);
        // 悬浮预览也是玻璃：和面板/提示同一套材质，不再是固定 245 的深灰块。
        // 同样铺背板（只是从缓存里搬一小块，不触发采集）—— 少铺这一层的话，同一根
        // 进度条上「气泡」和「面板」会是两种玻璃，正是用户说的「割裂」。
        Gdiplus::GraphicsPath bubble_path;
        const Gdiplus::RectF bubble_rect(bubble_x, 0.0f, 50.0f, 17.0f);
        AddRoundedRectPath(bubble_path, bubble_rect, 8.5f);
        FillGlassSurface(graphics, bubble_path, bubble_rect,
                         GlassPanelAlpha(false), GlassPanelAlpha(true), true);
        StrokeGlassEdge(graphics, bubble_path);
        auto preview_font = MakeInterfaceFont(9, Gdiplus::FontStyleRegular);
        Gdiplus::StringFormat preview_format;
        preview_format.SetAlignment(Gdiplus::StringAlignmentCenter);
        preview_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        graphics.DrawString(preview, -1, &preview_font,
                            Gdiplus::RectF(bubble_x, 0, 50, 17),
                            &preview_format, &thumb);
      }

      const float center = width / 2;
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
      const Gdiplus::RectF play_rect = PixelSnapRect(
          Gdiplus::RectF(center - 24, controls_y - 24, 48, 48),
          0.5f);
      Gdiplus::GraphicsPath play_path;
      AddRoundedRectPath(play_path, play_rect, play_rect.Width / 2.0f);
      FillGlassSurface(graphics, play_path, play_rect,
                       GlassChromeAlpha(false), GlassChromeAlpha(true), true);
      StrokeGlassEdge(graphics, play_path);
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
        DrawDockLabel(graphics, L"播放失败", status_font,
                      Gdiplus::PointF(24, 63), error);
        // 「重新播放」：失败之后 mpv 停在 idle，播放键发 cycle pause 毫无作用，
        // 这颗胶囊是界面上唯一说得清的恢复入口（命中区见 HitControl 的 kReplay，
        // 两者宽度是一份：78 + 74）。材质与控件条其它按钮完全一致 —— frost 渐变
        // 加悬停叠一层极淡的白，不另起一套观感。
        const float replay_hover = HoverAmount(kReplay);
        Gdiplus::GraphicsPath replay_path;
        const Gdiplus::RectF replay_rect(78.0f, 54.0f, 74.0f, 26.0f);
        AddRoundedRectPath(replay_path, replay_rect, 13.0f);
        FillGlassSurface(graphics, replay_path, replay_rect,
                         GlassDiscAlpha(false), GlassDiscAlpha(true), true);
        StrokeGlassEdge(graphics, replay_path);
        if (replay_hover > 0.001f) {
          Gdiplus::SolidBrush lit(Gdiplus::Color(
              static_cast<BYTE>(replay_hover * 68), 255, 255, 255));
          graphics.FillPath(&lit, &replay_path);
        }
        Gdiplus::SolidBrush replay_ink(Gdiplus::Color(255, 248, 248, 250));
        auto replay_font = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
        Gdiplus::StringFormat replay_format;
        replay_format.SetAlignment(Gdiplus::StringAlignmentCenter);
        replay_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        graphics.DrawString(L"重新播放", -1, &replay_font, replay_rect,
                            &replay_format, &replay_ink);
      } else if (g_buffering.load()) {
        Gdiplus::SolidBrush accent(Gdiplus::Color(255, 236, 238, 245));
        Gdiplus::Pen spinner(Gdiplus::Color(255, 236, 238, 245), 1.8f);
        ConfigureControlPen(spinner);
        graphics.DrawArc(&spinner, Gdiplus::RectF(23, 66, 10, 10),
                         g_buffer_phase, 245);
        auto status_font = MakeInterfaceFont(11, Gdiplus::FontStyleRegular);
        DrawDockLabel(graphics, L"缓冲中", status_font,
                      Gdiplus::PointF(37, 63), accent);
      } else {
        DrawDockLabel(graphics, time, font, Gdiplus::PointF(24, 64), quiet);
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
        Gdiplus::SolidBrush volume_thumb(
            Gdiplus::Color(255, 248, 248, 250));
        graphics.FillEllipse(
            &volume_thumb,
            Gdiplus::RectF(volume_start - 3 + 58 * volume_fraction,
                           controls_y - 3, 6, 6));
      }
      for (const auto& tool : tool_layout) {
        DrawHover(graphics, tool.first, tool.second, controls_y, 34);
        DrawToolIcon(graphics, tool.first, tool.second, controls_y);
      }
      graphics.Flush(Gdiplus::FlushIntentionSync);
      }
      PresentControlsSurface();
      return 0;
    }
    case WM_LBUTTONDOWN: {
      ShowControls();
      RECT rect{};
      GetClientRect(window, &rect);
      // 命中判定与绘制共用设计稿坐标系：物理坐标先除回缩放系数。
      const float scale = UiScale();
      const int x = static_cast<int>(GET_X_LPARAM(lparam) / scale);
      const int y = static_cast<int>(GET_Y_LPARAM(lparam) / scale);
      rect.right = static_cast<LONG>(std::lround(rect.right / scale));
      const int center = rect.right / 2;
      const bool compact = rect.right < 780;
      const ControlId hit = HitControl(x, y, rect.right);
      if (y <= 34 && g_duration.load() > 0) {
        // 进度条通屏：x=0 是屏幕左边缘，x=窗口宽度是右边缘。
        const double span = std::max(1.0, static_cast<double>(rect.right));
        const double fraction =
            std::clamp(static_cast<double>(x) / span, 0.0, 1.0);
        const std::string target = std::to_string(fraction * 100.0);
        MpvCommand("seek", target.c_str(), "absolute-percent");
        ShowAdjustHint(ClockLabel(fraction * g_duration.load()) + L" / " +
                           ClockLabel(g_duration.load()),
                       std::wstring(), kGlyphGauge,
                       static_cast<float>(fraction));
        g_hint_seek_percent = static_cast<int>(fraction * 100.0);
      } else if (hit == kReplay) {
        // 放在工具面板与中央按钮之前：窄窗下这颗胶囊的命中区可能与「后退 10 秒」
        // 碰上（失败态下 seek 本来就无效），恢复优先。
        ReplayAfterPlaybackFailure();
      } else if (hit == kAudio || hit == kSubtitle || hit == kDanmaku ||
                 hit == kPicture || hit == kSpeed || hit == kChapters ||
                 hit == kEpisodes || hit == kSegments || hit == kPlaylist) {
        OpenToolPanel(hit, DockAnchor(x));
      } else if (hit == kMore) {
        ShowOverflowMenu(rect.right, DockAnchor(x));
      } else if (x >= center - 28 && x <= center + 28) {
        // 失败态下这一键是「重新播放」：mpv 已经在 idle，cycle pause 没有任何
        // 效果 —— 用户报的「播放失败之后无法恢复」正是停在这一步。
        if (!ReplayAfterPlaybackFailure()) MpvCommand("cycle", "pause");
      } else if (!compact && x >= center - 166 && x < center - 116) {
        if (LoadPlaylistEntry(g_playlist_position.load() - 1)) {
          ShowToast("上一集");
        }
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
        if (LoadPlaylistEntry(g_playlist_position.load() + 1)) {
          ShowToast("下一集");
        }
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
      // 同上：不在这里刷新计时器，鼠标移动交给 timer 的真实位移判定。
      RECT rect{};
      GetClientRect(window, &rect);
      TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT), TME_LEAVE, window, 0};
      TrackMouseEvent(&tracking);
      // 命中判定与进度条换算都在设计稿坐标系里做。
      const float scale = UiScale();
      const int mouse_x = static_cast<int>(GET_X_LPARAM(lparam) / scale);
      const int mouse_y = static_cast<int>(GET_Y_LPARAM(lparam) / scale);
      rect.right = static_cast<LONG>(std::lround(rect.right / scale));
      if (mouse_y <= 32) {
        // 与绘制共用同一条换算：通屏进度条，x=0 是屏幕左边缘。
        const double span = std::max(1.0, static_cast<double>(rect.right));
        const double fraction = std::clamp(
            static_cast<double>(mouse_x) / span, 0.0, 1.0);
        g_seek_hover = fraction;
        if ((wparam & MK_LBUTTON) != 0 && g_duration.load() > 0) {
          const std::string target = std::to_string(fraction * 100.0);
          MpvCommand("seek", target.c_str(), "absolute-percent");
          const int percent = static_cast<int>(fraction * 100.0);
          // 拖动时只在整数百分比变化时重画提示，否则每一像素都会重建一次浮层。
          if (percent != g_hint_seek_percent) {
            g_hint_seek_percent = percent;
            ShowAdjustHint(ClockLabel(fraction * g_duration.load()) + L" / " +
                               ClockLabel(g_duration.load()),
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
      g_hover_control.store(hovered);
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    }
    case WM_MOUSELEAVE:
      g_seek_hover = -1;
      g_hint_seek_percent = -1;
      g_hint_volume_percent = -1;
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
    // 失败态下空格也是「重新播放」，与控件条的播放键同一条路；否则 cycle pause
    // 在 idle 的 mpv 上什么也不做，表现就是「按了没反应」。
    if (!ReplayAfterPlaybackFailure()) {
      MpvCommand("cycle", "pause");
      ShowAdjustHint(g_paused.load() ? L"继续播放" : L"已暂停", std::wstring(),
                     0, -1.0f);
    }
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

// 一帧：控件条的悬停/淡出、缓冲转圈、提示浮层、片头片尾倒计时、弹幕重绘。
// 由 wWinMain 里的高精度定时器驱动（拿不到时退回 WM_TIMER，两条路走的是
// 同一份实现）。以前这段直接写在 WM_TIMER 分支里：WM_TIMER 的最小周期被
// 系统时钟节拍卡在 15.6ms 的整数倍上，请求 16ms 实际拿到 31.25ms ——
// 弹幕层只有约 32fps，「一顿一顿」就是这么来的。
void TickFrame() {
  const double frame_now = NowMs();
  // 第一帧没有「上一帧」可比，用一个等于当前节拍的 dt：对齐刷新时是刷新周期 ×
  // 分频，退回定时器时才是 kFrameIntervalMs。只影响第一帧，但拿错了转圈/淡出会
  // 在起始那一下跳一下。
  const double frame_dt =
      g_last_frame_ms == 0.0
          ? (g_frame_divisor > 0 && g_refresh_period_ms > 0.0
                 ? g_refresh_period_ms * static_cast<double>(g_frame_divisor) /
                       1000.0
                 : static_cast<double>(kFrameIntervalMs) / 1000.0)
          : std::min(0.1, (frame_now - g_last_frame_ms) / 1000.0);
  g_last_frame_ms = frame_now;
  // 弹幕层：播放中每帧重画；暂停 / 缓冲时只在「设置改了 / 跳转了」之后重画一次
  // —— 画面本来就停着，每帧 memset 整层再合成一遍是白烧的 CPU。
  const bool danmaku_animating = !g_paused.load() && !g_buffering.load();
  if (g_danmaku_loaded && g_danmaku &&
      (danmaku_animating || g_danmaku_dirty)) {
    // WM_PAINT 是低优先级消息：只 InvalidateRect 会让稳定的 tick 在消息繁忙时
    // 延后 1 个刷新拍，随后又在下一拍追上，形成肉眼可见的 1/3 拍交替。弹幕层
    // 是独立 layered window，直接在节拍点提交即可；先验证掉可能残留的脏区，
    // 避免稍后再收到一次 WM_PAINT 而重复画同一帧。
    ValidateRect(g_danmaku, nullptr);
    PaintDanmaku();
  }
  // 玻璃里的背板会过期：视频还在放，背板却还是开菜单那一刻的画面。有浮层露着的时候
  // 按 kGlassBackdropRefreshMs 重抓一次，玻璃里的画面就跟着动 —— 原生没有
  // BackdropFilter，这是唯一能让它「活」起来的办法（节流在 UpdateGlassBackdrop 里，
  // 这里每次 tick 调一次也不会有额外开销）。
  const bool glass_visible = (g_controls && IsWindowVisible(g_controls)) ||
                             (g_top_bar && IsWindowVisible(g_top_bar)) ||
                             (g_panel && IsWindowVisible(g_panel)) ||
                             (g_hint && IsWindowVisible(g_hint));
  if (glass_visible) {
    static ULONGLONG presented_stamp = 0;
    const ULONGLONG stamp = g_backdrop.captured_at.load();
    if (stamp != 0 && stamp != presented_stamp) {
      presented_stamp = stamp;
      if (g_panel && IsWindowVisible(g_panel)) {
        InvalidateRect(g_panel, nullptr, FALSE);
      }
      if (g_hint && IsWindowVisible(g_hint)) {
        InvalidateRect(g_hint, nullptr, FALSE);
      }
      if (g_controls && IsWindowVisible(g_controls)) {
        InvalidateRect(g_controls, nullptr, FALSE);
      }
      if (g_top_bar && IsWindowVisible(g_top_bar)) {
        InvalidateRect(g_top_bar, nullptr, FALSE);
      }
    }
  }
  // 音量是连续量（拖一次音量条会连出几十个值），回写偏好要等手停下来。
  FlushPendingPlayerPreferences();
  // 重试之后已经稳稳放了十几秒：这一集算恢复正常，重试预算放开。
  // 否则「用掉唯一一次重试」之后哪怕过了半小时，再遇到真断流也不给补了。
  // g_retry_stamp 是 GetTickCount64 记的（见 ReportPlaybackFailure），这里必须用
  // 同一个时间源相减 —— 拿 QPC 的 frame_now 去减会得出一个负值，窗口永远不触发。
  if (g_retry_count > 0 &&
      GetTickCount64() - g_retry_stamp > kRetryHealthWindowMs) {
    g_retry_count = 0;
  }
  // 位置已经补回去：把「正在重试…」换成实际结果，别让提示自相矛盾。
  if (g_resume_done.exchange(false)) {
    ShowToast("连接中断，已从原位置继续");
    ShowControls();
  }
  if (AnimateControlHover() && g_controls) {
    InvalidateRect(g_controls, nullptr, FALSE);
  }
  if (AnimateTopHover() && g_top_bar) {
    InvalidateRect(g_top_bar, nullptr, FALSE);
  }
  // 提示浮层跟着控件条一起进退：控件条淡出时提示留着会更奇怪。
  // 例外是「N 秒后跳过片头」：它本来就是给「用户没在操作」的场景看的，
  // 控件条此时多半已经退场，跟着一起隐藏等于没有提示。
  if (g_hint_mode != HintMode::Hidden) {
    const bool expired = g_hint_mode == HintMode::Toast &&
                         GetTickCount64() > g_hint_until;
    if (expired || (g_controls_alpha == 0 && g_skip_index < 0)) HideHint();
  }
  // 片头片尾自动跳过：按当前播放位置判断是否进入片段，并按设置里的秒数
  // 倒计时（倒计时期间提示浮层就是取消入口的指引）。
  // 注意这里传的是 GetTickCount64：跳过倒计时的 g_skip_deadline 全流程都建立在
  // 它上面（提示浮层那边也用 GetTickCount64 比较），换成 QPC 会变成两套时间基准
  // 相减。它对精度的要求只是「几十毫秒级」，15.6ms 的粒度完全够用。
  UpdateAutoSkip(GetTickCount64());
  // 播放失败时中间那颗键是「重新播放」，图标就必须是播放三角：mpv 在 idle 时
  // pause 属性是 false，光看 g_paused 会画成双竖线（读作「点一下会暂停」），
  // 与它此刻真正会做的事正好相反。
  const float play_target =
      (g_paused.load() || g_playback_error.load()) ? 1.0f : 0.0f;
  const float play_delta = play_target - g_play_state_mix;
  if (std::abs(play_delta) > 0.001f) {
    const float play_limit = static_cast<float>(4.8 * frame_dt);
    g_play_state_mix += std::clamp(play_delta, -play_limit, play_limit);
    if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
  }
  if (g_buffering.load()) {
    g_buffer_phase = std::fmod(
        g_buffer_phase + static_cast<float>(440.0 * frame_dt), 360.0f);
    if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
  }
  // 自动隐藏看「光标最后一次在播放器窗口内移动」：轮询光标位置，动了且
  // 在窗口内就算一次交互；光标停在窗口里任何地方（画面、控件条都算）
  // 2.6 秒后，控件条、顶栏与光标一起退场。用户在窗口外打字或动鼠标不会
  // 打扰播放器的计时。
  POINT cursor{};
  bool cursor_moved = false;
  bool cursor_in_window = false;
  if (GetCursorPos(&cursor)) {
    const LONG dx = cursor.x - g_last_cursor.x;
    const LONG dy = cursor.y - g_last_cursor.y;
    // 3px 死区：光学鼠标静止时常有 ±1px 抖动，手搭在鼠标上不该把控件
    // 一直钉在屏幕上；参考点只在累计位移过阈值时刷新，缓慢漂移也算移动。
    if (dx * dx + dy * dy >= 9) {
      cursor_moved = true;
      RECT window_rect{};
      if (g_window && GetWindowRect(g_window, &window_rect) &&
          PtInRect(&window_rect, cursor)) {
        cursor_in_window = true;
        ShowControls();
      }
      g_last_cursor = cursor;
    }
  }
  const bool should_hide = GetTickCount64() - g_last_interaction > 2600 &&
                           !g_paused.load() &&
                           !(g_panel && IsWindowVisible(g_panel));
  if (FILE* trace = AutoHideTrace()) {
    std::fprintf(trace,
                 "tick=%llu cur=%ld,%ld moved=%d inwin=%d idle=%llu "
                 "hide=%d paused=%d panelvis=%d alpha=%d\n",
                 GetTickCount64(), cursor.x, cursor.y,
                 cursor_moved ? 1 : 0, cursor_in_window ? 1 : 0,
                 GetTickCount64() - g_last_interaction,
                 should_hide ? 1 : 0, g_paused.load() ? 1 : 0,
                 (g_panel && IsWindowVisible(g_panel)) ? 1 : 0,
                 static_cast<int>(g_controls_alpha));
    std::fclose(trace);
  }
  const BYTE target = should_hide ? 0 : 232;
  if (g_controls_alpha != target) {
    // 淡出约 480ms、淡入约 360ms，与改成 60fps 之前的观感一致；
    // 步长按经过时间算，帧率再变也不会忽快忽慢。
    const int step = should_hide
                         ? static_cast<int>(480.0 * frame_dt)
                         : static_cast<int>(638.0 * frame_dt);
    const int next = std::clamp(static_cast<int>(g_controls_alpha) +
                                    (should_hide ? -step : step),
                                0, 232);
    g_controls_alpha = static_cast<BYTE>(next);
    // 控件条走 ULW，淡入淡出只能靠重新呈现（SourceConstantAlpha），不能再调
    // SetLayeredWindowAttributes —— 两者互斥。这里复用同一块离屏面，只换 alpha，
    // 不重跑绘制。
    PresentControlsSurface();
    if (g_top_bar) {
      // 顶栏同样走 ULW：淡入淡出只能改 SourceConstantAlpha 后重新呈现，不能再
      // 调 SetLayeredWindowAttributes（两者互斥，调了内容直接失效）。
      PresentTopBarSurface();
    }
    if (g_controls_alpha == 0) {
      SetCursor(nullptr);
    } else if (next == 232) {
      SetCursor(LoadCursor(nullptr, IDC_ARROW));
    }
    // 退场后把命中测试也交还给画面（见 SetOverlayHitTest 的说明）。
    SetOverlayHitTest(g_controls_alpha > 0);
  }
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam) return 0;
      return DefWindowProcW(window, message, wparam, lparam);
    case WM_DISPLAYCHANGE:
      // 换显示器 / 改刷新率 / 开关全屏 / 显卡驱动切模式：帧节拍要跟着重算，
      // 否则会拿旧面板的刷新周期去分频，又变成非整数比（见 RefreshFramePacing）。
      RefreshFramePacing();
      return 0;
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
      // 顶部这条「顶栏带」整条都算标题栏：拖它可以移动窗口、双击最大化。
      //
      // 顶栏是独立的分层窗口，改成逐像素透明（ULW）之后它中间那片是**真透明**
      // —— 逐像素 alpha 下 alpha=0 的像素点击穿透，鼠标落到主窗口上，而主窗口
      // 此前把客户区一律判成 HTCLIENT，于是「播放器最上面拖不动了」。顶栏上的
      // 三个窗口按钮仍然不透明，照样收得到点击，不受这里影响。
      if (y - rect.top < Scaled(kTopBarHeight + kTopBarTopMargin)) {
        return HTCAPTION;
      }
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
    case kDanmakuReload:
      // 弹幕是播放开始后才拉到的：这里在主线程补建叠加窗口并读入数据。
      // 窗口必须由创建它的线程处理消息，所以不能在 stdin 线程里建。
      if (g_danmaku_enabled) {
        if (!g_danmaku) {
          CreateDanmakuWindow(
              reinterpret_cast<HINSTANCE>(GetModuleHandleW(nullptr)));
        }
        LoadDanmaku();
        PositionDanmaku();
      }
      return 0;
    case kApplyLiveSettings: {
      // 播放期间设置页改的设置（见 stdin 的 MOVA_APPLY）。窗口操作必须在
      // 创建弹幕层的线程上做，所以排队到这里逐个应用。
      std::vector<std::pair<std::string, std::string>> pending;
      {
        std::lock_guard<std::mutex> guard(g_live_mutex);
        pending.swap(g_live_pending);
      }
      for (const auto& item : pending) {
        ApplyLiveOption(item.first, item.second);
        // 回一行给应用侧：出错时「设置没生效」与「播发没送到」能一眼分开。
        char text[192]{};
        const int length =
            std::snprintf(text, sizeof(text), "MOVA_LIVE=%s|%s\r\n",
                          item.first.c_str(), item.second.c_str());
        const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (output && output != INVALID_HANDLE_VALUE && length > 0) {
          DWORD written = 0;
          WriteFile(output, text, static_cast<DWORD>(length), &written,
                    nullptr);
        }
      }
      return 0;
    }
    case kPlaylistAdvance:
      // 只有确认「真播完了」的 EOF 会走到这里（见 END_FILE 处的位置校验）。
      // 已经是最后一集时 LoadPlaylistEntry 会直接失败，播放器停在片尾。
      LoadPlaylistEntry(g_playlist_position.load() + 1);
      return 0;
    case kPlaybackInterrupted:
      // 同一集先补一次再认输：源站在跳转那一刻新建连接，偶发抖动会让 mpv 把
      // 这一集判成结束，而地址本身通常还是好的。用户报的「自动跳过会存在播放
      // 失败」就是这条路径——自动跳片头会让播放器去要一段新的字节区间，正好
      // 撞上抖动的概率比顺放时高得多。
      if (g_running.load() && g_retry_count < kMaxInterruptRetries &&
          RetryCurrentEpisode()) {
        ++g_retry_count;
        ShowToast("播放中断，正在重试…");
        if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
        ShowControls();
        return 0;
      }
      g_playback_error = true;
      // 失败态单独留一条轨迹：只看 MOVA_ENDFILE / MOVA_RETRY 的话，「自动重试
      // 也用尽」这一步在日志里是隐含的，只能靠数错误次数猜。恢复路径要靠它断言。
      std::fprintf(stdout, "MOVA_FAILED=%lld|%.3f\r\n",
                   static_cast<long long>(g_playlist_position.load()),
                   g_last_valid_position.load());
      std::fflush(stdout);
      // 文案要给动作，不能只说状态：原来这里是「已停在当前位置」，用户看完
      // 不知道该做什么，于是就成了「播放失败之后无法恢复」。
      ShowToast("播放中断 · 点播放键重新播放");
      if (g_controls) InvalidateRect(g_controls, nullptr, FALSE);
      ShowControls();
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
    case WM_SETCURSOR: {
      // 退场期间光标必须保持隐藏。命中测试已经交还给画面，但系统每移动一次
      // 光标还是会问一次 WM_SETCURSOR，这里直接按住不放。
      if (g_controls_alpha == 0) {
        SetCursor(nullptr);
        return TRUE;
      }
      return DefWindowProcW(window, message, wparam, lparam);
    }
    case WM_MOUSEMOVE:
      // 这里以前无条件 ShowControls()。mpv 以 wid 嵌入主窗口后，即使光标
      // 一动不动也会周期性重投 WM_MOUSEMOVE（实测约每 500 ms 一次，坐标
      // 一字不差），计时器被不断清零，控件条和光标就永远不会自动隐藏。
      // 现在鼠标移动只由 50 ms timer 里「位移 ≥3px 且落在窗口内」的轮询
      // 负责刷新，合成消息进不来。
      return 0;
    case WM_LBUTTONDBLCLK:
      ToggleFullscreen();
      return 0;
    case WM_TIMER:
      // 拿不到高精度可等待定时器时的回退节拍（见 wWinMain 里建定时器的地方）。
      TickFrame();
      return 0;
    case WM_KEYDOWN:
      ShowControls();
      if (RunShortcut(static_cast<int>(wparam))) return 0;
      return DefWindowProcW(window, message, wparam, lparam);
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
  // 类光标留空：光标显隐完全跟着控件条走（ShowControls 里设箭头、控件退场时
  // 设 null）。若在这里挂 ARROW，控件隐藏后每一次鼠标微动都会经 WM_SETCURSOR
  // 把光标重新点亮，出现「面板退场了光标还亮着」。
  window_class.hCursor = nullptr;
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
  WNDCLASSW danmaku_class{};
  danmaku_class.hInstance = instance;
  danmaku_class.lpszClassName = kDanmakuClass;
  danmaku_class.lpfnWndProc = DanmakuProc;
  danmaku_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&danmaku_class);

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
  // 默认窗口按工作区的 92% 开，并夹在 1280×760（旧默认，保证不会缩得比以前还
  // 小）到 1920×1160 之间。以前固定 1280×760，在 2K / 4K 屏上只占中间一小块，
  // 画面和逐字弹幕都偏小。
  const int window_width =
      std::min(work_width, std::max(1280, std::min(1920, work_width * 92 / 100)));
  const int window_height =
      std::min(work_height,
               std::max(760, std::min(1160, work_height * 92 / 100)));
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
  // 控件条刻意**不调** SetLayeredWindowAttributes：它由 UpdateLayeredWindow 呈现
  // （逐像素 alpha），两者互斥，调了会让窗口内容失效。淡入淡出见 TickOverlay。
  g_top_bar = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kTopBarClass,
                              L"", WS_POPUP, 0, 0, 1, 1, window, nullptr,
                              instance, nullptr);
  // 顶栏也刻意**不调** SetLayeredWindowAttributes：它由 UpdateLayeredWindow
  // 逐像素呈现（右上角那几个按钮要真半透明的玻璃），两者互斥。
  // 淡入淡出见 TickOverlay 的 PresentTopBarSurface()。
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
  // 给底部播放控件留出字幕安全区。默认 100% 会把内嵌字幕压在控制按钮后面。
  SetOption(g_handle, "sub-pos", "84");
  // 光标隐藏由窗口的 50ms timer 统一管理（控件条与光标同进退）；mpv 自己的
  // autohide 与它各管各的，会出现「控件退场了光标还亮着」的分裂状态。
  SetOption(g_handle, "cursor-autohide", "no");

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
        } else if (name == "mova-playlist-resume") {
          // 每集一条（可为空 = 这一集没有观看记录）。换集时按它设 mpv 的 start，
          // 见 g_playlist_resumes 与 ApplyPlaylistStart。
          const std::wstring value = argument.substr(equals + 1);
          g_playlist_resumes.push_back(
              value.empty() ? 0.0 : std::strtod(Utf8(value).c_str(), nullptr));
        } else if (name == "mova-start") {
          // 本次起播的续播点。**故意不做成 mpv 的 `--start=`**：那个是普通选项，
          // 换文件时不会重置，会把这一集的起点染到后面每一集上（见 g_playlist_resumes）。
          g_initial_position = std::strtod(Utf8(argument.substr(equals + 1)).c_str(),
                                           nullptr);
          g_initial_position_explicit = true;
        } else if (name == "start") {
          // 兜底：仍然接受 mpv 自己的 `--start=<秒>`（探针、手工调试、旧调用方都
          // 在用它指定起播点）。只把它记成「本次起播点」，**不再交给 mpv** ——
          // 交给它就会被应用到之后每一次 loadfile 上，正是这次要修的那个 bug。
          // `--mova-start` 明确给过值时以它为准。
          if (!g_initial_position_explicit) {
            g_initial_position = std::strtod(
                Utf8(argument.substr(equals + 1)).c_str(), nullptr);
          }
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
        } else if (name == "mova-seek-seconds" ||
                   name == "mova-volume-step") {
          // 与播放期间的热更新同一份实现（见 ApplyLiveOption）。
          ApplyLiveOption(name, Utf8(argument.substr(equals + 1)));
        } else if (name == "mova-danmaku-file") {
          g_danmaku_path = argument.substr(equals + 1);
        } else if (IsLiveSettingName(name)) {
          // 与播放期间的热更新（stdin 的 MOVA_APPLY）共用一份实现：起播是
          // 「第一次应用」，之后设置页再改就是就地更新。
          ApplyLiveOption(name, Utf8(argument.substr(equals + 1)));
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
      g_media_urls.push_back(Utf8(argument));
    }
  }
  LocalFree(argv);
  while (g_playlist_titles.size() < g_media_urls.size()) {
    g_playlist_titles.push_back(g_media_title);
  }
  while (g_playlist_details.size() < g_media_urls.size()) {
    g_playlist_details.emplace_back();
  }
  // 并行下发的数组都补齐到同一长度，免得面板里按下标取数据时越界。
  while (g_playlist_seasons.size() < g_media_urls.size()) {
    g_playlist_seasons.emplace_back();
  }
  while (g_playlist_episodes.size() < g_media_urls.size()) {
    g_playlist_episodes.emplace_back();
  }
  while (g_playlist_episode_titles.size() < g_media_urls.size()) {
    g_playlist_episode_titles.emplace_back();
  }
  while (g_playlist_images.size() < g_media_urls.size()) {
    g_playlist_images.emplace_back();
  }
  while (g_playlist_meta.size() < g_media_urls.size()) {
    g_playlist_meta.emplace_back();
  }
  while (g_playlist_progress.size() < g_media_urls.size()) {
    g_playlist_progress.push_back(-1.0);
  }
  while (g_playlist_durations.size() < g_media_urls.size()) {
    g_playlist_durations.push_back(0.0);
  }
  while (g_playlist_watched.size() < g_media_urls.size()) {
    g_playlist_watched.push_back(false);
  }
  while (g_playlist_resumes.size() < g_media_urls.size()) {
    g_playlist_resumes.push_back(0.0);
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

  if (g_mpv.initialize(g_handle) < 0 || g_media_urls.empty()) {
    MessageBoxW(window, L"播放器初始化失败或没有可播放的地址。",
                L"Mova 原生播放器", MB_ICONERROR);
    g_mpv.terminate_destroy(g_handle);
    g_handle = nullptr;
    return 5;
  }

  if (g_danmaku_enabled && !g_danmaku_path.empty()) {
    CreateDanmakuWindow(instance);
    LoadDanmaku();
    PositionDanmaku();
  }

  g_mpv.observe_property(g_handle, 1, "time-pos", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 2, "duration", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 3, "pause", MPV_FORMAT_FLAG);
  g_mpv.observe_property(g_handle, 4, "volume", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 5, "mute", MPV_FORMAT_FLAG);
  g_mpv.observe_property(g_handle, 6, "speed", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(g_handle, 7, "paused-for-cache", MPV_FORMAT_FLAG);
  // 不再 observe mpv 的 playlist-pos：列表里只有一项，它恒为 0，会把我们
  // 自己维护的集索引冲掉（Dart 侧靠这个索引切缓存、预加载下一集）。
  g_mpv.observe_property(g_handle, 9, "brightness", MPV_FORMAT_DOUBLE);
  // 只把当前这一集交给 mpv。整季都塞进播放列表时，mpv 在任何 end-file 之后
  // （含读取出错）都会自动前进到下一项 —— 实测证实了 keep-open=yes 也拦不住，
  // 这才是「播到一半突然跳下一集」的根因。换集一律走 LoadPlaylistEntry()。
  const int start_index =
      (playlist_start > 0 &&
       playlist_start < static_cast<int>(g_media_urls.size()))
          ? playlist_start
          : 0;
  g_playlist_position = start_index;
  // 起播这一集用应用给的精确位置（可能来自服务器端进度，比「观看比例 × 时长」
  // 估出来的准），覆盖 playlist 里的那一项。
  if (!g_playlist_resumes.empty() &&
      start_index < static_cast<int>(g_playlist_resumes.size())) {
    g_playlist_resumes[static_cast<size_t>(start_index)] = g_initial_position;
  }
  if (!g_media_urls.empty()) {
    // 起播点必须显式设进 mpv：以前这一步是命令行 `--start=` 代劳的，但那个选项
    // 会一直留到后面每一次 loadfile（见 g_playlist_resumes 的注释）。
    ApplyPlaylistStart(start_index);
    const char* load[] = {"loadfile",
                          g_media_urls[static_cast<size_t>(start_index)].c_str(),
                          "replace", nullptr};
    g_mpv.command(g_handle, load);
  }
  ShowWindow(window, show_command);
  UpdateWindow(window);
  // 帧节拍的主路径现在是「对齐合成器的整数拍」（见 RefreshFramePacing 与主循环
  // 里的 DwmFlush 分支），这一段定时器只在「拿不到刷新周期 / 窗口不可见 / 暂停」
  // 时兜底。
  //
  // 曾经的历史：SetTimer(window, 1, 16) 的周期会被向上取整到系统时钟节拍
  // （15.6ms）的整数倍，请求 16ms 实际拿到 31.25ms → 弹幕只有约 32fps。换成
  // 可等待定时器（Win10 1803+ 的高精度模式）之后才稳定在 16.7ms。但 16.7ms 本身
  // 仍然与面板刷新率无关，在 170Hz 面板上每帧停留 2.77 个周期（非整数）→ 位移
  // 步长 3:2 交替。这才是「还是不够平滑」的根因。
  RefreshFramePacing();
  timeBeginPeriod(1);
  HANDLE frame_timer = nullptr;
  if (HINSTANCE kernel32 = GetModuleHandleW(L"kernel32.dll")) {
    using CreateWaitableTimerExW_fn = HANDLE(WINAPI*)(LPSECURITY_ATTRIBUTES,
                                                      LPCWSTR, DWORD, DWORD);
    const auto create_timer =
        reinterpret_cast<CreateWaitableTimerExW_fn>(reinterpret_cast<void*>(
            GetProcAddress(kernel32, "CreateWaitableTimerExW")));
    if (create_timer) {
      // 0x1 = CREATE_WAITABLE_TIMER_MANUAL_RESET 不用；0x2 = HIGH_RESOLUTION。
      frame_timer = create_timer(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
    }
  }
  if (frame_timer) {
    LARGE_INTEGER due{};
    due.QuadPart = -10000;  // 100ns 单位：1ms 后第一次触发
    SetWaitableTimer(frame_timer, &due, kFrameIntervalMs, nullptr, nullptr,
                     FALSE);
  } else {
    SetTimer(window, 1, kFrameIntervalMs, nullptr);
  }
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
        // \r 不能留：应用侧 writeln 写的是 \r\n，路径行带 \r 会让文件打不开。
        // 数值行靠 strtod 忽略尾部垃圾侥幸没事，字符串行就不行了。
        std::string line = pending.substr(0, newline);
        pending.erase(0, newline + 1);
        while (!line.empty() && line.back() == '\r') line.pop_back();
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
        } else if (line.rfind("MOVA_DANMAKU_STATUS=", 0) == 0) {
          const std::string value = line.substr(20);
          if (value.rfind("loading", 0) == 0) {
            g_danmaku_loading = true;
            g_danmaku_error.clear();
          } else if (value.rfind("error:", 0) == 0) {
            g_danmaku_loading = false;
            g_danmaku_error = Wide(value.substr(6));
          } else {
            g_danmaku_loading = false;
          }
        } else if (line.rfind("MOVA_DANMAKU_INFO=", 0) == 0) {
          // 条数 \t 命中的 API 名 \t 匹配到的作品 / 集
          const std::string value = line.substr(18);
          const size_t t1 = value.find('\t');
          const size_t t2 = t1 == std::string::npos
                                ? std::string::npos
                                : value.find('\t', t1 + 1);
          g_danmaku_count = std::atoi(value.c_str());
          if (t1 != std::string::npos) {
            g_danmaku_source = Wide(value.substr(
                t1 + 1, t2 == std::string::npos ? std::string::npos
                                                : t2 - t1 - 1));
          }
          if (t2 != std::string::npos) {
            g_danmaku_matched = Wide(value.substr(t2 + 1));
          }
        } else if (line.rfind("MOVA_DANMAKU=", 0) == 0) {
          // 应用侧在播放开始后把弹幕写到这里，原生侧热加载，不必重开播放器。
          g_danmaku_path = Wide(line.substr(13));
          g_danmaku_loading = false;
          g_danmaku_error.clear();
          PostMessageW(g_window, kDanmakuReload, 0, 0);
        } else if (line.rfind("MOVA_SEGMENT_STATUS=", 0) == 0) {
          const std::string value = line.substr(20);
          if (value.rfind("loading", 0) == 0) {
            // 换集时先到的那条 loading 会把上一集的片段清掉：面板里挂着上一集
            // 的片头时间点比什么都不显示更糟，自动跳过也会跳到错误的位置。
            g_segments_loading = true;
            g_segments_error.clear();
            g_segments_pending.clear();
            {
              std::lock_guard<std::mutex> guard(g_segments_mutex);
              g_segments.clear();
            }
          } else if (value.rfind("error:", 0) == 0) {
            g_segments_loading = false;
            g_segments_error = Wide(value.substr(6));
          } else if (value.rfind("note:", 0) == 0) {
            // 「未找到 / 已在设置里关闭全部来源」这类说明：不算失败，但要如实
            // 告诉用户为什么面板里是空的。
            g_segments_loading = false;
            g_segments_error = Wide(value.substr(5));
          } else {
            g_segments_loading = false;
          }
        } else if (line.rfind("MOVA_SEGMENT=", 0) == 0) {
          // <类型>|<开始秒>|<结束秒>|<来源>
          const std::string value = line.substr(13);
          const size_t first = value.find('|');
          const size_t second = first == std::string::npos
                                    ? std::string::npos
                                    : value.find('|', first + 1);
          const size_t third = second == std::string::npos
                                   ? std::string::npos
                                   : value.find('|', second + 1);
          if (third != std::string::npos) {
            SegmentItem segment;
            const std::string kind = value.substr(0, first);
            if (kind == "recap") segment.kind = SegmentKind::recap;
            else if (kind == "credits") segment.kind = SegmentKind::credits;
            else if (kind == "preview") segment.kind = SegmentKind::preview;
            segment.start = std::strtod(value.c_str() + first + 1, nullptr);
            segment.end = std::strtod(value.c_str() + second + 1, nullptr);
            segment.provider = Wide(value.substr(third + 1));
            g_segments_pending.push_back(std::move(segment));
          }
        } else if (line.rfind("MOVA_SEGMENTS_DONE=", 0) == 0) {
          // 一次下发的全部片段到齐了，整体替换（见 ApplyPendingSegments）。
          g_segments_loading = false;
          ApplyPendingSegments();
          PostMessageW(g_window, kPlayerStateChanged, 0, 0);
        } else if (line.rfind("MOVA_APPLY=", 0) == 0) {
          // 播放期间设置页改了弹幕 / 片头片尾 / 播放器偏好：<参数名>|<值>。
          // 入队交给主线程应用 —— 改区域要重新贴合弹幕窗口、重绘也要在窗口
          // 自己的线程上做，stdin 线程只负责收。
          const std::string value = line.substr(11);
          const size_t divider = value.find('|');
          if (divider != std::string::npos &&
              IsLiveApplyName(value.substr(0, divider))) {
            {
              std::lock_guard<std::mutex> guard(g_live_mutex);
              g_live_pending.emplace_back(value.substr(0, divider),
                                          value.substr(divider + 1));
            }
            PostMessageW(g_window, kApplyLiveSettings, 0, 0);
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
      if (event->event_id == MPV_EVENT_END_FILE && event->data) {
        const auto* end = static_cast<mpv_event_end_file*>(event->data);
        // 结束原因原样吐给应用侧：以后再遇到「播到一半跳集」，看这一行就能
        // 分清是正常播完（0）还是读取出错（4），不用靠猜。
        //
        // 后面几段是给「自动跳过之后报播放失败」准备的证据：光看 reason 分不出
        // 「真的断流」和「我们自己发起的 seek / loadfile 把当前文件打断了」，
        // 把当时的播放位置、总时长和 mpv 的错误码一并带出来才判得准。应用侧只
        // 认 MOVA_POSITION / MOVA_COMPLETED / MOVA_RESOURCE / MOVA_SETTING，
        // 不认识这一行，加长字段是安全的。
        std::fprintf(stdout,
                     "MOVA_ENDFILE=%d|%lld|played=%.3f|duration=%.3f"
                     "|error=%d|eof=%d|aborted=%d\r\n",
                     static_cast<int>(end->reason),
                     static_cast<long long>(g_playlist_position.load()),
                     g_last_valid_position.load(), g_duration.load(),
                     static_cast<int>(end->error),
                     end->reason == MPV_END_FILE_REASON_EOF ? 1 : 0,
                     end->reason == MPV_END_FILE_REASON_ERROR ? 1 : 0);
        if (end->reason == MPV_END_FILE_REASON_EOF) {
          // 断流同样可能被报成 EOF：ffmpeg 会把连接中断当成「读到结尾」。
          // 只认 reason 就连播，就仍然是「卡一下跳下一集」，所以再校验一次
          // 位置——离片尾太远的 EOF 一律按中断处理，停在原地不前进。
          const double duration = g_duration.load();
          const double played = g_last_valid_position.load();
          const bool reached_end =
              duration <= 0.0 || played >= duration - kEofGraceSeconds;
          if (!reached_end) {
            std::fprintf(stdout, "MOVA_SUSPECT_EOF=%.3f|%.3f\r\n", played,
                         duration);
            std::fflush(stdout);
            PostMessageW(window, kPlaybackInterrupted, 0, 0);
          } else {
            std::fprintf(stdout, "MOVA_COMPLETED=%lld\r\n",
                         static_cast<long long>(g_playlist_position.load()));
            std::fflush(stdout);
            // mpv 的自动前进已被 keep-open=yes 关掉，连播由主线程显式推进。
            PostMessageW(window, kPlaylistAdvance, 0, 0);
          }
        } else if (end->reason == MPV_END_FILE_REASON_ERROR) {
          // 缓冲耗尽 / 源站报错都会被 mpv 记成 end-file。以前它紧接着就会
          // 前进到下一集（表现为「卡一下就跳集」），现在停在原地并给出提示。
          PostMessageW(window, kPlaybackInterrupted, 0, 0);
        }
      }
      if (event->event_id == MPV_EVENT_FILE_LOADED) {
        g_playback_error = false;
        // 中断重试：文件加载完了才把位置补回去（加载中发 seek 会落空）。
        const double resume = g_resume_seconds.exchange(0);
        if (resume > 0 && g_handle) {
          const std::string target = std::to_string(resume);
          const char* args[] = {"seek", target.c_str(), "absolute", nullptr};
          g_mpv.command(g_handle, args);
          g_resume_done = true;
        }
        PostMessageW(window, kPlayerStateChanged, 0, 0);
      }
      if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->data) {
        auto* property = static_cast<mpv_event_property*>(event->data);
        if (property->format == MPV_FORMAT_DOUBLE && property->data) {
          const double value = *static_cast<double*>(property->data);
          if (property->name && std::string(property->name) == "time-pos") {
            g_position = value;
            g_position_tick = NowMs();
            if (value > 0.0) g_last_valid_position = value;
            // 暂停时位置只会在拖动进度条时动，这时要重画一次动画静止的弹幕层
            // （播放中每帧都画，用不到这个标记）。
            if (g_paused.load()) g_danmaku_dirty = true;
          } else if (property->name && std::string(property->name) == "duration") {
            // 只认正值：换集时 mpv 会在旧文件卸载的瞬间报一次 duration=0，
            // 收下它会让「离片尾多远」的判定失去参照（duration<=0 一律当成
            // 已经播到结尾），那一次 0 就能把断流误判成正常播完。
            if (value > 0.0) g_duration = value;
          } else if (property->name && std::string(property->name) == "volume") {
            g_volume = value;
            // 音量从哪改的（面板、快捷键、滚轮、拖音量条）都会走到这里，统一在
            // 这里记账，改完等手停下来再回写一次偏好。
            NoteVolumeForPreference(value);
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
        }
        // playlist-pos 不再观察：mpv 里始终只有当前一集，它恒为 0，而我们
        // 自己的集索引由 LoadPlaylistEntry() 维护（见那里的注释）。
      }
    }
  });

  // 背板采集与 CPU 模糊不能跑在 UI 帧循环里。后台线程只处理可见玻璃区域，
  // 持续产出最新帧，
  // UI 只在 TickFrame 中发现新时间戳后重绘，不再等待采集完成。
  std::atomic<bool> glass_backdrop_done{false};
  std::thread glass_backdrop([&glass_backdrop_done] {
    while (g_running) {
      const bool visible =
          (g_controls && IsWindowVisible(g_controls)) ||
          (g_top_bar && IsWindowVisible(g_top_bar)) ||
          (g_panel && IsWindowVisible(g_panel)) ||
          (g_hint && IsWindowVisible(g_hint));
      if (visible) UpdateGlassBackdrop(false);
      // UpdateGlassBackdrop 自己按 16ms 节流。这里只让出一个时间片，
      // 避免原先的 8ms 睡眠把可达刷新率直接压到 30–40Hz。
      Sleep(1);
    }
    glass_backdrop_done = true;
  });

  MSG message{};
  bool pumping = true;
  while (pumping) {
    if (frame_timer) {
      if (FramePacingWanted()) {
        // 等自己的高精度节拍时钟到点（一个 tick = divisor × 刷新周期）。
        //
        // **不在这里调 DwmFlush**：它的返回本身就在 1 拍/2 拍之间跳，把 tick 挂在
        // 它上面等于把这份抖动搬进 paint 间隔（实测 dwell 落成 2/3/4 拍不规则混合，
        // 只有 4–8.5% 恰好 1 拍）。相位只在建表时用一次 DwmFlush 对齐（见
        // RebuildPacingTimer），之后靠「周期严格等于整数拍」保持同相。
        //
        // 同时等消息：定时器（index 0）比消息就绪（index 1）优先，所以不会因为
        // 一直在处理消息而饿掉 tick；也能让消息一到位就处理，不必等满一个周期。
        const DWORD wait_result = MsgWaitForMultipleObjects(
            1, &g_pacing_timer, FALSE, INFINITE, QS_ALLINPUT);
        if (wait_result == WAIT_OBJECT_0) {
          const double tick_now = NowMs();
          if (g_tick_last_ms > 0.0) {
            const double tick_gap = tick_now - g_tick_last_ms;
            g_tick_sum_ms += tick_gap;
            ++g_tick_count;
            // 节拍间隔的分布：和绘制的 dwell 配对读，才知道该往定时器还是往
            // 绘制派发路径上找问题（见 g_tick_dwell 的说明）。
            g_tick_gap_max = std::max(g_tick_gap_max, tick_gap);
            if (g_refresh_period_ms > 0.0) {
              const long long periods =
                  std::lround(tick_gap / g_refresh_period_ms);
              const int bucket = static_cast<int>(
                  periods < 1 ? 1 : (periods > 4 ? 4 : periods));
              ++g_tick_dwell[bucket];
            }
          }
          g_tick_last_ms = tick_now;
          g_tick_now_ms = tick_now;
          TickFrame();
          ++g_pacing_tick;
          ArmNextPacingTick();
        } else {
          // 有消息先处理，但**这一轮没有走 tick**：定时器若已触发就会一直保持
          // 触发态，下一轮立刻返回，于是量出一个远短于 period 的间隔。计数它。
          if (wait_result != WAIT_TIMEOUT) ++g_msg_wakes;
        }
      } else {
        // 画面停着 / 窗口不可见 / 拿不到刷新周期：回到定时器节拍。
        // 有帧定时器就阻塞等「定时器到点」或「有消息」，哪边都不落空：以前那种
        // 纯 GetMessage 的循环要靠 WM_TIMER 才有节拍，而 WM_TIMER 的周期被系统
        // 时钟节拍限死（见上面建定时器处的说明）。
        const DWORD wait_result = MsgWaitForMultipleObjects(
            1, &frame_timer, FALSE, INFINITE, QS_ALLINPUT);
        if (wait_result == WAIT_OBJECT_0) TickFrame();
      }
    }
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        pumping = false;
        break;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (!frame_timer) {
      // 回退到 WM_TIMER 节拍的模式：没有消息就阻塞等着。
      if (PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE)) continue;
      WaitMessage();
    }
  }
  g_running = false;
  // 节拍时钟也是内核对象，退出前要拆掉（DisarmPacingTimer 内部判空）。
  DisarmPacingTimer();
  if (frame_timer) {
    CancelWaitableTimer(frame_timer);
    CloseHandle(frame_timer);
  } else {
    KillTimer(window, 1);
  }
  // 与 timeBeginPeriod 配对。漏掉它会让系统时钟一直停在 1ms 粒度上，
  // 本机其他程序的待机电耗会明显上升。
  timeEndPeriod(1);
  // PrintWindow can synchronously send messages to this thread. Keep servicing
  // them until capture exits, otherwise joining here can deadlock shutdown.
  while (!glass_backdrop_done) {
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) continue;
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  if (glass_backdrop.joinable()) glass_backdrop.join();
  if (events.joinable()) events.join();
  if (g_handle) {
    g_mpv.terminate_destroy(g_handle);
    g_handle = nullptr;
  }
  // GdiplusShutdown 会卸载 gdiplus.dll；这些全局 GDI+ 对象必须在它之前释放，
  // 否则进程退出时它们的析构函数会调用已失效的 Gdip* 并触发访问冲突（0xC0000005）。
  ReleaseGlyphCache();
  ReleaseDanmakuSurface();
  // 背板那两张全窗位图（各 32bpp，和整屏同量级）里的 Gdiplus::Bitmap 同样是 GDI+
  // 对象，必须在 GdiplusShutdown 之前释放。
  ReleaseGlassBackdrop();
  // 控件条那块 32bpp 面里的 Gdiplus::Bitmap 同样是 GDI+ 对象，必须在
  // GdiplusShutdown 之前释放（否则收尾时析构踩到已卸载的 Gdip*，0xC0000005）。
  delete g_controls_surface;
  g_controls_surface = nullptr;
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
