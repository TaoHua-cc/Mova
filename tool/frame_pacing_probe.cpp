// 量「弹幕帧节拍」与「显示器刷新 / DWM 合成节拍」的关系。
//
// 为什么需要它：2026-09-19 把弹幕时间源从 GetTickCount64 换成 QPC 之后，帧间隔
// 均值已经贴住 16.4ms（≈61fps），既有诊断（MOVA_TRACE_DANMAKU 的 avg / late20 /
// late33）就此判「合格」。但用户仍然反馈滚动不够平滑 —— 说明「均值达标」不足以
// 描述「看起来连不连续」。位置是每帧按 (时钟 - 出现时刻) x 速度 现算的，内部时钟
// 再准，**帧变成像素的节拍**如果和显示器刷新不同源，投到屏幕上的位移序列就仍然
// 是抖的。两种情况都能让均值好看：
//
//   (A) 节拍错拍（beat）：请求周期 16ms -> 62.5Hz，而 60Hz 面板是 16.667ms。
//       两者差 4%，每约 25 帧就有一帧挤进上一个刷新周期里、根本没被显示，
//       下一帧位移翻倍 —— 滚动文字上就是每秒 2~3 次「顿一下」。
//   (B) 相位漂移：即便帧数对得上，ULW 提交时刻与 DWM 合成时刻的相对相位一直在
//       漂，屏幕上那一帧的「年龄」在 0~16.7ms 之间变化，视觉速度就等于在
//       ±100% 之间抖。
//
// 均值、late20、late33 对这两种都无感（没有哪一帧特别慢），所以单独量：
//
//   * 帧间隔直方图（1ms 分箱）—— 看是单峰还是「16/16/33」这种拍频三峰；
//   * 刷新桶分布 —— 相邻两帧之间隔了几个刷新周期，理想恒定 1x；
//   * 间隔的变异系数 cv = std/mean —— 位移抖动的直接代理，理想 0；
//   * 对照策略 B（每次提交后 DwmFlush 相位锁定）—— 证明这抖动是可去掉的。
//
// 用法：frame_pacing_probe.exe [秒数] [周期ms]      默认 5 秒 / 16ms

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

double Frequency() {
  static const double value = [] {
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    return static_cast<double>(f.QuadPart);
  }();
  return value;
}

double NowMs() {
  LARGE_INTEGER counter{};
  QueryPerformanceCounter(&counter);
  return static_cast<double>(counter.QuadPart) * 1000.0 / Frequency();
}

struct Stats {
  std::vector<double> intervals;
  double mean = 0.0;
  double stddev = 0.0;
  double cv = 0.0;
  double max = 0.0;

  void Compute() {
    if (intervals.empty()) return;
    double sum = 0.0;
    for (double v : intervals) sum += v;
    mean = sum / static_cast<double>(intervals.size());
    double acc = 0.0;
    for (double v : intervals) acc += (v - mean) * (v - mean);
    stddev = std::sqrt(acc / static_cast<double>(intervals.size()));
    cv = mean > 0.0 ? stddev / mean : 0.0;
    max = *std::max_element(intervals.begin(), intervals.end());
  }
};

