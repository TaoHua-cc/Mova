# Android 普通后台恢复与图片重显

日期：2026-10-02；平台：Android；状态：验证中。

## 背景与目标

用户明确：普通 Home 手势与再次进入时卡顿，图片重显；上轮 o-stop 是后续主动移除任务，不是原卡顿原因。普通切换样本 pid 31517 保持，未发现新增进程启动。目标是减少热返回图片/渲染资源重建，保留系统动画和真实低内存释放。

## 检查与方案

当前 Flutter SDK Android delegate 在首帧后对 level >= 10 一律发送 Dart/引擎内存压力；UI_HIDDEN=20 只表示界面不可见，也落入此分支。PaintingBinding.handleMemoryPressure 清理非 live 图片缓存，发动引擎清理也可能导致纹理重上传。尚需自然手势日志确认 UI_HIDDEN 是否实际出现，不能把代码路径当作全部症状已证明。

在 MainActivity 仅对 UI_HIDDEN 不转发低内存通知，仍转发 renderer/platform view 资源提示；其余所有等级及 onLowMemory 保持 Flutter 默认行为。测试包仅日志记录整数等级/进程/生命周期，不记录图片 URL、账号或令牌。没有新增权限、保活服务或持久化键；Windows 不变。实测无收益则撤回此策略。

## 验证

剩余单次停顿的第二轮诊断：复用 FrameTrace 的 MOVA_TRACE_FRAME_LOGCAT 编译开关，仅诊断构建启用生命周期缓存数量与恢复后六帧耗时；默认构建不注册监听，日志不含图片地址或凭据。暂不改变生产渲染策略。采样完成后以默认关闭的构建覆盖测试版，避免持续诊断开销。

Android Release 构建、针对性回归测试；自然 Home→桌面→图标进入确认 pid 保持和通知等级，随后复测海报与动画。真实低内存逻辑必须仍调用 super；不把 Activity 启动时间当帧率。横竖屏、Exo/mpv 正常进入与退出列为回归风险，未实测需明确说明。

## 实现记录

### 剩余单次卡顿：诊断结果

2026-10-02 显式启用 MOVA_TRACE_FRAME_LOGCAT 的 Release 测试包已临时部署。诊断进程 pid 3384 保持。可读取的一组热返回样本：02:26:38.916 hidden/paused 与 02:26:39.094 resumed，均为 images=42、bytes=53355308、pending=0。恢复后三帧 build_us=116/1480/815，raster_us=23409/33402/42873，totalSpan_us=51515/35762/70353；当时面板预算20ms，三帧均为 raster 超预算而不是 Dart build 超预算。另一次前置窗口有 raster 最大49.02ms。该样本位于 depth=.637、pos=514.3（首页/发现过渡区），不是纯首页/纯发现对照。

结论限于：剩余停顿已定位到恢复阶段 GPU 光栅侧；非进程重启或 Dart 图片缓存整体清空。pending=0 不能证明不存在后台网络请求；不能据此断言具体为纹理重上传、某个模糊滤镜或 Surface 重建。atrace 同时见 Flutter SurfaceView 与 Activity 窗口分别合成，尚未完成每个 GPU 调用的耗时归因。后续用户操作的 logcat 已被密集系统日志覆盖，未拿到第二组完整数据，避免声称重复验证。此次仅增加默认关闭的诊断日志，未改变生产渲染路径、动画、图片质量；采样后默认关闭诊断的 Release 包重新覆盖平板。静态分析保持19项既有info，帧诊断10项测试通过。Windows 不部署。

用户自然 Home 往返复测反馈：有改善，比之前好很多，但仍有一次卡顿。此反馈支持 UI_HIDDEN 误触发清理是实际开销之一；不是全部卡顿的唯一原因。保留试修，后续需针对剩余恢复首帧采样，不将系统 Surface 重建/纹理上传写成已经证实的根因。

普通后台往返前后 pid 31517 保持，未新增 am_proc_start/am_kill。MainActivity 的 UI_HIDDEN 分支保留 renderer/platformViews 的 trim 提示，不触发 delegate 的 DartExecutor.notifyLowMemoryWarning/SystemChannel.sendMemoryPressureWarning；其余级别继续 super。未变更 onLowMemory、系统后台权限或动画速度。测试版保留整数级别日志用于自然手势核对。

Android 测试版 Release 构建成功，平板覆盖安装成功；302 项 Flutter 测试通过，分析无错误/警告（19 项既有 info）。2026-10-02 02:15:55 自然后台切换捕获 MovaMemory trim=20、pid=32467，随后 pid 仍为 32467，确认设备确实收到 UI_HIDDEN。用户主观改善和新版帧率待反馈/采样，不能断言所有卡顿已解决。Windows 无原生代码改动，不重新部署。播放器、旋转及真正内存压力条件未完成真机复测。
