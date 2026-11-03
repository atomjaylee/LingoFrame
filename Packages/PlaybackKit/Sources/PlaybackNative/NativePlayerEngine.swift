import AetherEngine
import Combine
import CoreGraphics
import Foundation
import LearningCore
import Observation
import os
import PlaybackCore
import QuartzCore

public struct NativeSubtitleImage: Identifiable, @unchecked Sendable {
    public let id: Int
    public let cgImage: CGImage
    public let position: CGRect
    public let canvasSize: CGSize

    public init(id: Int, cgImage: CGImage, position: CGRect, canvasSize: CGSize) {
        self.id = id
        self.cgImage = cgImage
        self.position = position
        self.canvasSize = canvasSize
    }

    public func frame(in videoRect: CGRect) -> CGRect {
        guard canvasSize.width > 0 else {
            return CGRect(
                x: videoRect.minX + position.minX * videoRect.width,
                y: videoRect.minY + position.minY * videoRect.height,
                width: position.width * videoRect.width,
                height: position.height * videoRect.height)
        }
        let scale = videoRect.width / canvasSize.width
        return CGRect(
            x: videoRect.minX + position.minX * canvasSize.width * scale,
            y: videoRect.midY + (position.minY * canvasSize.height - canvasSize.height / 2) * scale,
            width: position.width * canvasSize.width * scale,
            height: position.height * canvasSize.height * scale)
    }
}

@MainActor
@Observable
public final class NativePlayerEngine: PlaybackCore.PlaybackEngine, SegmentPlayer, @unchecked Sendable {
    private struct NativeCue {
        var id: Int
        var startTime: Double
        var endTime: Double
        var text: String?
        var image: NativeSubtitleImage?
    }

    let backend: AetherEngine

    public private(set) var state: PlaybackCore.PlaybackState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var bufferedRanges: [BufferedRange] = []
    public private(set) var isSeeking = false
    public private(set) var isBuffering = false
    /// 起播后 AVPlayer 还没真正走起来的预滚阶段。引擎此时已把状态记为播放中，
    /// 这段等待也会被算作缓冲，界面应当把它当作加载而不是中途断粮。
    public private(set) var isPrerolling = false
    public private(set) var presentationSize: CGSize = .zero
    public private(set) var audioOptions: [TrackOption] = []
    public private(set) var selectedAudioID: Int?
    public private(set) var subtitleOptions: [TrackOption] = []
    public private(set) var selectedSubtitleID: Int?
    public private(set) var videoDescription: String?
    public private(set) var nativeSubtitleDescription: String?
    public private(set) var currentSubtitleText: String?
    public private(set) var currentSubtitleImages: [NativeSubtitleImage] = []
    public private(set) var hasStyledSubtitleTrack = false
    public var usesOriginalSubtitleStyle = true {
        didSet {
            configureASSRenderer()
            updateSubtitle(at: currentTime)
        }
    }
    public private(set) var recognizedSubtitleCues: [RecognizedNativeSubtitleCue] = []
    public private(set) var recognizedCompanionSubtitleCues: [RecognizedNativeSubtitleCue] = []
    public private(set) var isRecognizingBitmapSubtitles = false
    public private(set) var startupMilliseconds: Double?
    public private(set) var startupStage = "未开始"

    /// 初次加载、跳到未缓存位置或播放中断粮时，界面都应明确告诉用户正在等待数据。
    public var isWaitingForMedia: Bool { state == .loading || isSeeking || isBuffering }

    public var rate: Double = 1 {
        didSet { backend.setRate(Float(rate)) }
    }

    public var volume: Float = 1 {
        didSet {
            volume = min(max(volume, 0), 1)
            if !isMuted { backend.volume = volume }
        }
    }

    public var isMuted = false {
        didSet { backend.volume = isMuted ? 0 : volume }
    }

