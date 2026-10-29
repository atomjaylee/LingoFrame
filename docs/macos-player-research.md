# macOS 学英语播放器：竞品调研与技术方案

> 日期：2026-10-28
> 目标：在 macOS 上做一个底层播放能力对标 Infuse / SenPlayer 的播放器（杜比视界、杜比全景声、Emby 资源），上层做「小鹦看看」式的看剧学英语功能。
> 说明：标注「待验证」的结论来自论坛或 App Store 自述，需要在 M0 技术验证里用真机和样片确认。

---

## 1. 结论先行

1. **想在 Mac 上显示真正的杜比视界，只能走 Apple 自己的解码和渲染管线**（AVFoundation / VideoToolbox + EDR）。libmpv、VLC 这类自己写渲染的方案，最多只能「把 DV 正确映射成 HDR10/SDR」，系统不会把它当成 DV 处理。Infuse、SenPlayer、Forward 都是「FFmpeg 负责解封装和兼容，Apple 原生管线负责 DV/HDR 显示」。
2. **推荐双引擎架构**：
   - **主引擎（Native）**：FFmpeg 解封装 MKV/TS → 重新封装成 fMP4（HLS 或直接喂 CMSampleBuffer）→ AVPlayer / AVSampleBufferDisplayLayer。负责 DV P5 / P8.1 / P8.4、HDR10、HLG、E-AC-3 JOC（Atmos）。
   - **兜底引擎（Fallback）**：FFmpeg 软解后交给 AVSampleBufferDisplayLayer 显示。负责 AVFoundation 不支持的编码，比如 VC-1、MPEG-2、老 AVI，以及在不支持 AV1 硬解的机器上播 AV1。（最初的方案是用 libmpv，定稿时改掉了，原因见 [tech-stack.md](tech-stack.md)）
   - 两个引擎都实现同一个 `PlayerEngine` 协议，学习功能只依赖这个协议，不关心底层是哪个引擎。
3. **字幕不交给播放器画，由我们自己渲染**。学习功能（点词、逐句、双语、遮挡）必须拿到结构化的「句子 + 时间轴 + 单词」数据，用 SwiftUI/AppKit 叠加层自己画。
4. **Emby 走 Direct Play（`static=true` 原文件流）**。不让服务器转码，否则 DV 和 Atmos 会被破坏。播放进度回写 Emby，学习数据（生词、收藏句子）存在本地，以后再考虑同步。
5. **许可证要提前定**：要上 Mac App Store 或闭源商用，就不能用 GPL 组件。FFmpeg 用 LGPL 构建并动态链接，**不能直接用 KSPlayer 的免费版**（它是 GPL，LGPL 版要付费）。

---

## 2. 竞品调研

| 产品 | 渲染 / 引擎 | 杜比视界 | 杜比全景声 | 媒体源 | 开源 | 对我们的参考价值 |
|---|---|---|---|---|---|---|
| **Infuse**（Firecore） | 自研 FFmpeg 引擎 + Apple 原生 DV 管线 | P5 稳定；P8.1 / P8.4 视设备而定；P7 会降级成 HDR10（取决于 Apple 设备能力） | E-AC-3 JOC 可以；TrueHD Atmos 在 Mac 上只能解码成多声道 PCM | Emby / Jellyfin / Plex / SMB / WebDAV / 网盘 | 否 | 行业标杆。Mac 版 DV P5 曾长期偏色，说明 Mac 路径比 iOS/tvOS 难 |
| **SenPlayer** | 「Apple 原生渲染引擎」+ FFmpeg | App Store 宣称支持原生 DV | 宣称支持 | Emby / Jellyfin / 飞牛，多服务器、统一搜索 | 否 | 国产，Emby 体验好；Mac 版需要 macOS 13+ |
| **Forward** | 原生渲染 + FFmpeg（推测） | 宣称支持 DV、Dovi P5、HDR10 | 未明确 | 网盘 / Emby / Jellyfin / 模块 / Stremio 聚合，AI 刮削 | 否 | 「聚合多源 + AI 识别」的思路可以借鉴；Mac 版只支持 Apple Silicon |
| **VidHub** | 未公开 | 只宣称 HDR，没找到 DV 的确切说明 | 未明确 | Emby / Jellyfin / Plex / SMB / WebDAV，iCloud 同步 | 否 | 媒体库刮削和整理做得完整，最低支持 macOS 10.15 |
| **IINA** | libmpv（gpu / gpu-next，Metal/OpenGL）+ EDR | 不输出真正的 DV；P5 依赖 libplacebo 做 RPU 映射，Mac 上一直不太稳 | 解码成 PCM；1.4 新增 AVFoundation 音频驱动和空间音频 | 本地文件 / URL | 是（GPLv3） | Swift + libmpv 的工程组织、插件系统（1.4）、字幕处理都可以参考，**代码不能直接抄进闭源项目** |
| **小鹦看看**（学习竞品） | — | — | — | TED / YouTube / 本地 / 外挂字幕 | 否 | 学习功能对标对象，见第 5 节 |

