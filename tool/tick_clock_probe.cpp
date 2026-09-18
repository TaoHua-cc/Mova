// 量 GetTickCount64 与 QPC 的实际粒度，复刻播放器的用法（先 timeBeginPeriod(1)）。
//
// 为什么需要它：弹幕位置的公式是 (动画时钟 - 出现时刻) × 速度。如果时钟本身是
// 15.6ms 一格的，位置就一步跳 15.6ms 的距离，而帧间隔只有 16.3ms —— 大多数帧
// 算出来「没动」、偶尔跳两倍，滚动就是「一顿一顿」。文档说 GetTickCount64 的
// 分辨率「通常 10~16ms，且可能受 timeBeginPeriod 影响」，措辞含糊，所以直接量。
//
// 用法：tick_clock_probe.exe [秒数]      默认 2 秒

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <map>

int wmain(int argc, wchar_t** argv) {
  int seconds = 2;
  if (argc > 1) {
    const int parsed = _wtoi(argv[1]);
    if (parsed > 0) seconds = parsed;
  }
  const int duration_ms = seconds * 1000;

  // 与播放器一致：把系统时钟粒度提到 1ms 再采样，否则量到的是默认节拍。
  timeBeginPeriod(1);

  LARGE_INTEGER frequency{};
  QueryPerformanceFrequency(&frequency);

  std::map<unsigned long long, int> tick_deltas;
  std::map<unsigned long long, int> qpc_deltas;
  ULONGLONG previous_tick = GetTickCount64();
  LARGE_INTEGER previous_qpc{};
  QueryPerformanceCounter(&previous_qpc);
  const ULONGLONG start = previous_tick;
  long long samples = 0;

  while (GetTickCount64() - start < static_cast<ULONGLONG>(duration_ms)) {
    const ULONGLONG tick = GetTickCount64();
    if (tick != previous_tick) {
      ++tick_deltas[tick - previous_tick];
      previous_tick = tick;
    }
    LARGE_INTEGER counter{};
    QueryPerformanceCounter(&counter);
    const double microseconds =
        static_cast<double>(counter.QuadPart - previous_qpc.QuadPart) * 1e6 /
        static_cast<double>(frequency.QuadPart);
    if (microseconds >= 1000.0) {  // 按 1ms 粒度归并，便于和 tick 比
      ++qpc_deltas[static_cast<unsigned long long>(microseconds / 1000.0)];
      previous_qpc = counter;
    }
    ++samples;
  }
  timeEndPeriod(1);

  std::printf("sampled %lld iterations in %d ms\n\n", samples, duration_ms);
  std::printf("GetTickCount64 advancing steps (ms -> count):\n");
  unsigned long long tick_floor = 0;
  for (const auto& entry : tick_deltas) {
    std::printf("  %llu ms  x%d\n", entry.first, entry.second);
    if (tick_floor == 0 && entry.first > 1) tick_floor = entry.first;
  }
  std::printf("  -> smallest step above 1ms = %llu ms\n\n", tick_floor);

  std::printf("QPC steps >= 1ms (ms -> count):\n");
  for (const auto& entry : qpc_deltas) {
    std::printf("  %llu ms  x%d\n", entry.first, entry.second);
  }
  std::printf("\nVERDICT %s\n", tick_floor > 1
                                     ? "GetTickCount64 IS quantised"
                                     : "GetTickCount64 resolution is fine");
  return 0;
}
