# 映迹视觉系统 v3

## Direction

年轻家庭媒体库播放器，参考 Apple TV 的内容优先、空间层级和焦点浏览，但保持 Windows 桌面效率。第一视口先展示内容，再展示工具；玻璃只承载浮动控制和分组，不把每一块内容包成卡片。

## Contract

- **THESIS**：把“打开就想看”的大图内容和“我自己的服务器”放在同一条自然路径里，拒绝传统影音器材感和后台仪表盘感。
- **OWN-WORLD**：冷白 / 深海蓝自适应底色，半透明冰晶玻璃，蓝紫环境光，薄荷与钴蓝交互色，珊瑚色只表达提醒；现代中文无衬线、宽松留白、圆角 18–24px。
- **STORY**：用户先从海报和榜单发现内容，焦点态告诉他当前选择，详情页再逐层展开集数、资源、演员和预告，最后进入 mpv 播放。
- **FIRST VIEWPORT**：左侧 72px 图标栏，右侧内容占满；首页 60% 高度用于实时海报和标题，首个榜单只露出一排大海报，焦点项通过放大与玻璃高光表达。
- **FORM**：内容优先的焦点式画廊，seed=user-pinned-apple-tv-glass-v3。
- **FINISH**：unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md

## Tokens

| Token | Light | Dark |
| --- | --- | --- |
| Canvas | `#EEF4FA` | `#071426` |
| Glass | `rgba(255,255,255,.68)` | `rgba(17,35,64,.68)` |
| Ink | `#102541` | `#F5F9FF` |
| Secondary | `#5B7391` | `#AFC2DF` |
| Focus | `#2C6BFF` | `#79A8FF` |
| Play | `#B9F56A` | `#B9F56A` |
| Alert | `#F27D8A` | `#FF9BA7` |

## Component grammar

Glass navigation and tool surfaces use blur 24–32px, 1px low-contrast highlight, and a soft 0 18px 48px shadow. Poster surfaces use 16px radius, 2:3 ratio, and a 3px focus halo only on focus. Shelves scroll horizontally with snap points. Lists use hairline rhythm and never nest cards inside cards.

## Motion

Hero changes cross-fade with a 360ms critically damped spring feel. Poster focus uses scale 1.04 and 180ms. Navigation expansion uses 300ms with no overshoot. Reduced motion replaces all scale and translation with opacity and color changes.