### 2.1 可以借用的开源引擎

| 项目 | 做法 | DV | 许可证 | 建议 |
|---|---|---|---|---|
| **FFmpeg** | 解封装、软解、字幕解析、音频转码 | 能解析 DOVI 配置记录和 RPU 侧数据 | LGPL（不加 `--enable-gpl`） | 必须用 |
| **libdovi / dovi_tool** | DV RPU 解析，**P7 → P8.1 转换** | 核心工具 | MIT | 必须用，用来处理 P7 双层片源 |
| **KSPlayer** | AVPlayer + FFmpeg 双内核，Swift | 支持；「P5 不过热显示 HDR」只在付费 LGPL 版提供 | 免费版 GPL，商用版 LGPL 需付费 | 可以读代码学思路；闭源商用就买授权或者自己写 |
| **AetherEngine** | FFmpeg 解封装 → 薄封装成 HLS-fMP4 → AVPlayer；用 libdovi 把 P7 转成 8.1；软解回退走 AVSampleBufferDisplayLayer | 支持，把 DV 原样交给显示设备 | 「other」，需要看 LICENSE | **架构上最接近我们推荐的主引擎**，强烈建议先读源码 |
| **libmpv** | 全能兜底播放 | 只做映射，不输出真 DV | 默认 GPL，可以用 `-Dgpl=false` 编 LGPL 版 | 定稿不用（见 tech-stack.md） |
| **VLCKit** | 全能 | 不支持 | LGPL | 不推荐，HDR/DV 体验差 |
| **libass** | ASS 特效字幕渲染 | — | ISC | 需要保留 ASS 样式时再用 |

---

## 3. 底层播放能力：关键技术判断

### 3.1 杜比视界各 Profile 在 macOS 上怎么处理

| Profile | 常见来源 | 我们的处理方式 | 预期效果 |
|---|---|---|---|
| **P5**（单层，IPTPQc2，没有 HDR10 兼容层） | 流媒体 WEB-DL | 原样封装进 fMP4，样本描述用 `dvh1` 并带 `dvcC` → AVFoundation | 真 DV。**不能走 mpv**，否则一片紫绿 |
| **P8.1**（单层，兼容 HDR10） | WEB-DL、部分 BD 转制 | 封装成 `dvh1` 或 `hvc1` 加 SUPPLEMENTAL-CODECS（HLS 路径） | 真 DV（待验证：不同 macOS 版本对 P8.1 支持不一样）；失败时退回 HDR10 |
| **P8.4**（HLG 基础层） | iPhone 拍摄 | 原样交给系统 | 真 DV |
| **P7**（双层 BL+EL，UHD 原盘） | Remux、原盘 | 用 libdovi 把 RPU 转成 P8.1，丢掉 EL（MEL 无损；FEL 有轻微损失）→ 按 P8.1 处理 | 真 DV（会损失 FEL 的增强信息），这也是业界通行做法 |
| **P10**（AV1 DV） | 新流媒体 | M3 及以后的芯片硬解 AV1；先作为待验证项 | 待验证 |