    public var absoluteTime: Double { currentTime }

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var nativeCues: [NativeCue] = []
    @ObservationIgnored private var learningNativeCues: [NativeCue] = []
    @ObservationIgnored private var nativeSubtitlesVisible = true
    @ObservationIgnored private var bitmapRecognitionEnabled = false
    @ObservationIgnored private var bitmapRecognitionLanguage: String?
    @ObservationIgnored private var bitmapRecognitionTrackID: Int?
    @ObservationIgnored private var activeLearningSubtitleID: Int?
    @ObservationIgnored private var companionSubtitleID: Int?
    @ObservationIgnored private var cachedCompanionSubtitleID: Int?
    @ObservationIgnored private var companionSubtitleLanguage: String?
    @ObservationIgnored private var recognizedCompanionCueIDs: Set<Int> = []
    @ObservationIgnored private var learningScanPositions: [Int: Double] = [:]
    @ObservationIgnored private var recognizedBitmapCueIDs: Set<Int> = []
    @ObservationIgnored private var bitmapRecognitionGeneration: UInt64 = 0
    @ObservationIgnored private var bitmapRecognitionTask: Task<Void, Never>?
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var assRenderer: ASSSubtitleRenderer?
    @ObservationIgnored private var assTrackID: Int?
    @ObservationIgnored private var assHeader: String?
    @ObservationIgnored private var assRenderSize: CGSize = .zero
    @ObservationIgnored private var assTimer: AnyCancellable?
    @ObservationIgnored private var subtitleClockSampleTime = CACurrentMediaTime()
    @ObservationIgnored private var segmentGeneration: UInt64 = 0
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var startupStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var startupGeneration: UInt64?
    @ObservationIgnored private var startupContext = "直接加载"
    @ObservationIgnored private let log = Logger(subsystem: "app.elenglish", category: "startup")

    public init() throws {
        backend = try AetherEngine()
        bindState()
    }

    /// 从用户发起播放时开始计时；冷启动会包含媒体服务请求，预热启动只包含播放器加载。
    public func beginStartupMeasurement(context: String) {
        startupStartedAt = .now
        startupGeneration = nil
        startupMilliseconds = nil
        startupStage = "准备片源"
        startupContext = context
    }

    public func load(_ source: PlaybackSource) async throws {
        if startupStartedAt == nil { beginStartupMeasurement(context: "直接加载") }
        // 保留会话在起播前设置的识别开关，只清理上一段字幕的识别结果。
        resetBitmapSubtitleRecognition(disable: false)
        learningNativeCues = []
        activeLearningSubtitleID = nil
        learningScanPositions = [:]
        lastError = nil
        resetASSRenderer()
        state = .loading
        let options = LoadOptions(
            httpHeaders: source.httpHeaders,
            preserveASSMarkup: true,
            declaredDurationSeconds: source.durationHint,
            progressiveSegmentDelivery: true,
            autoplay: source.autoplay,
            escalatesToSoftwarePath: true)
        do {
            try await backend.load(url: source.url, startPosition: source.startAt, options: options)
            configureASSRenderer(force: true)
            startLearningSubtitleChannel()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
            startupStage = "加载失败"
            startupStartedAt = nil
            throw error
        }
    }

    public func load(url: URL, id: String? = nil, startAt: Double? = nil, autoplay: Bool = true,
                     durationHint: Double? = nil, httpHeaders: [String: String] = [:]) async throws {
        try await load(PlaybackSource(id: id ?? url.absoluteString, url: url, startAt: startAt,
                                      durationHint: durationHint, httpHeaders: httpHeaders,
                                      autoplay: autoplay))
    }

    /// 预热多少秒的片源。引擎按 4 秒切段，AVPlayer 要等第一段写完、第二段开始才起播，
    /// 预热不够这么多就会在首帧之后停在「正在缓冲」。
    nonisolated static let prewarmSeconds: Double = 8
    /// 引擎的预热缓存总共只收 64 MB（头部加尾部），单次留出尾部的余量。
    nonisolated static let maximumPrewarmBytes = 56 * 1024 * 1024
    /// 和引擎默认的预热字节数一致。
    nonisolated static let minimumPrewarmBytes = 8 * 1024 * 1024

    /// 按码率换算预热字节数：码率未知时用引擎默认的 8 MB，4K 高码率片源最多 56 MB。
    nonisolated static func prewarmByteBudget(bitrate: Int?) -> Int {
        let minimum = minimumPrewarmBytes
        guard let bitrate, bitrate > 0 else { return minimum }
        let bytes = Int(Double(bitrate) * prewarmSeconds / 8)
        return min(max(bytes, minimum), maximumPrewarmBytes)
    }

