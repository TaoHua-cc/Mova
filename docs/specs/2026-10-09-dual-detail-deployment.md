# 双端本地详情更新部署记录

- 范围：剧集末端展示、默认已完成后的下一集、电影系列及同页切换、弹窗选中防裁切。
- Windows：安装 app.so 与最新 release 构建 SHA256 均为 5DDC9D7E0A20ABBF86A018CCC907114E64B57BA3259A282A4F9DB189E9D6C516，已部署，无需再次覆盖。未改原生播放器。
- Android：OPPO f9f3a649，原包 com.taohua.mova.debug，部署前未运行。初次 ORG_GRADLE_PROJECT_movaLocalTest 环境属性未生效，生成/误装正式包 com.taohua.mova；已移除本次新装的第二包，原 debug 应用及数据未卸载/清理。
- 纠正：Flutter 构建必须传 --android-project-arg=movaLocalTest=true（或显式 Gradle -PmovaLocalTest=true）。安装前必须将 aapt 解析的包名与目标包名程序化比较，不匹配时立即失败，不能仅打印包名后继续安装。
- 验证：此前针对性测试通过，Windows release 构建成功；Android 正在以显式属性重新构建，安装/真机复测待记录。
- 数据策略：adb install -r 覆盖原包，禁止 uninstall 原 com.taohua.mova.debug 或清理应用数据。未发布/推送。
- 最终结果：显式属性 Android release 构建成功，aapt 程序化断言 com.taohua.mova.debug / Mova / 3.1.123+134 后 adb install -r 返回 Success；平板仅剩原包，lastUpdateTime=2026-10-09 16:31:58。双端已本地部署，设置及观看数据保留；实际 UI/性能真机复测未执行，不把安装成功当功能全部验收。