补充：
- Mac 内建 XDR 屏或 Pro Display XDR 能显示 DV 的动态映射效果。**通过 HDMI 接电视时，macOS 一般不会输出 DV 信号**，最多是 HDR10（待验证），这一点和 Apple TV 不同，要在产品说明里讲清楚。
- HDR10+：Apple 平台支持有限，按 HDR10 静态元数据播放即可。

### 3.2 杜比全景声（Atmos）

| 音轨 | macOS 上能做到什么 | 处理方式 |
|---|---|---|
| **E-AC-3 JOC**（流媒体 Atmos） | AVFoundation 原生支持：耳机空间音频、Mac 内置扬声器空间渲染；macOS 15 起 Apple 自家 App 支持通过 HDMI 直通 Atmos | 原样封装进 fMP4 交给 AVPlayer。**第三方 App 能否走 HDMI 直通需要验证**（Infuse 用户反馈过不行） |
| **TrueHD Atmos**（原盘） | macOS 没有 TrueHD 直通 | FFmpeg 解码成 7.1 PCM → 转成 FLAC/ALAC 多声道封装（或者走 AVSampleBufferAudioRenderer），**对象信息会丢失，只剩 7.1 床** |
| **DTS / DTS-HD MA / DTS:X** | 不支持原生 | FFmpeg 解码成多声道 PCM，同上 |
| AC-3 / AAC / FLAC | 原生支持 | 直接封装 |

对学英语来说，Atmos 是「锦上添花」，**清晰的人声和精确的时间轴更重要**。后面可以加一个「人声增强」：调高中置声道，或者用 AVAudioUnitEQ 做均衡。

### 3.3 主引擎的两种实现方式（M0 阶段二选一）

**方案 A：FFmpeg → 本地 HLS-fMP4 → AVPlayer**（AetherEngine、NuvioTVOS 的做法）
- 好处：完全复用 AVPlayer，DV、空间音频、画中画、Now Playing、倍速保持音调（`audioTimePitchAlgorithm`）都能直接用，开发量最小。
- 坏处：seek 要重新生成分片，延迟稍高；精确 AB 循环要配合 `seek(toleranceBefore: .zero)` 加边界观察器；需要维护一个本地 HTTP 服务或者 `AVAssetResourceLoaderDelegate`。

**方案 B：FFmpeg → CMSampleBuffer → AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer**（Infuse、KSPlayer 一类）
- 好处：时钟完全由自己控制，逐句跳转和循环最快最精确；不需要本地 HTTP。
- 坏处：DV 格式描述（`dvcC`）、音画同步、E-AC-3 JOC 空间音频要自己处理，工作量大。

**建议**：M0 先用方案 A 做出 DV/Atmos 样片验证，最快确认「Apple 管线能不能吃下我们封装出来的流」。如果逐句循环的体验不够跟手，再在 M2 引入方案 B。两个方案共用 FFmpeg 解封装层和 libdovi 转换层，可以平滑切换。

### 3.4 统一引擎协议（学习层只依赖这个协议）

```swift
protocol PlayerEngine: AnyObject {
    var currentTime: CMTime { get }
    var duration: CMTime { get }
    var rate: Float { get set }                       // 0.5–2.0，保持音调
    var timePublisher: AnyPublisher<CMTime, Never> { get } // ~30Hz，用来做字幕高亮

    func load(_ source: MediaSource) async throws
    func play(); func pause()
    func seek(to: CMTime, exact: Bool) async
    func loop(range: CMTimeRange?)                    // 单句 / AB 循环，nil 表示取消
    func pauseAt(_ time: CMTime)                      // 逐句模式：播完这一句自动暂停

    var audioTracks: [TrackInfo] { get }
    var subtitleTracks: [TrackInfo] { get }           // 内嵌文本字幕，由 FFmpeg 抽取
    func extractAudio(range: CMTimeRange) async throws -> AVAudioPCMBuffer // 给 ASR 和跟读对比用
}
```

---

