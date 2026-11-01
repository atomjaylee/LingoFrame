# ELEnglish

macOS 上的看剧学英语播放器：片源来自 Emby，底层播放对标 Infuse / SenPlayer，上层做逐句精听、点词查词、影子跟读。

- 竞品调研：[docs/macos-player-research.md](docs/macos-player-research.md)
- 技术选型：[docs/tech-stack.md](docs/tech-stack.md)
- 字幕与学习层设计：[docs/subtitle-learning-design.md](docs/subtitle-learning-design.md)

## 运行

需要 Xcode 26 和 XcodeGen（`brew install xcodegen`）。Xcode 工程由 `project.yml` 生成，不纳入版本管理。

```bash
xcodegen generate
```

```bash
open ELEnglish.xcodeproj
```

在 Xcode 里选择 ELEnglish scheme 运行（⌘R），测试用 ⌘U。也可以用命令行：

```bash
xcodebuild -project ELEnglish.xcodeproj -scheme ELEnglish -derivedDataPath build/DerivedData test
```

单个模块可以在它的目录里直接 `swift test`，例如 `Packages/LearningCore`。

## 结构

| 位置 | 内容 |
|---|---|
| `App/` | App 入口、登录、媒体库、播放窗口、设置 |
| `Packages/LearningCore` | 字幕剧本模型、学习程序、命令与绑定、扩展注册中心（不依赖界面） |
| `Packages/DesignSystem` | Rex 设计令牌（颜色 / 字体 / 圆角 / 间距 / 阴影）、主题存储、Rex 组件、图片加载与取色 |
| `Packages/Workspace` | 面板注册、停靠布局、布局预设与存储 |
| `Packages/MediaServerKit` | Emby 客户端、设备能力描述、凭据存储、片源标签 |
| `Packages/PlaybackCore` | 播放协议、状态、轨道、缓冲区间和诊断模型 |
| `Packages/PlaybackKit` | AetherEngine 适配器、Apple 原生视频图层与软件解码兜底 |
| `Packages/TMDBKit` | TMDB 客户端（搜索、详情、图片与磁盘缓存） |

## 用户数据位置

| 内容 | 位置 |
|---|---|
| 布局和布局预设 | `~/Library/Application Support/ELEnglish/Layouts/` |
| 登录信息 | 正式版：钥匙串；开发版：`~/Library/Application Support/ELEnglish/dev-account.json`（600 权限） |
| 图片与 TMDB 缓存 | `~/Library/Caches/app.elenglish/` |
| 字幕缓存 | `~/Library/Caches/ELEnglish/Subtitles/` |

## 设计系统

界面遵循设计系统 Rex（claude.ai 上的 Design System「Rex」）。令牌在 `Packages/DesignSystem/Sources/DesignSystem/Theme.swift`，
名称与 Rex 的 tokens.json 一一对应（kebab-case 改成 camelCase）；支持深色、浅色、跟随系统三种外观模式。

## 开发版调试工具

- 启动参数 `-debugRoute` 直接打开某个页面：`detail:<条目ID>`、`library:<媒体库ID>`、`play:<条目ID>`。

开发版收到分布式通知 `app.elenglish.debug.snapshot`（object 为输出目录）时，会把所有窗口渲染成 PNG，用于在没有录屏权限的环境里检查界面。视频画面不会出现在截图里。
