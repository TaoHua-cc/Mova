# Third-party notices

## Interface typeface

- Alimama FangYuanTi VF 1.000, copyright 2023 Alibaba (China) Co., Ltd. —
  Mova uses the variable FangYuan typeface for its Flutter interface and
  Windows native player. Font metadata identifies Alibaba Design as the
  manufacturer. The bundled file's SHA-256 is
  `b0b8c4c057af7dbc6ccb52a3ad00138fed41d1ad37d4f4a666b6cd431c913d94`.
  The Windows native player uses a static instance generated from the same
  font at weight 600 and `BEVL=100`; its SHA-256 is
  `69116eab7144f8d600a4ca626b64ddc5be12ed77b7a9b1eee692f31177132d47`.
- Noto Sans SC remains bundled only as a fallback for characters outside the
  FangYuan font's coverage.

## Interface icons

- Iconsax: https://iconsax.io/ — Mova's Flutter interface uses the
  `iconsax_flutter` package, and the Windows native player uses a small set of
  integrated, adapted control glyphs following the same visual language.
  Icons remain subject to the Iconsax Free License and are not distributed as
  a standalone icon pack: https://docs.iconsax.io/license-and-terms/license

## Metadata services

Rating platform logos identify their respective rating sources and remain the property of their respective owners. Image provenance: https://github.com/Druidblack/jellyfin_ratings/tree/main/logo . No endorsement is implied; public distribution remains subject to the applicable owners' permissions.

- TMDB: https://www.themoviedb.org/ — This product uses the TMDB API but is not endorsed or certified by TMDB.
- MDBList: https://mdblist.com/ — Aggregated ratings retain their original source and scale. Availability varies by title. Public distribution and caching remain subject to provider permissions.
- TVmaze: https://www.tvmaze.com/ — Broadcast metadata from the TVmaze API (https://www.tvmaze.com/api), licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). Episode timestamps are converted to the user's local timezone; original date-only precision is retained. The license applies to TVmaze data, including redistributed adaptations.

映迹包含 Electron 与 mpv 运行时。

mpv Windows x64 build: shinchiro/mpv-winbuild-cmake release `20260814`, asset `mpv-x86_64-20260814-git-7b8915bc1d.7z`.

- mpv source and license information: https://github.com/mpv-player/mpv
- Windows build source: https://github.com/shinchiro/mpv-winbuild-cmake
- Bundled archive SHA-256: `1bf3b029da2c98e605e00e85f21ee3142f22a1dcc4ceb5c827b5c51e36e390f9`
- Electron license information is included in the packaged Electron runtime.

## Android media playback

Android 原生 Dolby Vision 播放通道使用 AndroidX Media3（ExoPlayer 与
Media3 UI），依据 Apache License 2.0 发布：

- Source and license: https://github.com/androidx/media
- AndroidX Media3 version: `1.11.0`
