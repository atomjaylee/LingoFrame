import CryptoKit
import Foundation
import LearningCore
import MediaServerKit
import Observation
import os
import PlaybackKit
@preconcurrency import Translation

/// 打开播放窗口的请求。作为窗口的值，必须可编码。
enum PlayRequest: Codable, Hashable {
    case emby(serverID: String, itemID: String, resume: Bool)
    case local(URL)
}

private actor SubtitleCueCache {
    static let shared = SubtitleCueCache()
    private var inFlight: [URL: Task<[SubtitleCue]?, Never>] = [:]

    func cues(file: URL, loader: @escaping @Sendable () async -> String?) async -> [SubtitleCue]? {
        if let text = try? String(contentsOf: file, encoding: .utf8) { return SubtitleParser.parse(text) }
        if let task = inFlight[file] { return await task.value }
        let task = Task { () -> [SubtitleCue]? in
            guard let text = await loader() else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
            return SubtitleParser.parse(text)
        }
        inFlight[file] = task
        let result = await task.value
        inFlight[file] = nil
        return result
    }
}

struct SeekFeedback: Equatable {
    enum Direction: Equatable { case backward, forward }
    var direction: Direction
    var seconds: Int
}

/// 一个播放窗口的会话：把 Emby 条目解析成播放地址，交给播放内核，并向 Emby 上报播放进度。
@MainActor
@Observable
final class PlaybackSession {
    let engine: NativePlayerEngine
    let client: EmbyClient?
    let serverID: String?

    private(set) var item: EmbyItem?
    private(set) var stream: ResolvedStream?
    private(set) var siblings: [EmbyItem] = []
    private(set) var localURL: URL?
    private(set) var errorMessage: String?
    /// 这次播放的准备方式，诊断用：直接加载或详情页预热复用。
    private(set) var playMode = ""
    /// 学习窗口可用的原字幕轨，包含可直接读取的文字和需要识别的图片字幕。
    private(set) var subtitleOptions: [SubtitleOption] = []
    /// 主字幕（一般是英文）和副字幕（一般是中文）。
    private(set) var primarySubtitle: SubtitleOption?
    private(set) var secondarySubtitle: SubtitleOption?
    private(set) var primaryCues: [SubtitleCue] = []
    private(set) var secondaryCues: [SubtitleCue] = []
    private(set) var isLearningPanelVisible = false
    private var bitmapLearningSubtitle: SubtitleOption?
    var learningPrimarySubtitle: SubtitleOption? { primarySubtitle ?? bitmapLearningSubtitle }
    /// 没有可用字幕时的说明，比如「这个片源只有图形字幕」。
    private(set) var subtitleNote: String?
    private(set) var translationNote: String?
    var subtitleMode: SubtitleMode = .primaryOnly {
        didSet {
            if subtitleMode != .bilingual { translationNote = nil }
            if oldValue != subtitleMode { updateLearningActivity() }
        }
    }
    /// 当前句在主字幕里的序号，每 0.1 秒按播放位置更新，只有换句时才变。
    private(set) var currentLine: Int?
    /// 学习面板高亮的句子序号：句间空档保持在上一句，仅在句子边界变化时更新，避免界面高频读取播放时钟。
    private(set) var activeLine: Int?
    /// 单句循环：每句重复几遍再进入下一句（关 / 3 遍 / 5 遍 / 一直）。换集时保留。
    var loopMode: LoopMode = .off {
        didSet { loopPass = 1 }
    }
    var loopEnabled: Bool { loopMode != .off }
    var loopTimes: Int { loopMode.times }
    private(set) var loopPass = 1
    /// 每句播完自动暂停，方便跟读或回想。
    var pauseAfterSentence = false
    @ObservationIgnored private var pausedAfterLine: Int?
    /// 快捷键操作的短暂提示，比如「速度 0.75×」。
    private(set) var hud: String?
    /// 快进快退使用画面左右两侧的独立反馈，不和普通状态提示混在一起。
    private(set) var seekFeedback: SeekFeedback?

    @ObservationIgnored private var reporter: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var seekFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var usesBitmapSubtitleRecognition = false
    @ObservationIgnored private var lastRecognizedBitmapCueID: Int?
    @ObservationIgnored private var lastRecognizedBitmapCueCount = 0
    @ObservationIgnored private var lastCompanionCueID: Int?
    @ObservationIgnored private var lastCompanionCueCount = 0
    @ObservationIgnored private var translatedCues: [SubtitleCue: String] = [:]
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var lastRequest: PlayRequest?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var jumpGeneration: UInt64 = 0
    @ObservationIgnored private var nextPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparedNext: PreparedPlayback?
    private let profile = DeviceProfile.native
    private let log = Logger(subsystem: "app.elenglish", category: "session")

