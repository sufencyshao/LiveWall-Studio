# LiveWall Studio

一款面向 Apple 芯片 Mac 的本地动态壁纸应用。壁纸库支持图片、视频和部分 Wallpaper Engine 创意工坊场景。文件准备好后，壁纸可离线播放。

[下载安装包](https://github.com/sufencyshao/LiveWall-Studio/releases/latest)

## 安装

1. 在 GitHub Releases 下载最新的 `LiveWall-Studio-版本号-macOS-arm64.dmg`。
2. 双击打开磁盘映像，将 `LiveWall.app` 拖到「应用程序」。升级时先从菜单栏退出旧版，再替换「应用程序」里的旧副本。
3. 在「应用程序」中打开 LiveWall。菜单栏会出现 LiveWall 图标，左键打开主窗口，右键打开播放控制。

需要 **Apple 芯片 Mac（M1 或更新）和 macOS 15 或更新版本**。此版本以 macOS 15 为最低构建目标，安装包与场景渲染器已在 macOS 27.2 上验证。安装包使用临时签名，尚未经过 Apple 公证。macOS 若提示无法验证开发者，先确认文件来自本仓库的 Release，再参考 [Apple 的官方说明](https://support.apple.com/zh-cn/102445)。

## 导入壁纸

首次使用会创建 `~/Pictures/LiveWall`。在「全部壁纸」右上角的文件夹菜单可以选择已有文件夹，或创建新的壁纸文件夹。

- **添加新文件**：把文件从 Finder 拖到「全部壁纸」。LiveWall 会复制到当前壁纸文件夹。同名导入会追加数字。也可拖到播放列表，导入后会加入该列表。
- **使用已有文件夹**：选择目录后，LiveWall 会直接读取其中的壁纸。用工具栏的刷新按钮重新扫描，也可用排序菜单按名称或修改时间排序。若目录已被删除或移走，需要重新选定或新建一个目录。
- **导入 macOS 安装包**：在文件夹菜单选「导入 PKG 壁纸」。LiveWall 会从可解包的安装包中提取能读取的图片和视频，安装包里的安装程序无需运行。

### 支持的文件

| 类型 | 文件及要求 |
| --- | --- |
| 静态图片 | `.png`、`.jpg`、`.jpeg`、`.webp`、`.heic`、`.tif`、`.tiff`、`.bmp` |
| 动图 | `.gif` |
| 视频 | `.mp4`、`.mov`、`.m4v`，视频编码需要能在 macOS 上解码。H.264 编码的 MP4 通常最容易兼容。 |
| 创意工坊场景 | 包含 `project.json` 和 `scene.pkg` 的完整项目文件夹。保留项目附带的素材、着色器和预览图。 |
| macOS 安装包 | 能解包且包含上述图片或视频的普通 `.pkg` 安装包。 |

Windows 程序壁纸和网页壁纸超出此版本的支持范围。不同场景使用的效果不同，显示可能与 Windows 上的 Wallpaper Engine 有差异。

### 创意工坊场景的文件夹结构

安装包已包含渲染引擎和运行库。场景还需要来自自己已购 Wallpaper Engine 安装的共享 `assets`。将整个 `assets` 文件夹复制到当前壁纸库根目录，再把各个场景文件夹放在同一层。播放器无需连接 Steam，也无需安装 WallpaperMachine。

```text
LiveWall/
├── assets/
│   ├── shaders/
│   └── materials/
├── 我的场景/
│   ├── project.json
│   ├── scene.pkg
│   └── preview.jpg（可选，使用项目实际文件名）
└── 示例.mp4
```

复制完成后点「刷新壁纸库」。也可以将完整场景文件夹拖进应用。单个 `scene.pkg` 只有在同目录仍有完整项目时才能导入。共享资源来源参见 [WallpaperMachine 的上游说明](https://github.com/MMFoundation/WallpaperMachine/blob/v1.13.0/docs/features/workshop-downloads.md#shared-scene-resources)。

## 播放和管理

- **设为壁纸**：在「全部壁纸」双击卡片。点眼睛可预览，并为每张壁纸独立设置「填充」「适应」「拉伸」。填充模式下可移动取景位置，场景在预览窗口实时渲染。
- **壁纸帧率**：场景与 GIF 可以在预览或右键菜单中单独选帧率。电池节能模式会降低场景渲染分辨率，并限制「自动」档的帧率。手动帧率优先。视频按原文件播放。
- **播放列表**：创建列表后点「添加壁纸」，在带缩略图的窗口中多选。每一项支持自定时长，也可批量设置。顶部能切换上一张、下一张、随机一张，并可暂停、继续、随机轮换或单张循环。
- **菜单栏**：右键 LiveWall 图标，可切换壁纸、暂停或继续、静音或取消静音。
- **音频反应**：对带频谱的场景，在「偏好设置 → 场景音频」打开系统声音响应，按 macOS 提示授权。LiveWall 在本机实时分析音频。
- **垃圾桶**：在壁纸卡片上右键移入垃圾桶，可以从侧边栏恢复。清空前会要求确认。确认后会永久删除原文件，场景会删除整个项目文件夹。

## 从源码构建

在 Apple 芯片 Mac 上准备 Xcode 或 Command Line Tools、CMake 3.24+、pkg-config、Python 3 和 rustup。首次构建需要联网获取固定版本的源码与 Rust 依赖。Release 中的 `LiveWall-Studio-版本号-source.tar.gz` 随附上游、原生依赖和所用 Rust 依赖的源码。

```bash
./script/build-renderer.sh
python3 script/package.py
```

输出为 `dist/LiveWall-Studio-版本号-macOS-arm64.dmg`。

如需把自己的共享资源带到另一台 Mac，可运行 `python3 script/package.py --personal-assets "/路径/assets"`。自用 DMG 放在 `dist/personal/`。公开分发素材前请核对是否取得相应的再分发授权。

## 许可

LiveWall 的 Swift 应用源码沿用 [MIT](LICENSE)。场景桥接与 [WallpaperMachine v1.13.0](https://github.com/MMFoundation/WallpaperMachine/tree/v1.13.0) 渲染器按 [GPL-3.0-only](renderer/COPYING) 分发。包含该渲染器的完整发行包按 GPL-3.0 分发，其他组件保留各自的许可声明。对应源码、修改补丁和构建脚本随同 Release 提供。