    @discardableResult
    public nonisolated static func prewarm(url: URL, httpHeaders: [String: String] = [:], bitrate: Int? = nil) async -> Bool {
        _ = await AetherEngine.prewarm(url: url, httpHeaders: httpHeaders,
                                       byteBudget: prewarmByteBudget(bitrate: bitrate))
        return AetherEngine.isPrewarmed(url: url)
    }

    public nonisolated static func isPrewarmed(url: URL) -> Bool { AetherEngine.isPrewarmed(url: url) }

    public func play() { backend.play() }
    public func pause() { backend.pause() }

    public func stop() {
        cancelSegment()
        resetBitmapSubtitleRecognition(disable: true)
        backend.stop()
        resetASSRenderer()
    }

    public func togglePlay() {
        state == .playing ? pause() : play()
    }

    public func seek(to seconds: Double, exact: Bool = false) async {
        seekGeneration &+= 1
        let generation = seekGeneration
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)

        if !exact,
           bufferedRanges.contains(where: { $0.lowerBound <= target && target < $0.upperBound }),
           backend.supportsCacheBackedStills,
           let preview = await backend.scrubPreviewFrame(
               atSeconds: target, refined: false, maxWidth: 16,
               isCancelled: { Task.isCancelled }
           ), generation == seekGeneration, !Task.isCancelled,
           preview.validRange?.contains(target) == true {
            await backend.seek(to: preview.actualSeconds)
            return
        }

