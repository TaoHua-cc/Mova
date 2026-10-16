# 恢复详情页季栏拖动

- 根因：季栏已有 MovaHorizontalDrag，但 physics 使用 yingjiWheelPhysics，Windows 返回 NeverScrollableScrollPhysics，鼠标拖动被禁止；同类剧集预览、资源横栏亦存在该配置。
- 按 ponytail 在三处横向栏去掉该覆盖，复用已有 BouncingScrollPhysics，保持竖向平滑滚轮配置不变。点击选季、选中居中逻辑不改，安卓保留原弹性物理。
- 验证：鼠标拖动产生偏移且不误触点击，普通点击仍触发；接线检查三个横栏不能引入桌面禁止滚动物理。格式化及静态检查；不改数据、存储或取流，不新增依赖。
- 本次未构建部署、未推送发版，双端真实详情页手势仍待复核。保留此前片单、筛选及发行记录改动。

## 本地部署记录

- 用户要求后，使用现有脚本构建 Windows Release、替换受校验 gpu-next libmpv 并覆盖 `D:\Mova`，数据保留；四个关键文件哈希一致。
- 2 项拖动回归通过、静态检查无错误/警告（24 项既有 info）。实际季栏拖动仍需用户确认；安卓未部署，不推送发版。按 ponytail 复用现有构建部署流程。
