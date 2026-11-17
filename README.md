# LiveWall Studio

免费的开源 macOS 壁纸管理器：本地壁纸库、图片和视频壁纸、多套播放列表，以及中文独立窗口。

基于 [Layton Brewer 的 LiveWall](https://github.com/layton-brewer/LiveWall) v1.1.0 二次开发，采用 MIT 许可证。本仓库是独立维护的衍生版本。

## 下载与安装

在 [Releases](https://github.com/sufencyshao/LiveWall-Studio/releases) 下载 ZIP，解压后将 `LiveWall.app` 拖入“应用程序”，然后打开。

- macOS 14 或更高版本；当前下载包仅提供 Apple Silicon（M 系列芯片）。
- 首次发布为预览版。应用使用本地临时签名，尚未获得 Apple Developer ID 签名或公证；macOS 可能要求在“系统设置 → 隐私与安全性”中允许打开。
- 同时运行原版 LiveWall 时请先退出原版：本版本沿用 `com.livewall.app`，会共用已有本地设置。
- 壁纸素材需自行准备。下载包不包含壁纸、账户信息或作者的本地配置。

## 功能

- 读取你选择的本地文件夹，显示预览、搜索和类型筛选；缩略图大小可调。
- 支持常见图片（PNG、JPEG、HEIC、GIF 等）和 macOS 可解码的视频（MP4、MOV、M4V 等）。视频是否可播放也取决于编码。
- 多套播放列表；拖入文件、调整顺序、移除条目；顺序播放、随机播放及当前壁纸循环。
- 时长以分钟设置，最短 1 分钟，默认 60 分钟；可批量应用时长。
- 多显示器、缩放、音量、循环片段，以及电池/低电量暂停选项。
- 独立窗口和菜单栏控制。较窄窗口收起侧栏，宽度足够时显示侧栏，也能手动切换。
- “从壁纸库移除”只隐藏条目，保留原文件；可恢复已移除项。

关闭窗口会继续播放；选择“退出 LiveWall”会停止播放器。

## 使用

1. 打开“全部壁纸”，通过右上角文件夹菜单选择壁纸目录。
2. 双击卡片设为壁纸；悬停可预览，眼睛按钮打开大图预览。
3. 新建播放列表，通过卡片右键菜单或拖动将壁纸加入列表。
4. 选择列表设置顺序/随机/单个循环及每项时长，再点击播放。

## 从源码构建

需要 macOS、Python 3、支持当前 Swift 源码及系统 API 的较新 Xcode 或 Command Line Tools。此版本已在 Apple Silicon 本机使用 Swift 6.3.3 编译验证；macOS 14 及 Intel 机器尚未实机验收。

```sh
./script/build_and_run.sh --build-only  # 构建、临时签名并生成 ZIP
./script/build_and_run.sh              # 构建后启动
```

产物位于 `dist/`。脚本从仓库源码构建应用和屏保模块，不需要已有的 LiveWall 安装。

可设置 `LIVEWALL_ARCH=x86_64` 尝试构建 Intel 版；首发未提供经实机验证的 Intel 包。

## 当前限制

本次验证覆盖编译、签名检查及本机窗口布局操作；尚未完成所有格式、长时间轮换、多显示器、屏保和不同 macOS 版本的完整验收。

“添加到系统壁纸与锁屏”功能继承上游实现，使用未公开的系统壁纸存储行为，可能随系统升级失效；它不是可靠的跨版本锁屏播放接口。

程序在启动时和手动检查更新时访问本仓库的 GitHub Releases；壁纸库及播放列表保存在本机。

## 署名和许可证

原版 LiveWall © 2026 Layton Brewer。LiveWall Studio 修改与扩展 © 2026 sufencyshao。详见 [LICENSE](LICENSE)。壁纸素材的版权属于各自权利人，不随应用许可证授权。
