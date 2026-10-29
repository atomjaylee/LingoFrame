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

/// 一个播放窗口的会话：把 Emby 条目解析成播放地址，交给播放内核，并向 Emby 上报播放进度。
@MainActor
@Observable
final class PlaybackSession {
    let engine: MPVPlayerEngine
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
    /// 没有可用字幕时的说明，比如「这个片源只有图形字幕」。
    private(set) var subtitleNote: String?
    var subtitleMode: SubtitleMode = .bilingual {
        didSet { engine.setNativeSubtitlesVisible(subtitleMode != .off && primaryCues.isEmpty) }
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

    @ObservationIgnored private var reporter: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var reportedStart = false
    @ObservationIgnored private var lastRequest: PlayRequest?
    private let profile = DeviceProfile.libmpv
    private let log = Logger(subsystem: "app.elenglish", category: "session")

    init(client: EmbyClient?, serverID: String?, engine: MPVPlayerEngine) {
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
            await finishCurrent()
            errorMessage = nil
            localURL = url
            engine.load(url: url)
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
        guard let client else {
            errorMessage = "请先登录 Emby"
            return
        }
        await finishCurrent()
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
            let item = try await client.item(itemID)
            mark("条目")
            self.item = item
            let start = resume ? item.resumePositionSeconds : nil
            let info = try await client.playbackInfo(itemID: itemID, startSeconds: start, profile: profile)
            mark("播放信息")
            let stream = try client.resolveOriginalStream(itemID: itemID, info: info)
            self.stream = stream
            loadSubtitles(itemID: item.id, source: stream.mediaSource)
            playMode = "libmpv 直读原文件"
            log.info("播放 \(itemID, privacy: .public) 路线 libmpv 原文件")
            engine.load(url: stream.url, startAt: start, durationHint: durationHint,
                        cachedSource: cachedSource(itemID: item.id, stream: stream))
            startReporting()
            if item.kind == .episode, let seriesID = item.seriesId {
                siblings = (try? await client.episodes(of: seriesID, season: item.seasonId)) ?? []
            } else {
                siblings = []
            }
        } catch {
            errorMessage = error.localizedDescription
            if siblings.isEmpty, let item, item.kind == .episode, let seriesID = item.seriesId {
                siblings = (try? await client.episodes(of: seriesID, season: item.seasonId)) ?? []
            }
        }
    }

    private func play(prepared: PreparedPlayback, resume: Bool) async {
        guard let client else {
            errorMessage = "请先登录 Emby"
            return
        }
        await finishCurrent(preserveEngine: true)
        errorMessage = nil
        lastRequest = .emby(serverID: prepared.serverID, itemID: prepared.item.id, resume: resume)
        item = prepared.item
        stream = prepared.stream
        let start = resume ? prepared.startAt : nil
        loadSubtitles(itemID: prepared.item.id, source: prepared.stream.mediaSource)
        playMode = "libmpv 详情页预热"
        if !engine.activatePreloaded(url: prepared.stream.url) || start != prepared.startAt {
            engine.load(url: prepared.stream.url, startAt: start, durationHint: durationHint,
                        cachedSource: cachedSource(itemID: prepared.item.id, stream: prepared.stream))
        }
        startReporting()
        if prepared.item.kind == .episode, let seriesID = prepared.item.seriesId {
            siblings = (try? await client.episodes(of: seriesID, season: prepared.item.seasonId)) ?? []
        } else {
            siblings = []
        }
    }

    private var durationHint: Double? { item?.runTimeTicks.map { Double($0) / 10_000_000 } }