    init(client: EmbyClient?, serverID: String?, engine: NativePlayerEngine) {
        self.client = client
        self.serverID = serverID
        self.engine = engine
    }

    var title: String {
        item?.cardTitle ?? localURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// 窗口标题，照 Infuse：「黄石 - 第 1 季 · 第 1 集 - 拂晓」，电影就是片名。
    var windowTitle: String {
        guard let item, item.kind == .episode else { return title }
        var parts = [item.seriesName ?? title]
        let numbers = [item.parentIndexNumber.map { "第 \($0) 季" }, item.indexNumber.map { "第 \($0) 集" }].compactMap { $0 }
        if !numbers.isEmpty { parts.append(numbers.joined(separator: " · ")) }
        if let name = item.name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " - ")
    }

    var subtitle: String? {
        guard let item else { return nil }
        return item.kind == .episode ? item.cardSubtitle : item.productionYear.map(String.init)
    }

    var summary: MediaSummary? { stream.map { MediaSummary(source: $0.mediaSource) } }

    var nextItem: EmbyItem? {
        guard let item, let i = siblings.firstIndex(where: { $0.id == item.id }), i + 1 < siblings.count else { return nil }
        return siblings[i + 1]
    }

    // MARK: 开始与结束

    func start(_ request: PlayRequest, prepared: PreparedPlayback? = nil) async {
        lastRequest = request
        switch request {
        case .local(let url):
            let generation = beginLoad()
            finishCurrent()
            guard generation == loadGeneration else { return }
            engine.beginStartupMeasurement(context: "本地文件")
            errorMessage = nil
            localURL = url
            do {
                try await engine.load(url: url)
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
            }
        case .emby(_, let id, let resume):
            if let prepared, prepared.item.id == id {
                await play(prepared: prepared, resume: resume)
            } else {
                await play(itemID: id, resume: resume)
            }
        }
    }

    func retry() async {
        if let lastRequest { await start(lastRequest) }
    }

    func play(itemID: String, resume: Bool) async {
        if let preparedNext, preparedNext.item.id == itemID {
            self.preparedNext = nil
            nextPreparationTask?.cancel()
            nextPreparationTask = nil
            await play(prepared: preparedNext, resume: resume)
            return
        }
        guard let client else {
            errorMessage = "请先登录 Emby"
            return
        }
        let generation = beginLoad()
        finishCurrent()
        guard generation == loadGeneration else { return }
        engine.beginStartupMeasurement(context: "Emby 冷启动")
        errorMessage = nil
        if let serverID {
            lastRequest = .emby(serverID: serverID, itemID: itemID, resume: resume)
        }
        let t0 = ContinuousClock.now
        func mark(_ step: String) {
            #if DEBUG
            NSLog("起播 %@ %@", step, "\(t0.duration(to: .now))")
            #endif
        }
        do {
            // 原文件直放不依赖 StartTimeTicks；条目与播放信息并行请求，冷启动少等一次网络往返。
            async let itemRequest = client.item(itemID)
            async let infoRequest = client.playbackInfo(itemID: itemID, profile: profile)
            let (item, info) = try await (itemRequest, infoRequest)
            guard generation == loadGeneration else { return }
            mark("条目与播放信息")
            self.item = item
            let start = resume ? item.resumePositionSeconds : nil
            let stream = try client.resolveOriginalStream(itemID: itemID, info: info)
            self.stream = stream
            loadSubtitles(source: stream.mediaSource)
            playMode = "Apple 原生显示管线"
            log.info("播放 \(itemID, privacy: .public) 路线 Apple 原生显示")
            mark("开始播放器")
            try await engine.load(url: stream.url, id: item.id, startAt: start, durationHint: durationHint,
                                  httpHeaders: client.playbackHTTPHeaders)
            startReporting(generation: generation)
            if item.kind == .episode, let seriesID = item.seriesId {
                let loaded = (try? await client.episodes(of: seriesID, season: item.seasonId)) ?? []
                guard generation == loadGeneration else { return }
                siblings = loaded
                prepareNextItem(generation: generation)
            } else {
                siblings = []
            }
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            if siblings.isEmpty, let item, item.kind == .episode, let seriesID = item.seriesId {
                let loaded = (try? await client.episodes(of: seriesID, season: item.seasonId)) ?? []
                guard generation == loadGeneration else { return }
                siblings = loaded
            }
        }
    }

