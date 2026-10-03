# 艺术图预览外壳

- 复现：详情艺术图放大时先出现大框；两处Dialog透明背景但继承app.dart全局DialogTheme描边。
- 修改：两处明确无边框shape、elevation0、透明shadow/tint；保留图片约束/加载/关闭与已有动效，不改发现配色，仅提出低饱和深墨青建议。
- 验证：接线测试1项通过，详情页静态检查无问题，格式化完成；Windows构建部署待完成。共享代码Android受影响，Android本轮未构建/部署，需后续复核。视觉闪框修复实际效果待人工确认，不把源码检查作为视觉验收。
- 用户数据/版本/网络不变；回退仅撤销两处Dialog属性。保留并一起交付此前键盘焦点修复，不推送发布。
- Windows Release构建成功；部署前确认无运行程序，GPU-next库校验安装后覆盖D:\Mova，mova.exe与MovaNativePlayer.exe哈希核对。两项实际用户行为/视觉复测仍待完成；Android未部署。