    static func defaultAudio(of source: MediaSourceInfo) -> MediaStream? {
        source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }
            ?? source.audioStreams.first { $0.isDefault == true }
            ?? source.audioStreams.first
    }

    private func cachedSource(itemID: String, stream: ResolvedStream) -> CachedMediaSource {
        CachedMediaSource(
            cacheKey: [serverID ?? "local", itemID, stream.mediaSource.id, stream.mediaSource.size.map(String.init) ?? "unknown"]
                .joined(separator: "|"),
            url: stream.url,
            size: stream.mediaSource.size,
            fileExtension: stream.mediaSource.container)
    }

    /// 关闭窗口时调用：上报停止、停掉服务器转码、释放播放器。
    func close() async {
        await finishCurrent()
    }

    /// 播放到结尾：立即上报停止（Emby 会据此把这一集标记为已看）。
    func handleEnded() {
        reporter?.cancel()
        reporter = nil
        guard reportedStart else { return }
        reportedStart = false
        Task { await send(.stopped) }
    }

    private func finishCurrent(preserveEngine: Bool = false) async {
        reporter?.cancel()
        reporter = nil
        if reportedStart { await send(.stopped) }
        reportedStart = false
        if let stream, stream.method != .directPlay, let id = stream.playSessionID {
            try? await client?.stopEncoding(playSessionID: id)
        }
        if !preserveEngine { engine.stop() }
        stream = nil
        localURL = nil
        subtitleTask?.cancel()
        ticker?.cancel()
        ticker = nil
        currentLine = nil
        currentSecondary = nil
        subtitleOptions = []
        primarySubtitle = nil
        secondarySubtitle = nil
        primaryCues = []
        secondaryCues = []
        subtitleNote = nil
    }

    // MARK: 字幕

    /// 自动挑字幕：文本字幕由 Emby 在后台导出，不阻塞 libmpv 首帧；图形字幕交给 mpv 播放但不参与逐句学习。
    private func loadSubtitles(itemID: String, source: MediaSourceInfo) {
        engine.setNativeSubtitlesVisible(true)
        let textCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "tx3g"]
        let options: [SubtitleOption] = source.subtitleStreams.compactMap { s in
            guard let index = s.index, s.isForced != true else { return nil }
            let codec = s.codec?.lowercased() ?? ""
            let isText = s.isTextSubtitleStream ?? textCodecs.contains(codec)
            guard isText else { return nil }
            return SubtitleOption(id: index, title: s.displayTitle ?? s.title ?? s.language ?? "字幕 \(index)",
                                  language: s.language, isText: true, isForced: false)
        }
        subtitleOptions = options
        func pick(_ english: Bool) -> SubtitleOption? {
            let pool = options.filter { english ? $0.isEnglish : $0.isChinese }
            if english { return pool.first { !$0.title.lowercased().contains("sdh") } ?? pool.first }
            return pool.first { $0.title.contains("简") || $0.title.lowercased().contains("simplified")
                || $0.title.lowercased().contains("chs") } ?? pool.first
        }
        let primary = pick(true) ?? options.first
        let secondary = primary?.isEnglish == true ? pick(false) : nil
        primarySubtitle = primary
        secondarySubtitle = secondary
        if primary == nil {
            subtitleNote = source.subtitleStreams.isEmpty ? "这个片源没有字幕" : "图形字幕由播放器直接显示，暂不能逐句取词"
        } else {
            subtitleNote = "正在读取字幕…"
            selectSubtitles(primary: primary, secondary: secondary, itemID: itemID, sourceID: source.id)
        }
    }

    func selectPrimarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        selectSubtitles(primary: option, secondary: secondarySubtitle, itemID: item.id, sourceID: stream.mediaSource.id)
    }

    func selectSecondarySubtitle(_ option: SubtitleOption?) {
        guard let item, let stream else { return }
        selectSubtitles(primary: primarySubtitle, secondary: option, itemID: item.id, sourceID: stream.mediaSource.id)
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
            self.engine.setNativeSubtitlesVisible(self.subtitleMode != .off && self.primaryCues.isEmpty)
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
        guard let text = try? await client.subtitleText(itemID: itemID, mediaSourceID: sourceID, streamIndex: option.id)
        else { return nil }
        let cues = SubtitleParser.parse(text)
        #if DEBUG
        NSLog("字幕 %@ 文本 %ld 字 解析 %ld 条 开头：%@", option.title, text.count, cues.count, String(text.prefix(160)))
        #endif
        return cues
    }

    // MARK: 句子

    private var now: MediaTime { MediaTime(seconds: engine.absoluteTime) }

    /// 跟踪当前句，并负责单句循环：到句尾就跳回句首，满 loopTimes 遍后继续往下播。
    private func startTicker() {
        ticker?.cancel()
        guard !primaryCues.isEmpty || !secondaryCues.isEmpty else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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

    /// 当前句；两句之间的空档里算作上一句。
    private var anchorLine: Int? {
        if let currentLine { return currentLine }
        let t = now
        return primaryCues.lastIndex { $0.range.start <= t }
    }

    func jump(toLine index: Int) {
        guard primaryCues.indices.contains(index) else { return }
        currentLine = index
        loopPass = 1
        pausedAfterLine = nil
        Task {
            await engine.seek(to: primaryCues[index].range.start.seconds, exact: true)
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
        if reportedStart { Task { await send(.progress(event: willPause ? "Pause" : "Unpause", paused: willPause)) } }
    }

    func seek(by seconds: Double) {
        engine.skip(by: seconds)
        flash(seconds < 0 ? "⏪ \(Int(-seconds)) 秒" : "⏩ \(Int(seconds)) 秒")
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
    private func startReporting() {
        reporter?.cancel()
        reportedStart = false
        guard client != nil else { return }
        reporter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.engine.state == .playing {
                    await self.send(.start)
                    self.reportedStart = true
                    break
                }
                if case .failed = self.engine.state { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                await self.send(.progress(event: "TimeUpdate"))
            }
        }
    }

    private func send(_ kind: Report) async {
        guard let client, let item, let stream else { return }
        var paused = engine.state != .playing
        var event: String?
        if case .progress(let e, let p) = kind {
            event = e
            if let p { paused = p }
        }
        let report = PlaybackReport(
            itemId: item.id, mediaSourceId: stream.mediaSource.id, playSessionId: stream.playSessionID,
            positionSeconds: engine.absoluteTime,
            isPaused: paused, isMuted: engine.isMuted, playMethod: stream.method, playbackRate: engine.rate,
            eventName: event)
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
struct SubtitleOption: Identifiable, Hashable {
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