    private func play(prepared: PreparedPlayback, resume: Bool) async {
        guard let client else {
            errorMessage = "请先登录 Emby"
            return
        }
        let generation = beginLoad()
        finishCurrent()
        guard generation == loadGeneration else { return }
        engine.beginStartupMeasurement(context: prepared.isPrewarmed ? "Emby 预热命中" : "Emby 元数据命中")
        errorMessage = nil
        lastRequest = .emby(serverID: prepared.serverID, itemID: prepared.item.id, resume: resume)
        item = prepared.item
        stream = prepared.stream
        let start = resume ? prepared.startAt : nil
        loadSubtitles(source: prepared.stream.mediaSource)
        playMode = prepared.isPrewarmed ? "Apple 原生显示管线（预热命中）" : "Apple 原生显示管线（元数据命中）"
        do {
            try await engine.load(url: prepared.stream.url, id: prepared.item.id,
                                  startAt: start, durationHint: durationHint, httpHeaders: client.playbackHTTPHeaders)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            return
        }
        startReporting(generation: generation)
        if prepared.item.kind == .episode, let seriesID = prepared.item.seriesId {
            let loaded = (try? await client.episodes(of: seriesID, season: prepared.item.seasonId)) ?? []
            guard generation == loadGeneration else { return }
            siblings = loaded
            prepareNextItem(generation: generation)
        } else {
            siblings = []
        }
    }

    private var durationHint: Double? { item?.runTimeTicks.map { Double($0) / 10_000_000 } }

    private func beginLoad() -> UInt64 {
        loadGeneration &+= 1
        jumpGeneration &+= 1
        return loadGeneration
    }