void PrintStats(const char* label, const Stats& s, double refresh_ms,
                int ideal_bucket = 1) {
  std::printf("--- %s ---\n", label);
  std::printf("  frames=%d  mean=%.3f ms  std=%.3f ms  cv=%.4f  max=%.2f ms\n",
              static_cast<int>(s.intervals.size()), s.mean, s.stddev, s.cv,
              s.max);
  if (s.intervals.empty() || refresh_ms <= 0.0) return;

  // 1ms 分箱直方图，只打非零档。
  int bins[128]{};
  for (double v : s.intervals) {
    int b = static_cast<int>(v + 0.5);
    if (b < 0) b = 0;
    if (b > 127) b = 127;
    ++bins[b];
  }
  std::printf("  histogram(1ms bins):");
  for (int i = 0; i < 128; ++i) {
    if (bins[i] > 0) std::printf(" %dms:%d", i, bins[i]);
  }
  std::printf("\n");

  // 「相邻两帧隔了几个刷新周期」。理想是全部落在 ideal_bucket × refresh。
  int bucket[6]{};
  for (double v : s.intervals) {
    int b = static_cast<int>(std::lround(v / refresh_ms));
    if (b < 0) b = 0;
    if (b > 5) b = 5;
    ++bucket[b];
  }
  const double total = static_cast<double>(s.intervals.size());
  std::printf("  dwell-buckets(理想 %dx):", ideal_bucket);
  for (int i = 0; i <= 5; ++i) {
    if (bucket[i] > 0) {
      std::printf(" %dx:%.2f%%", i, 100.0 * bucket[i] / total);
    }
  }
  std::printf("\n");

  // 偏离理想拍的帧占比 —— 也就是「肉眼上每秒会顿几次」。
  const int ideal = (ideal_bucket >= 0 && ideal_bucket <= 5) ? ideal_bucket : 1;
  const int deviating = static_cast<int>(total) - bucket[ideal];
  if (deviating > 0) {
    const double per_second =
        static_cast<double>(deviating) / (total * s.mean / 1000.0);
    std::printf("  偏离 %dx 的帧占比=%.2f%%  ->  约 %.2f 次/秒的节拍偏差\n",
                ideal, 100.0 * deviating / total, per_second);
  } else {
    std::printf("  偏离 %dx 的帧占比=0.00%%  ->  无节拍偏差\n", ideal);
  }
}

}  // namespace

/// 忙等 `ms` 毫秒：模拟「一个 tick 里除 flush 之外的工作量」（TickFrame +
/// WM_PAINT 合成整层弹幕，实测 1–4ms）。策略 D 用它检验「有负载时绝对日程还
/// 能不能保持严格整数拍」。
void BusyWork(double ms) {
  const double until = NowMs() + ms;
  volatile double sink = 0.0;
  while (NowMs() < until) sink += 1.0;
  (void)sink;
}

/// 与 main.cpp 的 ArmNextPacingTick 同构：**绝对日程**重排，不用 lPeriod。
///
/// lPeriod 的单位是整毫秒，11.764ms 只能喂 12/11 交替 → 自造错拍；而且每轮
/// 都「从现在起一个周期」会把唤醒延迟逐轮累加成漂移。这里一律从锚点算
/// `anchor + tick × period`，只有真的漏了不止半拍才挪锚点。
struct Pacer {
  HANDLE timer = nullptr;
  double period_ms = 0.0;
  double anchor = 0.0;
  long long tick = 1;

  bool Create() {
    timer = CreateWaitableTimerExW(
        nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        TIMER_ALL_ACCESS);
    if (!timer) timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    return timer != nullptr;
  }
  void Arm() {
    if (!timer) return;
    const double target = anchor + static_cast<double>(tick) * period_ms;
    double delay = target - NowMs();
    if (delay < 0.05) {
      if (delay < -period_ms * 0.5) {
        anchor = NowMs() - static_cast<double>(tick) * period_ms;
      }
      delay = 0.05;
    }
    LARGE_INTEGER due{};
    due.QuadPart = -static_cast<LONGLONG>(delay * 10000.0);
    SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
  }
  void Start(double refresh, int divisor) {
    period_ms = refresh * static_cast<double>(divisor);
    anchor = NowMs();
    tick = 1;
    Arm();
  }
  void Stop() {
    if (timer) CloseHandle(timer);
    timer = nullptr;
  }
};

/// 跑一遍「绝对日程 + 高精度可等待定时器」，返回实测间隔。
Stats RunAbsolute(Pacer& pacer, int frames, double work_ms) {
  Stats stats;
  double previous = 0.0;
  for (int i = 0; i < frames; ++i) {
    const DWORD wait =
        MsgWaitForMultipleObjects(1, &pacer.timer, FALSE, INFINITE, QS_ALLINPUT);
    if (wait != WAIT_OBJECT_0) break;
    const double now = NowMs();
    if (previous > 0.0) stats.intervals.push_back(now - previous);
    previous = now;
    // 顺序与主循环一致：先排下一拍，再干活（main.cpp 里 ArmNextPacingTick 在
    // 派发 WM_PAINT 之前）。
    ++pacer.tick;
    pacer.Arm();
    if (work_ms > 0.0) BusyWork(work_ms);
  }
  stats.Compute();
  return stats;
}

