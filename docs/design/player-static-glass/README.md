# Mova 播放器 · 静态玻璃设计交付

这是设计交付，不是已部署的播放器实现。直接打开 `preview.html` 可查看两张 1600 × 900 设计画板：完整播放页，以及全部提示、控件状态和二级菜单样本。`tokens.css` 是布局和材质的可编辑视觉源文件，`cinematic-background.png` 仅为原创演示底图；生产界面必须使用真实媒体画面和数据。

## 文件

- `preview.html`：可编辑的两张设计画板，含自绘 SVG 图标，按 1600 × 900 一比一排版。
- `player-overview.svg`：可直接查看的完整播放页矢量预览；细节与状态以 HTML/CSS 画板为准。
- `tokens.css`：玻璃材质、按钮、菜单、提示、排版、位置和状态的完整样式。
- `cinematic-background.png`：原创电影感演示底图；不应加入生产应用。
- `implementation.md`：与 Windows 原生播放器的绘制映射、外观联动、动效和验收基准。
- `../../specs/2026-09-30-player-static-glass.md`：实施规格草案。

## 设计原则

画面优先；不把视频像素抓取到控件背板。三种组件共享一块静态材质：石墨中性色叠层、上缘微光、内缘高光、薄白描边、轻投影。通过固定图层模拟玻璃的雾化与清透感，而不是在运行时截取或模糊当前视频帧。外观设置改变材质的雾化强度，不改变尺寸和布局；视频切换时材质不跳变。

图片生成提示（内置 imagegen，原图保存在交付目录）："Create ONLY a photorealistic cinematic 16:9 film-frame background plate for a premium desktop video player UI design mockup. Original fictional scene, no existing movie, no recognizable actor, no logos, no words, no subtitles, no UI, no borders. A quiet contemporary train interior at blue hour, one adult traveler in silhouette seated by a large rain-speckled window, distant city lights and warm amber reflections, restrained deep navy / charcoal / muted copper palette, elegant natural film lighting, atmospheric but not busy. Keep the lower 22% and upper 13% visually calm enough for white translucent player controls; central image should remain interesting. Sharp image with soft depth of field, realistic skin if visible, no illustration. Full-bleed landscape composition."
