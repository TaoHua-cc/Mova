# 弹窗选中边框防裁切

- 复现：详情资源切换列表选中项左右白边被裁掉。
- 根因：_DetailCardMotion 将选中卡片放大 1.025，宽度超过 ListView 裁切范围。音轨字幕预选也复用该组件。
- 修复：资源/音轨行取消放大，保留底色、选中图标、内侧边框和阴影；弹窗内详情海报及通用磨砂卡片禁用悬浮放大/平移，普通页面海报效果不变。双端共享。
- 源码检查：全局 YingjiMotionSurface 和通用圆形按钮只按压缩小；全部剧集行使用该安全组件；发现/设置通用 FrostSurface、艺术图/推荐弹窗海报存在悬浮放大，已按 PopupRoute 禁用。未逐个真机实测全部弹窗，不声明全部已验证。
- 验证计划：资源/音轨/字幕弹窗首尾项、全部列表边缘卡片，宽窄窗口与触控/鼠标；既有布局及系列切换回归。
- 验证结果：popup_selection_bounds_test、detail_origin_transition_test、movie_collection_navigation_test 共 17 项通过。包含源码回归约束及通用选中组件宽窄裁切列表几何测试，不等同于所有弹窗截图验收。
- 静态检查：无 error/warning，media_center 4 条既有 info；格式化及 diff --check 通过。Windows release 构建成功并覆盖主程序/data，保留用户数据，未替换原生播放器。Android 未构建/部署；双端实际截图人工验证仍待完成。
- 不改数据格式与播放取流。Windows 原生菜单未发现选中放大代码，本次不修改其绘制；不宣称已经对所有原生菜单做截图验收。