        guard generation == seekGeneration, !Task.isCancelled else { return }
        await backend.seek(to: target)
    }

    public func skip(by seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    public func selectAudio(_ id: Int) {
        selectedAudioID = id
        backend.selectAudioTrack(index: id)
    }

    public func selectSubtitle(_ id: Int?) {
        if id != selectedSubtitleID {
            if bitmapRecognitionTrackID == nil { resetBitmapSubtitleRecognition(disable: false) }
            nativeCues = []
            currentSubtitleText = nil
            currentSubtitleImages = []
        }
        selectedSubtitleID = id
        if let id { backend.selectSubtitleTrack(index: id) }
        else { backend.clearSubtitle() }
        configureASSRenderer()
        updateSubtitle(at: currentTime)
    }

    /// 图形字幕没有文本流时，按需启用本机 OCR；默认关闭，避免普通观影承担识别开销。
    public func setBitmapSubtitleRecognitionEnabled(_ enabled: Bool, language: String? = nil, trackID: Int? = nil) {
        guard enabled else {
            pauseBitmapSubtitleRecognition()
            resetBitmapSubtitleRecognition(disable: true)
            return
        }
        if bitmapRecognitionTrackID != trackID {
            pauseBitmapSubtitleRecognition()
            resetBitmapSubtitleRecognition(disable: false)
        }
        bitmapRecognitionTrackID = trackID
        bitmapRecognitionEnabled = true
        bitmapRecognitionLanguage = language
        startLearningSubtitleChannel()
        mergeDecodedTextSubtitleCues()
        scheduleBitmapSubtitleRecognition()
    }

    /// 学习窗口关闭时停止识别和独立取轨，保留结果供下次打开复用。
    public func pauseBitmapSubtitleRecognition() {
        bitmapRecognitionEnabled = false
        bitmapRecognitionGeneration &+= 1
        bitmapRecognitionTask?.cancel()
        bitmapRecognitionTask = nil
        isRecognizingBitmapSubtitles = false
        if activeLearningSubtitleID != nil { backend.clearSecondarySubtitle() }
        activeLearningSubtitleID = nil
    }

    /// 学习双语共用独立取轨通道，轮流补齐播放位置附近的原文和中文，视频轨保持不变。
    public func setLearningCompanionSubtitle(_ id: Int?, language: String? = nil) {
        guard companionSubtitleID != id else { return }
        let wasCompanion = activeLearningSubtitleID == companionSubtitleID && companionSubtitleID != nil
        companionSubtitleID = id
        companionSubtitleLanguage = language
        if let id, cachedCompanionSubtitleID != id {
            recognizedCompanionSubtitleCues = []
            recognizedCompanionCueIDs = []
            cachedCompanionSubtitleID = id
        }
        if let id { learningScanPositions[id] = nil }
        if wasCompanion {
            bitmapRecognitionGeneration &+= 1
            bitmapRecognitionTask?.cancel()
            bitmapRecognitionTask = nil
            isRecognizingBitmapSubtitles = false
            activeLearningSubtitleID = nil
            startLearningSubtitleChannel()
        } else {
            advanceLearningSubtitleChannel()
        }
    }

    private func startLearningSubtitleChannel() {
        guard bitmapRecognitionEnabled, let id = bitmapRecognitionTrackID,
              subtitleOptions.contains(where: { $0.id == id }),
              activeLearningSubtitleID == nil || !backend.isSecondarySubtitleActive else { return }
        activeLearningSubtitleID = id
        backend.selectSecondarySubtitleTrack(index: id)
    }

    private var recognizingCompanion: Bool {
        companionSubtitleID != nil && activeLearningSubtitleID == companionSubtitleID
    }

    private func advanceLearningSubtitleChannel() {
        guard bitmapRecognitionEnabled, !isRecognizingBitmapSubtitles, !learningNativeCues.isEmpty,
              let primary = bitmapRecognitionTrackID, let companion = companionSubtitleID,
              let active = activeLearningSubtitleID else { return }
        learningScanPositions[active] = currentTime
        let next = active == primary ? companion : primary
        if let position = learningScanPositions[next], abs(currentTime - position) < 8 { return }
        activeLearningSubtitleID = next
        backend.selectSecondarySubtitleTrack(index: next)
    }

    public func setNativeSubtitlesVisible(_ visible: Bool) {
        nativeSubtitlesVisible = visible
        updateSubtitle(at: currentTime)
        updateASSTimer()
    }

    /// 按实际视频显示区域生成字幕图片，窗口缩放时保留原字幕相对视频的位置。
    public func setSubtitleRenderSize(_ size: CGSize) {
        guard assRenderSize != size else { return }
        assRenderSize = size
        updateSubtitle(at: currentTime)
    }

    private func resetASSRenderer() {
        assTimer?.cancel()
        assTimer = nil
        assRenderer = nil
        assTrackID = nil
        assHeader = nil
        currentSubtitleImages = []
        currentSubtitleText = nil
    }

    private func configureASSRenderer(force: Bool = false) {
        let track = backend.subtitleTracks.first { $0.id == selectedSubtitleID }
        hasStyledSubtitleTrack = track.map { ["ass", "ssa"].contains($0.codec.lowercased()) } ?? false
        guard usesOriginalSubtitleStyle, hasStyledSubtitleTrack, let track,
              let header = track.assHeader ?? backend.sidecarASSHeader else {
            if assRenderer != nil { resetASSRenderer() }
            return
        }
        guard force || assTrackID != track.id || assHeader != header else { return }
        resetASSRenderer()
        assTrackID = track.id
        assHeader = header
        assRenderer = ASSSubtitleRenderer(header: header, fonts: backend.fontAttachments)
        feedASSEvents()
        updateASSTimer()
    }

    private func feedASSEvents() {
        guard let assRenderer else { return }
        for cue in backend.subtitleCues {
            guard let text = cue.text else { continue }
            assRenderer.add(event: text, start: cue.startTime, end: cue.endTime)
        }
        renderASS(at: backend.sourceTime)
    }

    private func renderASS(at time: Double) {
        guard nativeSubtitlesVisible, let assRenderer else { return }
        let size = assRenderSize == .zero ? presentationSize : assRenderSize
        let frame = assRenderer.render(at: time, size: size)
        if frame.changed { currentSubtitleImages = frame.image.map { [$0] } ?? [] }
    }

    private func updateASSTimer() {
        let runs = assRenderer != nil && nativeSubtitlesVisible && state == .playing && !isSeeking && !isBuffering
        guard runs else {
            assTimer?.cancel()
            assTimer = nil
            renderASS(at: backend.sourceTime)
            return
        }
        guard assTimer == nil else { return }
        assTimer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let elapsed = min(0.12, max(0, CACurrentMediaTime() - subtitleClockSampleTime))
            renderASS(at: backend.sourceTime + elapsed * rate)
        }
    }

    public func diagnostics() -> PlaybackDiagnostics {
        let telemetry = backend.liveTelemetry
        return PlaybackDiagnostics(
            indicatedBitrate: backend.sourceVideoBitrate > 0 ? Double(backend.sourceVideoBitrate) : nil,
            observedBitrate: telemetry?.networkThroughputMbps.map { $0 * 1_000_000 },
            droppedFrames: telemetry?.droppedFrameCount,
            playbackType: "Apple \(backend.playbackBackend.rawValue) / \(backend.activeVideoDecoder ?? "检测中")",
            lastError: lastError,
            startupMilliseconds: startupMilliseconds,
            startupStage: startupStage)
    }

    public func play(_ range: TimeRange, rate: Double) async throws {
        try Task.checkCancellation()
        cancelSegment()
        let generation = segmentGeneration
        let previousRate = self.rate
        defer {
            if generation == segmentGeneration, self.rate != previousRate {
                self.rate = previousRate
            }
        }
        await seek(to: range.start.seconds, exact: true)
        guard generation == segmentGeneration else { throw CancellationError() }
        self.rate = rate
        play()
        try await withTaskCancellationHandler {
            while generation == segmentGeneration, currentTime < range.end.seconds {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            guard generation == segmentGeneration else { throw CancellationError() }
            pause()
        } onCancel: {
            Task { @MainActor [weak self] in self?.pause() }
        }
    }

    private func cancelSegment() {
        segmentGeneration &+= 1
    }

    private func bindState() {
        backend.$state.sink { [weak self] value in
            guard let self else { return }
            switch value {
            case .idle: state = .idle
            case .loading: state = .loading
            case .playing: state = .playing
            case .paused: state = .paused
            case .seeking: break
            case .ended: state = .ended
            case .error(let message): state = .failed(message); lastError = message
            }
            updateASSTimer()
        }.store(in: &cancellables)

        backend.$startupProgress.compactMap { $0 }.sink { [weak self] progress in
            guard let self, let started = startupStartedAt else { return }
            if startupGeneration == nil { startupGeneration = progress.generation }
            guard startupGeneration == progress.generation else { return }
            let elapsed = Self.milliseconds(started.duration(to: .now))
            startupStage = Self.stageTitle(progress.stage)
            log.info("起播 \(self.startupContext, privacy: .public) \(self.startupStage, privacy: .public) \(elapsed, format: .fixed(precision: 0))ms")
            if progress.isComplete {
                startupMilliseconds = elapsed
                startupStartedAt = nil
                #if DEBUG
                NSLog("起播完成 %@ %.0fms", startupContext, elapsed)
                #endif
            }
        }.store(in: &cancellables)

        backend.clock.$currentTime.sink { [weak self] value in
            self?.currentTime = value
            self?.updateSubtitle(at: value)
            self?.advanceLearningSubtitleChannel()
        }.store(in: &cancellables)
        backend.clock.$sourceTime.sink { [weak self] time in
            self?.subtitleClockSampleTime = CACurrentMediaTime()
            self?.renderASS(at: time)
        }.store(in: &cancellables)

        backend.$duration.sink { [weak self] in self?.duration = $0 }.store(in: &cancellables)
        backend.$isSeeking.removeDuplicates().sink { [weak self] in self?.isSeeking = $0; self?.updateASSTimer() }.store(in: &cancellables)
        backend.$isBuffering.removeDuplicates().sink { [weak self] in self?.isBuffering = $0; self?.updateASSTimer() }.store(in: &cancellables)
        backend.$playbackPhase.map { $0 == .loading }.removeDuplicates()
            .sink { [weak self] in self?.isPrerolling = $0 }.store(in: &cancellables)
        backend.$residentRanges.sink { [weak self] ranges in
            self?.bufferedRanges = ranges.map { BufferedRange(lowerBound: $0.lowerBound, upperBound: $0.upperBound) }
        }.store(in: &cancellables)
        Publishers.CombineLatest3(backend.$sourceVideoWidth, backend.$sourceVideoHeight,
                                  backend.$sourceVideoCodecName)
            .sink { [weak self] width, height, codec in
                guard let self else { return }
                let displayWidth = Double(width) * backend.sourceVideoPixelAspectRatio
                presentationSize = width > 0 && height > 0 ? CGSize(width: displayWidth, height: Double(height)) : .zero
                videoDescription = codec.map { "\($0.uppercased()) \(width)×\(height)" }
            }.store(in: &cancellables)
        backend.$audioTracks.sink { [weak self] tracks in
            self?.audioOptions = tracks.map { TrackOption(id: $0.id, title: $0.name, language: $0.language) }
        }.store(in: &cancellables)
        backend.$subtitleTracks.sink { [weak self] tracks in
            guard let self else { return }
            subtitleOptions = tracks.map { TrackOption(id: $0.id, title: $0.name, language: $0.language) }
            if selectedSubtitleID == nil, let automatic = tracks.first(where: \.isDefault) ?? tracks.first {
                selectSubtitle(automatic.id)
            }
            startLearningSubtitleChannel()
            configureASSRenderer()
        }.store(in: &cancellables)
        backend.$activeAudioTrackIndex.sink { [weak self] in self?.selectedAudioID = $0 }.store(in: &cancellables)
        backend.$activeSubtitleTrackIndex.sink { [weak self] id in
            guard let self else { return }
            selectedSubtitleID = id
            nativeSubtitleDescription = subtitleOptions.first(where: { $0.id == id })?.title
            configureASSRenderer()
        }.store(in: &cancellables)
        backend.$sidecarASSHeader.sink { [weak self] _ in
            Task { @MainActor in self?.configureASSRenderer() }
        }.store(in: &cancellables)
        Publishers.CombineLatest(backend.$subtitleCues, backend.$secondarySubtitleCues).sink { [weak self] primary, secondary in
            guard let self else { return }
            for (isLearning, cues) in [(false, primary), (true, secondary)] {
                let id = isLearning ? activeLearningSubtitleID : selectedSubtitleID
                let isASS = backend.subtitleTracks.contains { $0.id == id && ["ass", "ssa"].contains($0.codec.lowercased()) }
                let mapped = cues.map { cue in
                    let image: NativeSubtitleImage? = if case .image(let value) = cue.body {
                        NativeSubtitleImage(id: cue.id, cgImage: value.cgImage,
                                            position: value.position, canvasSize: value.canvasSize)
                    } else {
                        nil
                    }
                    let text = isASS ? cue.text.map(SubtitleParser.plainASSDialogue) : cue.text
                    return NativeCue(id: cue.id, startTime: cue.startTime, endTime: cue.endTime,
                                     text: text, image: image)
                }
                if isLearning { learningNativeCues = mapped }
                else { nativeCues = mapped }
            }
            updateSubtitle(at: currentTime)
            if let assRenderer {
                for cue in primary {
                    if let text = cue.text { assRenderer.add(event: text, start: cue.startTime, end: cue.endTime) }
                }
                renderASS(at: backend.sourceTime)
            }
            mergeDecodedTextSubtitleCues()
            scheduleBitmapSubtitleRecognition()
            advanceLearningSubtitleChannel()
        }.store(in: &cancellables)
    }

    /// Emby 偶尔把可解码的文本轨标成图形轨；内核已经拿到文字时直接复用，不再多跑 OCR。
    private func mergeDecodedTextSubtitleCues() {
        guard bitmapRecognitionEnabled else { return }
        let companion = recognizingCompanion
        let existing = companion ? recognizedCompanionSubtitleCues : recognizedSubtitleCues
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for cue in bitmapRecognitionTrackID == nil ? nativeCues : learningNativeCues {
            guard let text = cue.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            merged[cue.id] = RecognizedNativeSubtitleCue(
                id: cue.id, startTime: cue.startTime, endTime: cue.endTime, text: text)
            if companion { recognizedCompanionCueIDs.insert(cue.id) }
            else { recognizedBitmapCueIDs.insert(cue.id) }
        }
        let result = merged.values.sorted { $0.startTime < $1.startTime }
        if companion {
            if result != recognizedCompanionSubtitleCues { recognizedCompanionSubtitleCues = result }
        } else if result != recognizedSubtitleCues { recognizedSubtitleCues = result }
    }

    private func scheduleBitmapSubtitleRecognition() {
        guard bitmapRecognitionEnabled, !isRecognizingBitmapSubtitles else { return }
        let now = currentTime
        let companion = recognizingCompanion
        let completed = companion ? recognizedCompanionCueIDs : recognizedBitmapCueIDs
        // 重新取轨会给同一句字幕分配新 ID，按时间复用识别结果，避免反复识别同一张字幕图。
        let cached = companion ? recognizedCompanionSubtitleCues : recognizedSubtitleCues
        let recognizedStarts = Set(cached.map { Int64(($0.startTime * 1_000).rounded()) })
        let pending = (bitmapRecognitionTrackID == nil ? nativeCues : learningNativeCues)
            .filter { $0.image != nil && !completed.contains($0.id)
                && !recognizedStarts.contains(Int64(($0.startTime * 1_000).rounded())) }
            .sorted {
                let aFuture = $0.endTime >= now
                let bFuture = $1.endTime >= now
                if aFuture != bFuture { return aFuture }
                return abs($0.startTime - now) < abs($1.startTime - now)
            }
        guard !pending.isEmpty else { return }
        bitmapRecognitionGeneration &+= 1
        let generation = bitmapRecognitionGeneration
        let language = companion ? companionSubtitleLanguage : bitmapRecognitionLanguage
        isRecognizingBitmapSubtitles = true
        bitmapRecognitionTask = Task { [weak self] in
            guard let self else { return }
            for cue in pending {
                guard !Task.isCancelled, generation == bitmapRecognitionGeneration,
                      let image = cue.image?.cgImage else { break }
                let text = await BitmapSubtitleRecognizer.recognize(image, language: language)
                guard !Task.isCancelled, generation == bitmapRecognitionGeneration else { break }
                if companion { recognizedCompanionCueIDs.insert(cue.id) }
                else { recognizedBitmapCueIDs.insert(cue.id) }
                guard let text else { continue }
                let item = RecognizedNativeSubtitleCue(
                    id: cue.id, startTime: cue.startTime, endTime: cue.endTime, text: text)
                if companion {
                    let index = recognizedCompanionSubtitleCues.firstIndex { $0.startTime > item.startTime }
                        ?? recognizedCompanionSubtitleCues.endIndex
                    recognizedCompanionSubtitleCues.insert(item, at: index)
                } else {
                    let index = recognizedSubtitleCues.firstIndex { $0.startTime > item.startTime }
                        ?? recognizedSubtitleCues.endIndex
                    recognizedSubtitleCues.insert(item, at: index)
                }
            }
            guard generation == bitmapRecognitionGeneration else { return }
            isRecognizingBitmapSubtitles = false
            bitmapRecognitionTask = nil
            scheduleBitmapSubtitleRecognition()
            advanceLearningSubtitleChannel()
        }
    }

    private func resetBitmapSubtitleRecognition(disable: Bool) {
        bitmapRecognitionGeneration &+= 1
        bitmapRecognitionTask?.cancel()
        bitmapRecognitionTask = nil
        recognizedBitmapCueIDs.removeAll()
        recognizedSubtitleCues = []
        recognizedCompanionSubtitleCues = []
        recognizedCompanionCueIDs = []
        learningScanPositions = [:]
        isRecognizingBitmapSubtitles = false
        if disable {
            bitmapRecognitionEnabled = false
            bitmapRecognitionLanguage = nil
            bitmapRecognitionTrackID = nil
            activeLearningSubtitleID = nil
            companionSubtitleID = nil
            cachedCompanionSubtitleID = nil
            companionSubtitleLanguage = nil
        }
    }

    private func updateSubtitle(at time: Double) {
        guard nativeSubtitlesVisible else {
            if currentSubtitleText != nil { currentSubtitleText = nil }
            if !currentSubtitleImages.isEmpty { currentSubtitleImages = [] }
            return
        }
        if assRenderer != nil {
            currentSubtitleText = nil
            renderASS(at: backend.sourceTime)
            return
        }
        let active = nativeCues.filter { $0.startTime <= time && time < $0.endTime }
        let joined = active.compactMap(\.text).joined(separator: "\n")
        let text = joined.isEmpty ? nil : joined
        if currentSubtitleText != text { currentSubtitleText = text }
        let images = active.compactMap(\.image)
        if currentSubtitleImages.map(\.id) != images.map(\.id) {
            currentSubtitleImages = images
        }
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private nonisolated static func stageTitle(_ stage: StartupStage) -> String {
        switch stage {
        case .connecting: "连接片源"
        case .openingContainer: "打开容器"
        case .analyzingStreams: "分析轨道"
        case .preparingDisplay: "准备显示"
        case .selectingRoute: "选择播放路线"
        case .buildingSession: "建立播放会话"
        case .preparingPlayback: "准备播放"
        case .awaitingFirstFrame: "等待首帧"
        case .presenting: "首帧已显示"
        }
    }
}
