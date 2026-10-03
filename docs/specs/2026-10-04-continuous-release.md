# 双端 3.1.120（131）预发布

- 用户明确授权双端推送与发布，并选择预发布版；沿用 main → Mova Continuous，不创建正式版本 tag。
- 范围：已交付的更新弹窗、网页 Trakt 授权、Android 自动画中画、海报轮播动画、SubHD 字幕搜索与分类及已下载字幕保留、Windows 零拷贝解码、跳过提示描边进度、键盘焦点与艺术图预览外框修复。
- 本轮完整 `flutter test`：367 项通过。`dart analyze lib test` 无错误/警告，25 项 info；不将源码接线检查视为真机行为验证。
- Windows Release 构建通过，固定 libmpv SHA256 校验通过；确认程序退出后覆盖 D:/Mova，应用二进制哈希与构建产物一致。Android Release 构建成功，OPPO OPD2401 同包 install -r 成功，versionName=3.1.120、versionCode=131，lastUpdateTime=2026-10-04 01:17:35，保留数据。无本轮长测成功结论。
- 已知限制：Android Exo 菜单卡顿未改善，用户要求暂停排查；保留诊断记录，不宣称修复。mpv 杜比色彩兼容亦未完成。未执行本轮双端 30 分钟候选版播放及管线 60 分钟长测、全路径性能三次采样、公开售卖合规核查。
- 版本号同步三处，Android buildCode 从 130 增至 131；保留现有持久化键与升级数据。本地 Android 仍覆盖 com.taohua.mova.debug，公开 APK 的签名由 CI 验证。
- 排除本地 SDK、轨迹、临时探针和二进制文件。GitHub 构建与附件发布成功前，不报告已发版。