## 4. Emby 集成

| 能力 | 接口 | 说明 |
|---|---|---|
| 登录 | `POST /Users/AuthenticateByName` | 请求头 `X-Emby-Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…"`，拿到 `AccessToken` 和 `UserId` |
| 媒体库 | `GET /Users/{uid}/Views`、`/Users/{uid}/Items?ParentId=…` | 剧集用 `/Shows/{id}/Seasons`、`/Shows/{id}/Episodes` |
| 继续观看 | `/Users/{uid}/Items/Resume`、`UserData.PlaybackPositionTicks` | 1 tick = 100ns |
| 播放信息 | `POST /Items/{id}/PlaybackInfo` | 带上「什么都能直接播放」的 `DeviceProfile`，**避免服务器转码** |
| 视频流 | `GET /Videos/{id}/stream?static=true&MediaSourceId=…&api_key=…` | 原文件流，支持 HTTP Range，FFmpeg 可以直接打开 |
| 外挂 / 内嵌字幕 | `GET /Videos/{id}/{msId}/Subtitles/{index}/Stream.srt` | 服务器可以把内嵌文本字幕转成 srt/vtt，省掉我们自己抽取 |
| 播放上报 | `POST /Sessions/Playing`、`/Sessions/Playing/Progress`（约每 10 秒一次）、`/Sessions/Playing/Stopped` | 服务器会自己按秒累加进度，不需要高频上报 |

注意事项：
- Jellyfin 的 API 基本兼容（它是 Emby 的分支），可以抽象成 `MediaServerClient` 协议，一次支持两个。
- `.strm` 和网盘直链：`PlaybackInfo` 返回的 `Path` 可能是远程地址，要单独处理；有用户反馈这种情况下进度会一直上报成 0，需要注意。
- **循环播放会反复读同一段数据**：网络流要加一层「最近 N 分钟」的磁盘或内存缓存（按 Range 分块），否则单句循环每次都要重新请求网络。

---

## 5. 学习层：对标小鹦看看

### 5.1 小鹦看看的功能清单（App Store 自述）
双语 / 中 / 英 / 隐藏字幕切换、点击字幕查词、单句循环、AB 循环、上一句 / 下一句、无级变速、字幕词汇分析、导出音频和字幕、外挂字幕和时间轴调整、收藏句子和笔记、影子跟读。

### 5.2 我们的功能设计和技术实现

| 功能 | 实现 |
|---|---|
| **字幕获取** | 优先级：Emby 外挂或内嵌文本字幕 → FFmpeg 抽取内嵌字幕 → PGS/VobSub 图形字幕用 Vision `VNRecognizeTextRequest` 做 OCR → 都没有就用 **WhisperKit / whisper.cpp 在本地 ASR** 生成英文字幕（带词级时间戳） |
| **双语对齐** | 中英两条字幕按时间重叠度配对；没有中文字幕时用大模型翻译（整集一起翻，保留上下文）；结果缓存到本地，key 用媒体 ID 加字幕哈希 |
| **句子模型** | 把字幕切成 `Sentence { id, range, en, zh, tokens[] }`；短的字幕行合并、长的拆分；用 Whisper 强制对齐修正时间轴（很多网上字幕会提前或延后 0.3–1 秒，对逐句循环影响很大） |
| **点词查词** | NaturalLanguage `NLTagger` 分词并还原词形（running → run）；本地词典用 **ECDICT**（MIT，约 77 万词条，带音标、词频、考试标签）；词组和俚语交给大模型解释（结合整句语境） |
| **逐句精听** | 单句循环 N 次、播完自动暂停、上一句 / 下一句快捷键（← → 空格）、0.5–2.0x 倍速保持音调 |
| **遮挡模式** | 先盲听：英文字幕模糊显示，点击或按快捷键才显示；可以选择只遮生词 |
| **影子跟读** | AVAudioEngine 录音 → 和原句波形并排显示 → Whisper 识别后和原文做逐词 diff 打分（Speech 框架作为备选）；可以导出「原声 + 我的跟读」对比音频 |
| **生词本和复习** | 收藏单词时保存原句、截图、音频片段；用 FSRS 安排复习；支持导出 Anki（.apkg） |
| **词汇分析** | 进入一集前，统计生词数和难度；**可以直接接入现有的《美剧口语高频2000词》**，字幕里出现这些词时高亮，形成「词表 → 剧中原句」的闭环 |
| **快捷键优先** | Mac 用户以键盘操作为主：空格暂停、← → 切换上一句和下一句、R 重复、S 跟读、L 查词，并支持菜单栏控制 |

