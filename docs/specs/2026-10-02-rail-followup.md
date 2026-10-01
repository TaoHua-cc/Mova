# 列表位置、拖动与悬浮补修

两端共享详情，Windows发现页；2026-10-02。聚合搜索每次产生新episodes列表对象触发目录轨居中：改为只在选择变化或首次空列表变为就绪时居中。资源流式返回不抢用户已浏览位置。

详情演员/艺术图/相似推荐三栏仍使用桌面NeverScrollableScrollPhysics，禁用了已接入的鼠标拖动：仅三栏改为原生Bouncing+AlwaysScrollable，纵向平滑滚轮保持不变。标题Wrap改Row，Expanded标题让全部列表按钮始终靠右，保留空态。

发现卡片清除滚动中hover后，鼠标未再次enter就不会恢复：独立保存pointerInside，停稳恢复hover；滚动快照关闭后的postframe更新MouseTracker命中，确保当前鼠标下海报更新。榜单预览仍在滚动期间取消，停稳后恢复。

无持久化/版本/协议改动；回归测试、静态检查、双端构建部署。搜索真实多个服务器返回、静止鼠标下滚轮停稳、三个栏目的触控板/鼠标实际观感待人工复核。

验证结果：313项测试通过，静态检查无错误/警告，20项info。双端Release构建成功；Windows本地覆盖D:/Mova且app.so哈希一致，安卓平板f9f3a649安装Success。未推送或发版。
