import AetherEngine
import Combine
import CoreGraphics
import Foundation
import LearningCore
import Observation
import os
import PlaybackCore

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
    public private(set) var presentationSize: CGSize = .zero
    public private(set) var audioOptions: [TrackOption] = []
    public private(set) var selectedAudioID: Int?
    public private(set) var subtitleOptions: [TrackOption] = []
    public private(set) var selectedSubtitleID: Int?
    public private(set) var videoDescription: String?
    public private(set) var nativeSubtitleDescription: String?
    public private(set) var currentSubtitleText: String?
    public private(set) var currentSubtitleImages: [NativeSubtitleImage] = []
    public private(set) var startupMilliseconds: Double?
    public private(set) var startupStage = "未开始"

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
    @ObservationIgnored private var nativeSubtitlesVisible = true
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var segmentGeneration: UInt64 = 0
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
        lastError = nil
        state = .loading
        let options = LoadOptions(
            httpHeaders: source.httpHeaders,
            declaredDurationSeconds: source.durationHint,
            progressiveSegmentDelivery: true,
            autoplay: source.autoplay,
            escalatesToSoftwarePath: true)
        do {
            try await backend.load(url: source.url, startPosition: source.startAt, options: options)
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

    @discardableResult
    public nonisolated static func prewarm(url: URL, httpHeaders: [String: String] = [:]) async -> Bool {
        _ = await AetherEngine.prewarm(url: url, httpHeaders: httpHeaders)
        return AetherEngine.isPrewarmed(url: url)
    }

    public nonisolated static func isPrewarmed(url: URL) -> Bool { AetherEngine.isPrewarmed(url: url) }

    public func play() { backend.play() }
    public func pause() { backend.pause() }

    public func stop() {
        cancelSegment()
        backend.stop()
    }

    public func togglePlay() {
        state == .playing ? pause() : play()
    }

    public func seek(to seconds: Double, exact _: Bool = false) async {
        await backend.seek(to: max(0, duration > 0 ? min(seconds, duration) : seconds))
    }

    public func skip(by seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    public func selectAudio(_ id: Int) {
        selectedAudioID = id
        backend.selectAudioTrack(index: id)
    }

    public func selectSubtitle(_ id: Int?) {
        selectedSubtitleID = id
        if let id { backend.selectSubtitleTrack(index: id) }
        else { backend.clearSubtitle() }
        updateSubtitle(at: currentTime)
    }

    public func setNativeSubtitlesVisible(_ visible: Bool) {
        nativeSubtitlesVisible = visible
        updateSubtitle(at: currentTime)
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
        }.store(in: &cancellables)

        backend.$duration.sink { [weak self] in self?.duration = $0 }.store(in: &cancellables)
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
        }.store(in: &cancellables)
        backend.$activeAudioTrackIndex.sink { [weak self] in self?.selectedAudioID = $0 }.store(in: &cancellables)
        backend.$activeSubtitleTrackIndex.sink { [weak self] id in
            guard let self else { return }
            selectedSubtitleID = id
            nativeSubtitleDescription = subtitleOptions.first(where: { $0.id == id })?.title
        }.store(in: &cancellables)
        backend.$subtitleCues.sink { [weak self] cues in
            self?.nativeCues = cues.map { cue in
                let image: NativeSubtitleImage? = if case .image(let value) = cue.body {
                    NativeSubtitleImage(id: cue.id, cgImage: value.cgImage,
                                        position: value.position, canvasSize: value.canvasSize)
                } else {
                    nil
                }
                return NativeCue(id: cue.id, startTime: cue.startTime, endTime: cue.endTime,
                                 text: cue.text, image: image)
            }
            self?.updateSubtitle(at: self?.currentTime ?? 0)
        }.store(in: &cancellables)
    }

    private func updateSubtitle(at time: Double) {
        guard nativeSubtitlesVisible else {
            currentSubtitleText = nil
            currentSubtitleImages = []
            return
        }
        let active = nativeCues.filter { $0.startTime <= time && time < $0.endTime }
        let text = active.compactMap(\.text).joined(separator: "\n")
        currentSubtitleText = text.isEmpty ? nil : text
        currentSubtitleImages = active.compactMap(\.image)
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
