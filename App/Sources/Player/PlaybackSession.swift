import CryptoKit
import Foundation
import LearningCore
import MediaServerKit
import Observation
import os
import PlaybackKit

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
    /// 片源里能选的字幕轨（只列文本字幕；图形字幕不能显示也不能取词）。
    private(set) var subtitleOptions: [SubtitleOption] = []
    /// 主字幕（一般是英文）和副字幕（一般是中文）。
    private(set) var primarySubtitle: SubtitleOption?
    private(set) var secondarySubtitle: SubtitleOption?
    private(set) var primaryCues: [SubtitleCue] = []
    private(set) var secondaryCues: [SubtitleCue] = []
    /// 当前播放器选择的是图形字幕或无法导出的字幕时，画面交给原生字幕，学习面板仍保留文本轨。
    private(set) var usesNativePlaybackSubtitles = false
    /// 没有可用字幕时的说明，比如「这个片源只有图形字幕」。
    private(set) var subtitleNote: String?
    var subtitleMode: SubtitleMode = .primaryOnly {
        didSet { updateNativeSubtitleVisibility() }
    }
    /// 当前句在主字幕里的序号，每 0.1 秒按播放位置更新，只有换句时才变。
    private(set) var currentLine: Int?
    /// 副字幕（中文）里和当前时间重叠的那一条。
    private(set) var currentSecondary: String?
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
            loadSubtitles(itemID: item.id, source: stream.mediaSource)
            playMode = "Apple 原生显示管线"
            log.info("播放 \(itemID, privacy: .public) 路线 Apple 原生显示")
            mark("开始播放器")
            try await engine.load(url: stream.url, id: item.id, startAt: start, durationHint: durationHint)
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
        loadSubtitles(itemID: prepared.item.id, source: prepared.stream.mediaSource)
        playMode = prepared.isPrewarmed ? "Apple 原生显示管线（预热命中）" : "Apple 原生显示管线（元数据命中）"
        do {
            try await engine.load(url: prepared.stream.url, id: prepared.item.id,
                                  startAt: start, durationHint: durationHint)
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
        currentSecondary = nil
        subtitleOptions = []
        primarySubtitle = nil
        secondarySubtitle = nil
        primaryCues = []
        secondaryCues = []
        usesNativePlaybackSubtitles = false
        usesBitmapSubtitleRecognition = false
        lastRecognizedBitmapCueID = nil
        subtitleNote = nil
        if let stopped { Task { await transmit(stopped, as: .stopped) } }
    }

    /// 当前集稳定播放后提前解析下一集，并利用空闲网络连接预取开头 8 MB。
    private func prepareNextItem(generation: UInt64) {
        nextPreparationTask?.cancel()
        preparedNext = nil
        guard let client, let serverID, let next = nextItem else { return }
        nextPreparationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
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
                let warmed = await NativePlayerEngine.prewarm(url: stream.url)
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

    /// 自动挑字幕：文本字幕由 Emby 在后台导出，不阻塞首帧；图形字幕由原生播放层显示但不参与逐句学习。
    private func loadSubtitles(itemID: String, source: MediaSourceInfo) {
        engine.setNativeSubtitlesVisible(true)
        let options = Self.textSubtitleOptions(from: source)
        subtitleOptions = options
        let english = options.filter(\.isEnglish)
        let primary = english.first { !$0.title.lowercased().contains("sdh") } ?? english.first ?? options.first
        primarySubtitle = primary
        secondarySubtitle = nil
        subtitleMode = .primaryOnly
        usesNativePlaybackSubtitles = primary == nil
        if primary == nil {
            if source.subtitleStreams.isEmpty {
                subtitleNote = "这个片源没有字幕"
                updateNativeSubtitleVisibility()
            } else {
                let language = engine.subtitleOptions.first(where: { $0.id == engine.selectedSubtitleID })?.language
                    ?? source.subtitleStreams.first?.language
                enableBitmapSubtitleRecognition(language: language)
            }
        } else {
            disableBitmapSubtitleRecognition()
            subtitleNote = "正在读取字幕…"
            selectSubtitles(primary: primary, secondary: nil, itemID: itemID, sourceID: source.id)
        }
    }

    func selectPrimarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        if option != nil { disableBitmapSubtitleRecognition() }
        selectSubtitles(primary: option, secondary: secondarySubtitle, itemID: item.id, sourceID: stream.mediaSource.id)
    }

    func selectSecondarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        if option != nil { subtitleMode = .bilingual }
        else if subtitleMode == .bilingual { subtitleMode = .primaryOnly }
        selectSubtitles(primary: primarySubtitle, secondary: option, itemID: item.id, sourceID: stream.mediaSource.id)
    }

    func selectPlaybackSubtitle(_ id: Int?) {
        engine.selectSubtitle(id)
        guard let id, let track = engine.subtitleOptions.first(where: { $0.id == id }) else {
            subtitleTask?.cancel()
            primaryCues = []
            secondaryCues = []
            usesNativePlaybackSubtitles = false
            disableBitmapSubtitleRecognition()
            subtitleMode = .off
            subtitleNote = "字幕已关闭"
            return
        }
        if subtitleMode == .off { subtitleMode = .primaryOnly }
        let learningTrack = matchingLearningTrack(id: id, title: track.title, language: track.language)
        guard let item, let stream else { return }
        guard let learningTrack else {
            usesNativePlaybackSubtitles = true
            updateNativeSubtitleVisibility()
            if subtitleOptions.isEmpty {
                primaryCues = []
                secondaryCues = []
                currentLine = nil
                enableBitmapSubtitleRecognition(language: track.language)
            } else if primaryCues.isEmpty, let fallback = preferredLearningTrack() {
                disableBitmapSubtitleRecognition()
                subtitleNote = "当前播放字幕不能逐句学习，已为学习面板保留文本字幕"
                selectSubtitles(primary: fallback, secondary: secondarySubtitle,
                                itemID: item.id, sourceID: stream.mediaSource.id)
            } else {
                subtitleNote = nil
            }
            return
        }
        usesNativePlaybackSubtitles = false
        disableBitmapSubtitleRecognition()
        updateNativeSubtitleVisibility()
        subtitleNote = "正在准备学习字幕…"
        selectSubtitles(primary: learningTrack, secondary: secondarySubtitle,
                        itemID: item.id, sourceID: stream.mediaSource.id)
    }

    private func matchingLearningTrack(id: Int, title: String, language: String?) -> SubtitleOption? {
        if let direct = subtitleOptions.first(where: { $0.id == id }) { return direct }
        let normalized = Self.normalizedSubtitleLanguage(language)
        if let normalized,
           let sameLanguage = subtitleOptions.first(where: { Self.normalizedSubtitleLanguage($0.language) == normalized }) {
            return sameLanguage
        }
        return subtitleOptions.first { option in
            option.title.localizedCaseInsensitiveContains(title)
                || title.localizedCaseInsensitiveContains(option.title)
        }
    }

    private func preferredLearningTrack() -> SubtitleOption? {
        subtitleOptions.first(where: \.isEnglish) ?? subtitleOptions.first
    }

    private nonisolated static func normalizedSubtitleLanguage(_ language: String?) -> String? {
        guard let value = language?.lowercased() else { return nil }
        if value == "eng" || value == "en" || value.hasPrefix("en-") { return "en" }
        if ["chi", "zho", "zh", "chs", "cht"].contains(value) || value.hasPrefix("zh-") { return "zh" }
        return value
    }

    private func updateNativeSubtitleVisibility() {
        engine.setNativeSubtitlesVisible(subtitleMode != .off && (usesNativePlaybackSubtitles || primaryCues.isEmpty))
    }

    private func enableBitmapSubtitleRecognition(language: String?) {
        usesBitmapSubtitleRecognition = true
        lastRecognizedBitmapCueID = nil
        subtitleNote = "正在识别图形字幕…"
        engine.setBitmapSubtitleRecognitionEnabled(true, language: language)
        updateNativeSubtitleVisibility()
        startTicker()
    }

    private func disableBitmapSubtitleRecognition() {
        guard usesBitmapSubtitleRecognition else { return }
        usesBitmapSubtitleRecognition = false
        lastRecognizedBitmapCueID = nil
        engine.setBitmapSubtitleRecognitionEnabled(false)
    }

    private func selectSubtitles(primary: SubtitleOption?, secondary: SubtitleOption?, itemID: String, sourceID: String) {
        primarySubtitle = primary
        secondarySubtitle = secondary
        subtitleTask?.cancel()
        subtitleTask = Task { [weak self] in
            guard let self, let client = self.client else { return }
            async let p = Self.fetchCues(client, itemID, sourceID, primary)
            async let s = Self.fetchCues(client, itemID, sourceID, secondary)
            let (primaryResult, secondaryResult) = await (p, s)
            guard !Task.isCancelled else { return }
            self.primaryCues = primaryResult ?? []
            self.secondaryCues = secondaryResult ?? []
            self.updateNativeSubtitleVisibility()
            if primary != nil {
                self.subtitleNote = primaryResult == nil ? "学习字幕读取失败，已由播放器直接显示"
                    : primaryResult?.isEmpty == true ? "学习字幕无法解析，已由播放器直接显示" : nil
            }
            self.log.info("字幕 主 \(self.primaryCues.count) 条 副 \(self.secondaryCues.count) 条")
            self.startTicker()
        }
    }

    private nonisolated static func fetchCues(_ client: EmbyClient, _ itemID: String, _ sourceID: String,
                                              _ option: SubtitleOption?) async -> [SubtitleCue]? {
        guard let option else { return [] }
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
        let textCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "tx3g"]
        return source.subtitleStreams.compactMap { stream in
            guard let index = stream.index, stream.isForced != true else { return nil }
            let codec = stream.codec?.lowercased() ?? ""
            guard stream.isTextSubtitleStream ?? textCodecs.contains(codec) else { return nil }
            return SubtitleOption(id: index, title: stream.displayTitle ?? stream.title ?? stream.language ?? "字幕 \(index)",
                                  language: stream.language, isText: true, isForced: false)
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
                if self.usesBitmapSubtitleRecognition { self.syncRecognizedBitmapSubtitles() }
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
                let secondary = self.secondaryCues.cue(at: t)?.text
                if secondary != self.currentSecondary { self.currentSecondary = secondary }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func syncRecognizedBitmapSubtitles() {
        let recognized = engine.recognizedSubtitleCues
        if recognized.isEmpty {
            subtitleNote = engine.isRecognizingBitmapSubtitles ? "正在识别图形字幕…" : "等待下一句字幕…"
            return
        }
        guard recognized.last?.id != lastRecognizedBitmapCueID || recognized.count != primaryCues.count else { return }
        lastRecognizedBitmapCueID = recognized.last?.id
        primaryCues = recognized.map {
            SubtitleCue(range: TimeRange(start: MediaTime(seconds: $0.startTime),
                                         end: MediaTime(seconds: $0.endTime)),
                        text: $0.text)
        }
        if primaryCues.isEmpty {
            subtitleNote = engine.isRecognizingBitmapSubtitles ? "正在识别图形字幕…" : "等待下一句图形字幕…"
        } else {
            subtitleNote = nil
        }
    }

    /// 当前句；两句之间的空档里算作上一句。
    private var anchorLine: Int? {
        if let currentLine { return currentLine }
        let t = now
        return primaryCues.lastIndex { $0.range.start <= t }
    }

    func jump(toLine index: Int) {
        guard primaryCues.indices.contains(index) else { return }
        jumpGeneration &+= 1
        let generation = jumpGeneration
        currentLine = index
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

/// 字幕显示方式，对应设计稿底部的「字幕：双语 / 仅英文 / 遮挡英文」。
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