int wmain(int argc, wchar_t** argv) {
  double seconds = 5.0;
  int period_ms = 16;
  int divisor = 2;
  if (argc > 1) {
    const double parsed = _wtof(argv[1]);
    if (parsed > 0.1) seconds = parsed;
  }
  if (argc > 2) {
    const int parsed = _wtoi(argv[2]);
    if (parsed > 0) period_ms = parsed;
  }
  if (argc > 3) {
    const int parsed = _wtoi(argv[3]);
    if (parsed > 0) divisor = parsed;
  }
  const int target_frames = static_cast<int>(seconds * 1000.0 / period_ms);

  std::printf("=== display / composition timing ===\n");
  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  double nominal_ms = 0.0;
  if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &mode)) {
    nominal_ms = mode.dmDisplayFrequency > 1
                     ? 1000.0 / static_cast<double>(mode.dmDisplayFrequency)
                     : 0.0;
    std::printf("  EnumDisplaySettings(CURRENT): %lux%lu @ %lu Hz (%.3f ms)\n",
                static_cast<unsigned long>(mode.dmPelsWidth),
                static_cast<unsigned long>(mode.dmPelsHeight),
                static_cast<unsigned long>(mode.dmDisplayFrequency),
                nominal_ms);
  } else {
    std::printf("  EnumDisplaySettings(CURRENT): failed (%lu)\n", GetLastError());
  }
  DEVMODEW reg{};
  reg.dmSize = sizeof(reg);
  if (EnumDisplaySettingsW(nullptr, ENUM_REGISTRY_SETTINGS, &reg)) {
    std::printf("  EnumDisplaySettings(REGISTRY): %lux%lu @ %lu Hz\n",
                static_cast<unsigned long>(reg.dmPelsWidth),
                static_cast<unsigned long>(reg.dmPelsHeight),
                static_cast<unsigned long>(reg.dmDisplayFrequency));
  }

  double refresh_ms = nominal_ms;
  DWM_TIMING_INFO timing{};
  timing.cbSize = sizeof(timing);
  const HRESULT dwm = DwmGetCompositionTimingInfo(nullptr, &timing);
  if (SUCCEEDED(dwm) && timing.qpcRefreshPeriod > 0) {
    const double from_dwm = static_cast<double>(timing.qpcRefreshPeriod) *
                            1000.0 / Frequency();
    std::printf("  DWM: qpcRefreshPeriod=%.1f -> %.3f ms (%.2f Hz)"
                "  rateCompose=%llu  cRefresh=%llu\n",
                static_cast<double>(timing.qpcRefreshPeriod), from_dwm,
                1000.0 / from_dwm,
                static_cast<unsigned long long>(timing.rateCompose.uiDenominator),
                static_cast<unsigned long long>(timing.cRefresh));
    refresh_ms = from_dwm;
  } else {
    std::printf("  DWM: DwmGetCompositionTimingInfo failed (hr=0x%08lX) -> "
                "退回按 EnumDisplaySettings 的标称值\n",
                static_cast<unsigned long>(dwm));
  }
  std::printf("  => 用于判据的刷新周期: %.3f ms\n", refresh_ms);

  timeBeginPeriod(1);

  // ---- 策略 A：与播放器现状一致（周期可等待定时器 + MsgWaitForMultipleObjects）
  HANDLE timer = nullptr;
  if (HINSTANCE kernel32 = GetModuleHandleW(L"kernel32.dll")) {
    using CreateWaitableTimerExW_fn = HANDLE(WINAPI*)(LPSECURITY_ATTRIBUTES,
                                                      LPCWSTR, DWORD, DWORD);
    const auto create_timer =
        reinterpret_cast<CreateWaitableTimerExW_fn>(reinterpret_cast<void*>(
            GetProcAddress(kernel32, "CreateWaitableTimerExW")));
    if (create_timer) {
      timer = create_timer(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
    }
  }
  Stats current;
  if (timer) {
    std::printf("\n=== strategy A: periodic waitable timer, period=%d ms "
                "(播放器现状) ===\n", period_ms);
    LARGE_INTEGER due{};
    due.QuadPart = -10000;
    SetWaitableTimer(timer, &due, period_ms, nullptr, nullptr, FALSE);
    double previous = 0.0;
    for (int i = 0; i < target_frames; ++i) {
      const DWORD wait = MsgWaitForMultipleObjects(1, &timer, FALSE, INFINITE,
                                                   QS_ALLINPUT);
      if (wait != WAIT_OBJECT_0) break;
      const double now = NowMs();
      if (previous > 0.0) current.intervals.push_back(now - previous);
      previous = now;
    }
    current.Compute();
    PrintStats("A: 现状（16ms 周期，与刷新不同源）", current, refresh_ms);
  } else {
    std::printf("\n=== strategy A 跳过：拿不到高精度可等待定时器 ===\n");
  }

  // ---- 策略 B：每次提交后 DwmFlush，把节拍锁到合成回路上
  std::printf("\n=== strategy B: DwmFlush() 相位锁定 ===\n");
  Stats flushed;
  {
    double previous = 0.0;
    for (int i = 0; i < target_frames; ++i) {
      DwmFlush();
      const double now = NowMs();
      if (previous > 0.0) flushed.intervals.push_back(now - previous);
      previous = now;
    }
    flushed.Compute();
    PrintStats("B: DwmFlush 每条一次", flushed, refresh_ms);
  }

  // ---- 策略 C/D：与 2026-09-22 的新实现一致（高精度定时器 + 绝对日程重排，
  //      周期 = divisor × 刷新周期）。C 空转、D 带一个 tick 的绘制负载。
  //
  // 为什么要在探针里单独跑：应用里 dwell 是「1 拍 / 3 拍」两峰而不是全 2 拍，
  // 可能是 (a) 这条定时器路径本身在这台机器上就不稳，也可能是 (b) 应用主循环
  // 里的其它工作量把它挤歪了。C 与 D 的差别正好把这两种因果分开。
  const int abs_frames = static_cast<int>(seconds * 1000.0 /
                                           (refresh_ms * divisor));
  std::printf("\n=== strategy C: 高精度定时器 + 绝对日程, 空转"
              " (period=%.3fms = %.3fms x %d) ===\n",
              refresh_ms * divisor, refresh_ms, divisor);
  Stats absolute;
  {
    Pacer pacer;
    if (pacer.Create()) {
      pacer.Start(refresh_ms, divisor);
      absolute = RunAbsolute(pacer, abs_frames, 0.0);
      pacer.Stop();
      PrintStats("C: 只有定时器，无其它工作", absolute, refresh_ms, divisor);
    } else {
      std::printf("  跳过：拿不到高精度可等待定时器\n");
    }
  }

  std::printf("\n=== strategy D: 同上 + 每拍 %.1fms 绘制负载 ===\n", 3.0);
  Stats loaded;
  {
    Pacer pacer;
    if (pacer.Create()) {
      pacer.Start(refresh_ms, divisor);
      loaded = RunAbsolute(pacer, abs_frames, 3.0);
      pacer.Stop();
      PrintStats("D: 每拍 3ms 负载（贴近弹幕满屏）", loaded, refresh_ms,
                 divisor);
    } else {
      std::printf("  跳过：拿不到高精度可等待定时器\n");
    }
  }

  // ---- 对照：各策略的节拍抖动比
  std::printf("\n=== 结论 ===\n");
  if (!current.intervals.empty() && !flushed.intervals.empty()) {
    std::printf("  cv: A=%.4f  B=%.4f  ->  A 的位移抖动是 B 的 %.1f 倍\n",
                current.cv, flushed.cv,
                flushed.cv > 0.0 ? current.cv / flushed.cv : 0.0);
    std::printf("  A 的周期 %d ms 与刷新 %.3f ms 的比值=%.4f"
                "（越接近 1 越好；整数比之外的都是错拍）\n",
                period_ms, refresh_ms,
                static_cast<double>(period_ms) / refresh_ms);
  }
  if (!absolute.intervals.empty()) {
    std::printf("  C（绝对日程，空转）：cv=%.4f  max=%.2fms  -> %s\n",
                absolute.cv, absolute.max,
                absolute.cv < 0.01 ? "定时器路径本身是稳的，抖动来自应用主循环"
                                   : "定时器路径本身就不稳");
  }
  if (!loaded.intervals.empty()) {
    std::printf("  D（绝对日程，3ms 负载）：cv=%.4f  max=%.2fms\n",
                loaded.cv, loaded.max);
  }

  if (timer) CloseHandle(timer);
  timeEndPeriod(1);
  return 0;
}