### 5.3 字幕渲染
- 在视频图层上叠一层 SwiftUI 自绘：每个单词是一个可以点击的 `Text` 片段，悬停时高亮，正在说的词做卡拉 OK 式高亮（依赖 Whisper 的词级时间戳）。
- ASS 特效字幕在学习模式下只取纯文本；观影模式可以用 libass 渲染成位图叠加。
- HDR 视频上的字幕亮度要压住，SDR 白色大约 203 nits，否则在 XDR 屏上会刺眼。

---

## 6. 整体架构

```
┌──────────────────────── App (SwiftUI + AppKit) ────────────────────────┐
│  媒体库 / 详情页      播放页（视频 + 字幕叠加层 + 学习侧栏）     生词本 / 复习   │
├────────────────────────────── 学习层 ──────────────────────────────────┤
│  SubtitleService   SentenceAligner   Dictionary(ECDICT)   ASR(WhisperKit) │
│  Translator(LLM)   ShadowingRecorder FSRS Scheduler       Store(SQLite/GRDB)│
├──────────────────────── PlayerEngine 协议 ─────────────────────────────┤
│  NativeEngine（FFmpeg 解封装 → libdovi → fMP4/CMSampleBuffer → AVFoundation）│
│  SoftwareEngine（FFmpeg 软解，兜底）       EngineSelector（按编码和 DV 选引擎）│
├────────────────────────────── 媒体源层 ────────────────────────────────┤
│  MediaServerClient: Emby / Jellyfin    Local / SMB / WebDAV   RangeCache │
└────────────────────────────────────────────────────────────────────────┘
```

**引擎选择规则（EngineSelector）**：
- 视频是 H.264 / HEVC / HEVC-DV / AV1（硬件支持时），并且音频能原生播放或可以转成 PCM → NativeEngine
- 其他情况（VC-1、MPEG-2、各种奇怪的格式）→ SoftwareEngine
- 用户可以在播放菜单里手动切换引擎

**技术栈**：已定稿，详见 [tech-stack.md](tech-stack.md)。要点：Swift 6 和 SwiftUI + AppKit；最低支持 macOS 15；同时编译 arm64 和 x86_64（Universal），因为开发机是 Intel；杜比视界和 HDR 的效果只在 Apple Silicon 上保证。

---

## 7. 里程碑

| 阶段 | 周期 | 交付 | 验收标准 |
|---|---|---|---|
| **M0 技术验证** | 2 周 | 命令行或最小 App：MKV → fMP4 → AVPlayer | 测试样片矩阵（见第 8 节）在 XDR 屏上被系统识别为 DV（看「显示器 HDR / 杜比视界」指示和画面）；E-AC-3 JOC 在 AirPods 上开启空间音频；P7 转 8.1 能正常播放 |
| **M1 Emby 播放器** | 3–4 周 | 登录、媒体库、继续观看、Direct Play、进度回写、音轨和字幕切换、软解兜底 | 日常看剧可以替代 Infuse |
| **M2 学习核心** | 4 周 | 自绘双语字幕、点词查词（ECDICT）、逐句、循环、遮挡、倍速、快捷键、收藏 | 小鹦看看的核心功能对齐 |
| **M3 AI 能力** | 3–4 周 | Whisper 生成字幕和时间轴对齐、大模型翻译和词组解释、影子跟读打分 | 没有字幕的片源也能学 |
| **M4 记忆闭环** | 2–3 周 | 生词本、FSRS 复习、高频 2000 词高亮、Anki 导出、iCloud 同步 | 形成「看 → 学 → 复习」的闭环 |