    static func defaultAudio(of source: MediaSourceInfo) -> MediaStream? {
        source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }
            ?? source.audioStreams.first { $0.isDefault == true }
            ?? source.audioStreams.first
    }

    /// 关闭窗口时调用：上报停止、停掉服务器转码、释放播放器。
    func close() {
        _ = beginLoad()
        finishCurrent()
    }

    /// 播放到结尾：立即上报停止（Emby 会据此把这一集标记为已看）。
    func handleEnded() {
        reporter?.cancel()
        reporter = nil
        guard reportedStart else { return }
        let stopped = makeReport(.stopped)
        reportedStart = false
        if let stopped { Task { await transmit(stopped, as: .stopped) } }
    }

    private func finishCurrent() {
        reporter?.cancel()
        reporter = nil
        let stopped = reportedStart ? makeReport(.stopped) : nil
        reportedStart = false
        engine.stop()
        item = nil
        siblings = []
        stream = nil
        localURL = nil
        subtitleTask?.cancel()
        ticker?.cancel()
        nextPreparationTask?.cancel()
        seekFeedbackTask?.cancel()
        nextPreparationTask = nil
        seekFeedbackTask = nil
        preparedNext = nil
        seekFeedback = nil
        ticker = nil
        currentLine = nil
        activeLine = nil
        subtitleOptions = []
        primarySubtitle = nil
        secondarySubtitle = nil
        primaryCues = []
        secondaryCues = []
        bitmapLearningSubtitle = nil
        usesBitmapSubtitleRecognition = false
        lastRecognizedBitmapCueID = nil
        subtitleNote = nil
        translationNote = nil
        translatedCues = [:]
        if let stopped { Task { await transmit(stopped, as: .stopped) } }
    }

    /// 剩余多少秒时开始准备下一集。太早会白取直链、占用起播带宽，直链也可能在用到之前过期。
    private static let nextPreparationLeadSeconds: Double = 5 * 60

    /// 当前集快播完时提前解析下一集，并利用空闲网络连接按码率预取开头约 8 秒。
    private func prepareNextItem(generation: UInt64) {
        nextPreparationTask?.cancel()
        preparedNext = nil
        guard let client = client?.forPreloading(), let serverID, let next = nextItem else { return }
        nextPreparationTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                let duration = self.engine.duration > 0 ? self.engine.duration : (self.durationHint ?? 0)
                if duration > 0, duration - self.engine.currentTime <= Self.nextPreparationLeadSeconds { break }
            }
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            do {
                async let itemRequest = client.item(next.id)
                async let infoRequest = client.playbackInfo(itemID: next.id,
                                                            startSeconds: next.resumePositionSeconds,
                                                            profile: profile)
                let (item, info) = try await (itemRequest, infoRequest)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                let stream = try client.resolveOriginalStream(itemID: item.id, info: info)
                preparedNext = PreparedPlayback(serverID: serverID, item: item, stream: stream,
                                                startAt: item.resumePositionSeconds, isPrewarmed: false)
                let warmed = await NativePlayerEngine.prewarm(url: stream.url, httpHeaders: client.playbackHTTPHeaders,
                                                             bitrate: stream.mediaSource.bitrate)
                guard !Task.isCancelled, generation == loadGeneration,
                      preparedNext?.item.id == item.id else { return }
                preparedNext?.isPrewarmed = warmed
                log.info("下一集准备完成 \(item.id, privacy: .public) 预热 \(warmed, privacy: .public)")
            } catch is CancellationError {
                return
            } catch {
                log.debug("下一集准备失败 \(next.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: 字幕

    /// 只准备学习字幕的选项，识别和读取等到学习窗口打开后再启动。
    private func loadSubtitles(source: MediaSourceInfo) {
        engine.setNativeSubtitlesVisible(true)
        let options = Self.learningSubtitleOptions(from: source)
        subtitleOptions = options
        let english = options.filter(\.isEnglish)
        let primary = english.first { $0.isText && !$0.title.lowercased().contains("sdh") }
            ?? english.first(where: \.isText) ?? english.first ?? options.first
        primarySubtitle = primary?.isText == true ? primary : nil
        bitmapLearningSubtitle = primary?.isText == false ? primary : nil
        secondarySubtitle = nil
        subtitleMode = .primaryOnly
        updateLearningActivity()
    }

    func setLearningPanelVisible(_ visible: Bool) {
        guard isLearningPanelVisible != visible else { return }
        isLearningPanelVisible = visible
        updateLearningActivity()
    }

    private var isLearningActive: Bool { isLearningPanelVisible && subtitleMode != .off }

    private func updateLearningActivity() {
        guard isLearningActive else {
            subtitleTask?.cancel()
            engine.pauseBitmapSubtitleRecognition()
            return
        }
        guard let item, let stream else { return }
        let primary = primarySubtitle
        if primary == nil {
            if let bitmap = bitmapLearningSubtitle {
                enableBitmapSubtitleRecognition(language: bitmap.language)
            } else {
                subtitleNote = "这个片源没有字幕"
            }
        } else if primaryCues.isEmpty {
            disableBitmapSubtitleRecognition()
            subtitleNote = "正在读取字幕…"
            selectSubtitles(primary: primary, secondary: secondarySubtitle, itemID: item.id, sourceID: stream.mediaSource.id)
        } else if let secondary = secondarySubtitle, secondary.isText, secondaryCues.isEmpty {
            selectSubtitles(primary: primary, secondary: secondary, itemID: item.id, sourceID: stream.mediaSource.id)
        }
        if subtitleMode == .bilingual { prepareBilingualSubtitles() }
        if subtitleMode == .bilingual, let secondary = secondarySubtitle, !secondary.isText,
           let primary = learningPrimarySubtitle {
            if !usesBitmapSubtitleRecognition { enableBitmapSubtitleRecognition(language: primary.language) }
            engine.setLearningCompanionSubtitle(secondary.id, language: secondary.language)
        } else {
            engine.setLearningCompanionSubtitle(nil)
        }
    }

    func selectPrimarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        if option != learningPrimarySubtitle {
            primaryCues = []
            translatedCues = [:]
            disableBitmapSubtitleRecognition()
        }
        bitmapLearningSubtitle = option?.isText == false ? option : nil
        selectSubtitles(primary: option?.isText == true ? option : nil, secondary: secondarySubtitle,
                        itemID: item.id, sourceID: stream.mediaSource.id)
        updateLearningActivity()
    }

    func selectSecondarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        selectSubtitles(primary: primarySubtitle, secondary: option, itemID: item.id, sourceID: stream.mediaSource.id)
        if option != nil { subtitleMode = .bilingual }
        else if subtitleMode == .bilingual { subtitleMode = .primaryOnly }
        updateLearningActivity()
    }

    private func prepareBilingualSubtitles() {
        guard isLearningActive, secondarySubtitle == nil, let item, let stream else { return }
        let chinese = subtitleOptions.filter { $0.isChinese && $0 != learningPrimarySubtitle }
        if let chinese = chinese.first(where: \.isText) ?? chinese.first {
            translationNote = chinese.isText ? "正在读取原片中文字幕…" : "正在识别原片中文字幕…"
            selectSubtitles(primary: primarySubtitle, secondary: chinese,
                            itemID: item.id, sourceID: stream.mediaSource.id)
        } else {
            translationNote = "等待英文字幕后生成中文…"
        }
    }

    var needsSystemTranslation: Bool {
        let isEnglish = primarySubtitle?.isEnglish ?? bitmapLearningSubtitle?.isEnglish ?? false
        return isLearningActive && subtitleMode == .bilingual && secondarySubtitle == nil && isEnglish && !primaryCues.isEmpty
    }

    var systemTranslationID: String? {
        needsSystemTranslation ? "\(loadGeneration)|\(primarySubtitle?.id ?? bitmapLearningSubtitle?.id ?? -1)" : nil
    }

    /// 英文轨没有配套中文时按句翻译，优先当前句及附近句子，并沿用原时间轴。
    func translateSubtitles(using translator: TranslationSession) async {
        let generation = loadGeneration
        let primary = primarySubtitle
        translationNote = "正在准备中文翻译，首次使用可能需要下载语言包…"
        do {
            while !Task.isCancelled, generation == loadGeneration, primary == primarySubtitle, needsSystemTranslation {
                let anchor = activeLine.flatMap { primaryCues.indices.contains($0) ? $0 : nil } ?? 0
                let pending = primaryCues.indices.filter { translatedCues[primaryCues[$0]] == nil }
                    .sorted { abs($0 - anchor) < abs($1 - anchor) }.prefix(8)
                if pending.isEmpty {
                    translationNote = nil
                    try await Task.sleep(for: .milliseconds(300))
                    continue
                }
                translationNote = "正在生成中文字幕…"
                let batch = Dictionary(uniqueKeysWithValues: pending.map { (String($0), primaryCues[$0]) })
                let requests = pending.map {
                    TranslationSession.Request(sourceText: primaryCues[$0].text, clientIdentifier: String($0))
                }
                for try await response in translator.translate(batch: requests) {
                    guard !Task.isCancelled, generation == loadGeneration, primary == primarySubtitle,
                          needsSystemTranslation else { return }
                    guard let id = response.clientIdentifier, let cue = batch[id], primaryCues.contains(cue) else { continue }
                    translatedCues[cue] = response.targetText
                    applyTranslatedCues()
                }
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, primary == primarySubtitle, needsSystemTranslation else { return }
            translationNote = "中文翻译未完成，请切回英文后再试"
            log.error("系统字幕翻译失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyTranslatedCues() {
        secondaryCues = primaryCues.compactMap { cue in
            translatedCues[cue].map { SubtitleCue(range: cue.range, text: $0) }
        }
    }

    func translation(for cue: SubtitleCue) -> String? {
        // 系统译文和英文逐句对应，不能用时间重叠去匹配持续时间较长的图形字幕。
        if secondarySubtitle == nil { return secondaryCues.first { $0.range == cue.range }?.text }
        if secondarySubtitle?.isText == false {
            return secondaryCues.filter { $0.range.overlaps(cue.range) }
                .min { abs($0.range.start.ms - cue.range.start.ms) < abs($1.range.start.ms - cue.range.start.ms) }?.text
        }
        return secondaryCues.filter { $0.range.overlaps(cue.range) }
            .max { $0.range.overlapDuration(with: cue.range) < $1.range.overlapDuration(with: cue.range) }?.text
    }

    func selectPlaybackSubtitle(_ id: Int?) {
        engine.selectSubtitle(id)
    }

    private nonisolated static func normalizedSubtitleLanguage(_ language: String?) -> String? {
        guard let value = language?.lowercased() else { return nil }
        if value == "eng" || value == "en" || value.hasPrefix("en-") { return "en" }
        if ["chi", "zho", "zh", "chs", "cht"].contains(value) || value.hasPrefix("zh-") { return "zh" }
        return value
    }

    private func enableBitmapSubtitleRecognition(language: String?) {
        usesBitmapSubtitleRecognition = true
        lastRecognizedBitmapCueID = nil
        subtitleNote = "正在识别图形字幕…"
        engine.setBitmapSubtitleRecognitionEnabled(true, language: language, trackID: learningPrimarySubtitle?.id)
        startTicker()
    }

    private func disableBitmapSubtitleRecognition() {
        guard usesBitmapSubtitleRecognition else { return }
        usesBitmapSubtitleRecognition = false
        lastRecognizedBitmapCueID = nil
        engine.setBitmapSubtitleRecognitionEnabled(false)
    }

    private func selectSubtitles(primary: SubtitleOption?, secondary: SubtitleOption?, itemID: String, sourceID: String) {
        if primary != primarySubtitle {
            translatedCues = [:]
            primaryCues = []
        }
        if secondary != secondarySubtitle {
            secondaryCues = []
            lastCompanionCueID = nil
            lastCompanionCueCount = 0
        }
        primarySubtitle = primary
        secondarySubtitle = secondary
        subtitleTask?.cancel()
        guard isLearningActive else { return }
        subtitleTask = Task { [weak self] in
            guard let self, let client = self.client else { return }
            async let p = Self.fetchCues(client, itemID, sourceID, primary)
            async let s = Self.fetchCues(client, itemID, sourceID, secondary)
            let (primaryResult, secondaryResult) = await (p, s)
            guard !Task.isCancelled else { return }
            if primary != nil { self.primaryCues = primaryResult ?? [] }
            if secondary?.isText == true {
                self.secondaryCues = secondaryResult ?? []
                self.translationNote = self.secondaryCues.isEmpty ? "中文字幕读取失败，请在字幕设置中换一条" : nil
            } else if secondary == nil { self.applyTranslatedCues() }
            if primary != nil {
                self.subtitleNote = primaryResult == nil ? "学习字幕读取失败，视频原字幕不受影响"
                    : primaryResult?.isEmpty == true ? "学习字幕无法解析，视频原字幕不受影响" : nil
            }
            self.log.info("字幕 主 \(self.primaryCues.count) 条 副 \(self.secondaryCues.count) 条")
            self.startTicker()
        }
    }

    private nonisolated static func fetchCues(_ client: EmbyClient, _ itemID: String, _ sourceID: String,
                                              _ option: SubtitleOption?) async -> [SubtitleCue]? {
        guard let option, option.isText else { return [] }
        let file = subtitleCacheFile(itemID: itemID, sourceID: sourceID, streamIndex: option.id)
        return await SubtitleCueCache.shared.cues(file: file) {
            try? await client.subtitleText(itemID: itemID, mediaSourceID: sourceID, streamIndex: option.id)
        }
    }

    nonisolated static func prefetchSubtitles(client: EmbyClient, itemID: String, source: MediaSourceInfo) async {
        let options = textSubtitleOptions(from: source)
        let english = options.first { $0.isEnglish }
        _ = await fetchCues(client, itemID, source.id, english ?? options.first)
    }

    private nonisolated static func textSubtitleOptions(from source: MediaSourceInfo) -> [SubtitleOption] {
        learningSubtitleOptions(from: source).filter(\.isText)
    }

    private nonisolated static func learningSubtitleOptions(from source: MediaSourceInfo) -> [SubtitleOption] {
        let textCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "tx3g"]
        return source.subtitleStreams.compactMap { stream in
            guard let index = stream.index, stream.isForced != true else { return nil }
            let codec = stream.codec?.lowercased() ?? ""
            return SubtitleOption(id: index, title: stream.displayTitle ?? stream.title ?? stream.language ?? "字幕 \(index)",
                                  language: stream.language, isText: stream.isTextSubtitleStream ?? textCodecs.contains(codec), isForced: false)
        }
    }

    private nonisolated static func subtitleCacheFile(itemID: String, sourceID: String, streamIndex: Int) -> URL {
        let key = "\(itemID)|\(sourceID)|\(streamIndex)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".srt"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ELEnglish/Subtitles", isDirectory: true)
            .appendingPathComponent(name)
    }

    // MARK: 句子

    private var now: MediaTime { MediaTime(seconds: engine.absoluteTime) }

    /// 跟踪当前句，并负责单句循环：到句尾就跳回句首，满 loopTimes 遍后继续往下播。
    private func startTicker() {
        ticker?.cancel()
        guard !primaryCues.isEmpty || !secondaryCues.isEmpty || usesBitmapSubtitleRecognition else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isLearningActive, self.usesBitmapSubtitleRecognition { self.syncRecognizedBitmapSubtitles() }
                if self.isLearningActive, self.subtitleMode == .bilingual { self.syncCompanionSubtitles() }
                let t = self.now
                if self.loopEnabled, let line = self.currentLine, self.primaryCues.indices.contains(line),
                   self.engine.state == .playing, t >= self.primaryCues[line].range.end {
                    if self.loopPass < self.loopTimes {
                        self.loopPass += 1
                        await self.engine.seek(to: self.primaryCues[line].range.start.seconds, exact: true)
                        continue
                    }
                    self.loopPass = 1
                }
                if !self.loopEnabled, self.pauseAfterSentence, let line = self.currentLine,
                   self.primaryCues.indices.contains(line), self.pausedAfterLine != line,
                   self.engine.state == .playing, t >= self.primaryCues[line].range.end {
                    self.pausedAfterLine = line
                    self.engine.pause()
                }
                let index = self.primaryCues.index(at: t) ?? (self.loopEnabled ? self.currentLine : nil)
                if index != self.currentLine {
                    #if DEBUG
                    NSLog("当前句 %@ 时间 %.1f", index.map(String.init) ?? "-", t.seconds)
                    #endif
                    self.currentLine = index
                    if !self.loopEnabled { self.loopPass = 1 }
                }
                let active = index
                    ?? self.primaryCues.latestIndex(atOrBefore: t)
                    ?? self.primaryCues.indices.first
                if active != self.activeLine { self.activeLine = active }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func syncRecognizedBitmapSubtitles() {
        guard primarySubtitle == nil else { return }
        let recognized = engine.recognizedSubtitleCues
        if recognized.isEmpty {
            subtitleNote = engine.isRecognizingBitmapSubtitles ? "正在识别图形字幕…" : "等待下一句字幕…"
            return
        }
        guard recognized.last?.id != lastRecognizedBitmapCueID || recognized.count != lastRecognizedBitmapCueCount else { return }
        lastRecognizedBitmapCueID = recognized.last?.id
        lastRecognizedBitmapCueCount = recognized.count
        var merged = Dictionary(primaryCues.map { (SentenceID.derive(start: $0.range.start, text: $0.text), $0) },
                                uniquingKeysWith: { _, latest in latest })
        for cue in recognized {
            let range = TimeRange(start: MediaTime(seconds: cue.startTime), end: MediaTime(seconds: cue.endTime))
            merged[SentenceID.derive(start: range.start, text: cue.text)] = SubtitleCue(range: range, text: cue.text)
        }
        primaryCues = merged.values.sorted { $0.range.start < $1.range.start }
        if primaryCues.isEmpty {
            subtitleNote = engine.isRecognizingBitmapSubtitles ? "正在识别图形字幕…" : "等待下一句图形字幕…"
        } else {
            subtitleNote = nil
        }
    }

    private func syncCompanionSubtitles() {
        guard secondarySubtitle?.isText == false else { return }
        let recognized = engine.recognizedCompanionSubtitleCues
        guard !recognized.isEmpty,
              recognized.last?.id != lastCompanionCueID || recognized.count != lastCompanionCueCount else { return }
        lastCompanionCueID = recognized.last?.id
        lastCompanionCueCount = recognized.count
        var merged = Dictionary(secondaryCues.map { (SentenceID.derive(start: $0.range.start, text: $0.text), $0) },
                                uniquingKeysWith: { _, latest in latest })
        for cue in recognized {
            let range = TimeRange(start: MediaTime(seconds: cue.startTime), end: MediaTime(seconds: cue.endTime))
            merged[SentenceID.derive(start: range.start, text: cue.text)] = SubtitleCue(range: range, text: cue.text)
        }
        secondaryCues = merged.values.sorted { $0.range.start < $1.range.start }
        translationNote = nil
    }

    /// 当前句；两句之间的空档里算作上一句。
    private var anchorLine: Int? {
        currentLine ?? primaryCues.latestIndex(atOrBefore: now)
    }

    func jump(toLine index: Int) {
        guard primaryCues.indices.contains(index) else { return }
        jumpGeneration &+= 1
        let generation = jumpGeneration
        currentLine = index
        activeLine = index
        loopPass = 1
        pausedAfterLine = nil
        Task {
            await engine.seek(to: primaryCues[index].range.start.seconds, exact: true)
            guard generation == jumpGeneration else { return }
            if engine.state != .playing { engine.play() }
        }
    }

    func previousSentence() {
        guard let line = anchorLine else { return seek(by: -5) }
        // 句子刚开头时回到上一句，否则回到本句开头。
        let started = now.ms - primaryCues[line].range.start.ms
        jump(toLine: started > 1200 ? line : max(line - 1, 0))
    }

    func nextSentence() {
        guard !primaryCues.isEmpty else { return seek(by: 5) }
        let t = now
        let next = primaryCues.firstIndex { $0.range.start > t } ?? primaryCues.count - 1
        jump(toLine: next)
    }

    func replaySentence() {
        guard let line = anchorLine else { return seek(by: -5) }
        jump(toLine: line)
    }

    /// 快捷键用：在「关」和「3 遍」之间切换。
    func toggleLoop() {
        loopMode = loopEnabled ? .off : .three
        flash(loopEnabled ? "单句循环 \(loopTimes) 遍" : "关闭单句循环")
    }

    var previousItem: EmbyItem? {
        guard let item, let i = siblings.firstIndex(where: { $0.id == item.id }), i > 0 else { return nil }
        return siblings[i - 1]
    }

    // MARK: 控制

    func togglePlay() {
        let willPause = engine.state == .playing
        engine.togglePlay()
        let generation = loadGeneration
        if reportedStart {
            Task { await send(.progress(event: willPause ? "Pause" : "Unpause", paused: willPause), generation: generation) }
        }
    }

    func seek(by seconds: Double) {
        engine.skip(by: seconds)
        let direction: SeekFeedback.Direction = seconds < 0 ? .backward : .forward
        let amount = max(1, Int(abs(seconds).rounded()))
        if let current = seekFeedback, current.direction == direction {
            seekFeedback = SeekFeedback(direction: direction, seconds: current.seconds + amount)
        } else {
            seekFeedback = SeekFeedback(direction: direction, seconds: amount)
        }
        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            self?.seekFeedback = nil
            self?.seekFeedbackTask = nil
        }
    }

    static let rateSteps: [Double] = [0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    func stepRate(up: Bool) {
        let steps = Self.rateSteps
        let next = up ? steps.first { $0 > engine.rate + 0.001 } : steps.last { $0 < engine.rate - 0.001 }
        setRate(next ?? engine.rate)
    }

    func setRate(_ rate: Double) {
        engine.rate = rate
        flash(String(format: "速度 %g×", rate))
    }

    func changeVolume(by delta: Float) {
        engine.volume = min(max(engine.volume + delta, 0), 1)
        engine.isMuted = false
        flash("音量 \(Int((engine.volume * 100).rounded()))%")
    }

    func toggleMute() {
        engine.isMuted.toggle()
        flash(engine.isMuted ? "静音" : "取消静音")
    }

    func flash(_ message: String) {
        hud = message
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }

    // MARK: 上报

    private enum Report {
        case start
        case progress(event: String?, paused: Bool? = nil)
        case stopped
    }

    /// 等到真正开始播放才上报「开始」，之后每 10 秒上报一次进度（Emby 服务器自己会按秒累加，不需要更频繁）。
    private func startReporting(generation: UInt64) {
        reporter?.cancel()
        reportedStart = false
        guard client != nil else { return }
        reporter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.loadGeneration == generation else { return }
                if self.engine.state == .playing {
                    await self.send(.start, generation: generation)
                    guard !Task.isCancelled, self.loadGeneration == generation else { return }
                    self.reportedStart = true
                    break
                }
                if case .failed = self.engine.state { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                await self.send(.progress(event: "TimeUpdate"), generation: generation)
            }
        }
    }

    private func send(_ kind: Report, generation: UInt64? = nil) async {
        if let generation, generation != loadGeneration { return }
        guard let report = makeReport(kind) else { return }
        await transmit(report, as: kind)
    }

    private func makeReport(_ kind: Report) -> PlaybackReport? {
        guard let item, let stream else { return nil }
        var paused = engine.state != .playing
        var event: String?
        if case .progress(let e, let p) = kind {
            event = e
            if let p { paused = p }
        }
        return PlaybackReport(
            itemId: item.id, mediaSourceId: stream.mediaSource.id, playSessionId: stream.playSessionID,
            positionSeconds: engine.absoluteTime,
            isPaused: paused, isMuted: engine.isMuted, playMethod: stream.method, playbackRate: engine.rate,
            eventName: event)
    }

    private func transmit(_ report: PlaybackReport, as kind: Report) async {
        guard let client else { return }
        do {
            switch kind {
            case .start: try await client.reportPlaybackStart(report)
            case .progress: try await client.reportPlaybackProgress(report)
            case .stopped: try await client.reportPlaybackStopped(report)
            }
        } catch {
            // 上报失败不影响播放，只记日志。
            log.error("进度上报失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 一条可选的字幕轨。
struct SubtitleOption: Identifiable, Hashable, Sendable {
    /// 片源里的流序号。
    let id: Int
    let title: String
    let language: String?
    let isText: Bool
    let isForced: Bool

    var isEnglish: Bool {
        guard let l = language?.lowercased() else { return title.lowercased().contains("english") }
        return l == "eng" || l == "en" || l.hasPrefix("en-")
    }

    var isChinese: Bool {
        guard let l = language?.lowercased() else { return title.contains("中") }
        return ["chi", "zho", "zh", "chs", "cht"].contains(l) || l.hasPrefix("zh-")
    }
}

/// 学习窗口的显示方式，不改变播放器选择的原字幕。
enum SubtitleMode: String, CaseIterable, Identifiable {
    case bilingual = "双语"
    case primaryOnly = "仅英文"
    case blurPrimary = "遮挡英文"
    case off = "关闭"

    var id: String { rawValue }

    /// 分段控件里用的短名字。
    var short: String {
        switch self {
        case .bilingual: "双语"
        case .primaryOnly: "英文"
        case .blurPrimary: "遮挡"
        case .off: "关闭"
        }
    }
}

enum LoopMode: String, CaseIterable, Identifiable {
    case off = "关", three = "3 遍", five = "5 遍", forever = "一直"

    var id: String { rawValue }

    var times: Int {
        switch self {
        case .off: 1
        case .three: 3
        case .five: 5
        case .forever: .max
        }
    }
}
