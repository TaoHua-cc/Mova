# 详情页资源版本弹窗重复边框

- 日期：2026-10-05；范围：Windows/Android 共用详情页；局部修复。
- 改前：showModalBottomSheet 背景虽透明，仍继承全局 BottomSheetTheme 带描边 shape；内部 GlassPanel 自有描边，形成两个弹窗框。
- 改后：只在 _showResourcePicker 显式使用无描边 shape、零 elevation、关闭主题拖动手柄；GlassPanel 为唯一背板。资源行选中描边和勾选保留，切换回调/音轨字幕重置不改；不改全局主题。
- ponytail：修复现有入口的主题继承，不新增组件或依赖。固定玻璃不采样；无存储/网络/权限变化，无版本变更。
- 3 项回归测试通过：源码接线、390px/1280px 真实 BottomSheet 组件在带边框主题下不再继承边框，GlassPanel 仅一层。格式化及 diff 检查通过，修改文件静态检查无 error/warning。
- 双端 release 构建通过，静态检查 0 issues。已部署 Windows `D:/Mova`：主应用未运行，原生播放器仍有进程，本次先恢复标准 GPU-next 库并逐文件比较哈希，仅更新发生变化的 app.so，未覆盖使用中的未变播放器文件或结束进程。app.so SHA256 `A9BCA1861E877603E8BE2CE3DC8BC69B743FD8333EAA9D34E46452C1FFAFD7AB`。
- 已部署 OPPO OPD2401：用户确认退出、核对无进程，使用既有本地 `com.taohua.mova.debug` 包名 `adb install -r` 返回 Success，不新增应用。APK SHA256 `959BF6E8F9993BA622E206DD0C6695389F057AC79D7BD71BA1AAF76B7DB51214`。双端保留用户数据与已有改动，未提交/推送/发版；没有重复执行全套测试，本轮为局部针对性验证。
- 实机验收路径：详情页资源版本打开/滚动/选择/关闭，核对只剩面板外框和资源选中框；自动测试未代替实机视觉验收。已有 Exo 菜单性能阻断和上架长测不在本次处理。