---

## 8. M0 测试样片矩阵

| # | 视频 | 音频 | 容器 | 预期 |
|---|---|---|---|---|
| 1 | DV P5 4K | E-AC-3 JOC 5.1 | MKV | DV + 空间音频 |
| 2 | DV P8.1 4K | E-AC-3 JOC | MKV | DV |
| 3 | DV P7 FEL 4K | TrueHD Atmos 7.1 | MKV（原盘 Remux） | P8.1 DV + 7.1 PCM |
| 4 | DV P7 MEL | DTS-HD MA 7.1 | MKV | P8.1 DV + 7.1 PCM |
| 5 | HDR10 / HDR10+ | AAC | MP4 | HDR10 EDR |
| 6 | iPhone DV P8.4 | AAC | MOV | DV |
| 7 | VC-1 1080p | AC-3 | MKV | 切到软解兜底 |
| 8 | 任意剧集 + PGS 字幕 | — | MKV | OCR 得到可点击的字幕 |

样片来源：Dolby 官方测试片、Kodi wiki 的 Samples 页面、自己 Emby 库里的真实片源。

---

## 9. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| macOS 对 P8.1 的 DV 识别不稳定 | 部分片源只能显示 HDR10 | M0 优先验证；如果不行，评估「P8.1 → P5」的 RPU 转换（libdovi 有相关能力，画质需要评估） |
| 第三方 App 拿不到 Atmos 的 HDMI 直通 | 外接功放没有 Atmos | 学英语场景以耳机和内置扬声器为主，可以接受；持续关注 Apple API |
| GPL 许可证传染 | 不能上架或闭源 | 第一天就把 FFmpeg 锁定为 LGPL 构建，CI 里检查 `--enable-gpl` |
| 网上字幕时间轴不准 | 逐句体验差 | Whisper 强制对齐，支持手动微调 ±100ms |
| 网络流反复 seek | 循环卡顿 | 加 RangeCache，预读当前句前后 30 秒 |

---

## 参考来源

- Infuse DV 讨论：[Dolby Vision Profile 7 & 8 support](https://community.firecore.com/t/dolby-vision-profile-7-8-support-ts-mkv-files/19713?page=47)、[DV P5 在 macOS 上颜色错误](https://community.firecore.com/t/dolby-vision-profile-5-plays-with-wrong-colors-on-macos-but-ok-on-ios-ipados-tvos/34946.md)、[Dolby Vision on macOS](https://community.firecore.com/t/dolby-vision-on-macos/26064.md)、[macOS Sequoia Atmos HDMI 直通](https://community.firecore.com/t/macos-sequoia-supports-hdmi-passthrough-for-dolby-atmos-content/49697)
- Apple：[Mac 音频直通说明](https://support.apple.com/guide/mac-help/mchle3a1461c)、[HLS Authoring Specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)
- 竞品 App Store：[SenPlayer](https://apps.apple.com/app/senplayer-hdr-media-player/id6443975850)、[Forward](https://apps.apple.com/app/id6503940939)、[VidHub](https://apps.apple.com/app/id1659622164)、[小鹦看看](https://apps.apple.com/cn/app/id1547395471)
- IINA：[1.4.0-beta1 发布说明](https://iina.io/release-note/1.4.0-beta1.html)、[Wikipedia](https://en.wikipedia.org/wiki/IINA)
- 开源引擎：[KSPlayer](https://github.com/kingslay/KSPlayer)、[AetherEngine](https://swiftpackageindex.com/superuser404notfound/AetherEngine)
- mpv 在 macOS 上的 DV/HDR：[mpv issue #12993](https://github.com/mpv-player/mpv/issues/12993)、[Emby 论坛：dolby vision in mpv](https://emby.media/community/topic/107829-dolby-vision-in-mpv/)
- Emby API：[Playback Check-ins](https://betadev.emby.media/doc/restapi/Playback-Check-ins.html)
