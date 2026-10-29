import AppKit
import AVFoundation
import LearningCore
import Observation
import QuartzCore
import libmpv

private final class MPVWakeupContext: @unchecked Sendable {
    weak var engine: MPVPlayerEngine?
    init(engine: MPVPlayerEngine) { self.engine = engine }
}

private final class MPVResources: @unchecked Sendable {
    var handle: OpaquePointer?
    var wakeupContext: UnsafeMutableRawPointer?
    let streamRegistry = MPVStreamRegistry()

    init(handle: OpaquePointer?) { self.handle = handle }

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
        if let wakeupContext {
            Unmanaged<MPVWakeupContext>.fromOpaque(wakeupContext).release()
        }
    }
}

private func mpvWakeup(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<MPVWakeupContext>.fromOpaque(context).takeUnretainedValue()
    guard let engine = box.engine else { return }
    DispatchQueue.main.async { [weak engine] in
        guard let engine else { return }
        MainActor.assumeIsolated { engine.drainEvents() }
    }
}

/// libmpv 单引擎：直接读取 MKV 等原文件，由 mpv 统一负责拆包、硬解、缓存、跳转和音画同步。
@MainActor
@Observable
public final class MPVPlayerEngine: SegmentPlayer, @unchecked Sendable {
    public let surface = MPVSurfaceView()

    public private(set) var state: PlaybackState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var bufferedTime: Double = 0
    public private(set) var presentationSize: CGSize = .zero
    public private(set) var audioOptions: [TrackOption] = []
    public private(set) var selectedAudioID: Int?
    public private(set) var videoDescription: String?
    public private(set) var nativeSubtitlesVisible = true
    public private(set) var nativeSubtitleDescription: String?

    public var rate: Double = 1 {
        didSet { setDouble("speed", rate) }
    }

    public var volume: Float = 1 {
        didSet { setDouble("volume", Double(volume * 100)) }
    }

    public var isMuted = false {
        didSet { setFlag("mute", isMuted) }
    }

    public var absoluteTime: Double { currentTime }

    @ObservationIgnored private let resources: MPVResources
    private var handle: OpaquePointer? { resources.handle }
    @ObservationIgnored private var autoplay = true
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var segmentGeneration: UInt64 = 0
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var observedTime: Double = 0
    @ObservationIgnored private let headless: Bool
    @ObservationIgnored private var didAutoSelectSubtitle = false
    @ObservationIgnored private var hasAbsoluteCacheTime = false

    public init(headless: Bool = false) {
        self.headless = headless
        let resources = MPVResources(handle: mpv_create())
        self.resources = resources
        guard let handle = resources.handle else {
            state = .failed("无法创建 libmpv 播放内核")
            return
        }
        configure(handle)
        let context = Unmanaged.passRetained(MPVWakeupContext(engine: self)).toOpaque()
        resources.wakeupContext = context
        mpv_set_wakeup_callback(handle, mpvWakeup, context)
    }

    /// 加载原文件。preload 为 true 时完成拆包和首帧准备，但保持暂停。
    public func load(url: URL, startAt: Double? = nil, autoplay: Bool = true,
                     durationHint: Double? = nil, preload: Bool = false,
                     cachedSource: CachedMediaSource? = nil) {
        guard handle != nil else {
            state = .failed("libmpv 不可用")
            return
        }
        cancelSegment()
        seekGeneration &+= 1
        state = .loading
        currentTime = startAt ?? 0
        observedTime = currentTime
        bufferedTime = currentTime
        hasAbsoluteCacheTime = false
        duration = durationHint ?? 0
        presentationSize = .zero
        audioOptions = []
        selectedAudioID = nil
        videoDescription = nil
        nativeSubtitleDescription = nil
        didAutoSelectSubtitle = false
        setNativeSubtitlesVisible(true)
        lastError = nil
        loadedURL = url
        self.autoplay = autoplay && !preload
        configureBuffering(forPreload: preload)
        setFlag("pause", true)
        var options: [String] = ["pause=yes"]
        if let startAt, startAt > 0 { options.append("start=\(startAt)") }
        let playbackURL = cachedSource.map(resources.streamRegistry.register) ?? url
        command("loadfile", [playbackURL.isFileURL ? playbackURL.path : playbackURL.absoluteString,
                             "replace", "-1", options.joined(separator: ",")])
    }

    /// 详情页预热完成后，播放窗口直接激活同一个内核，不重新打开文件。
    public func activatePreloaded(url: URL, autoplay: Bool = true) -> Bool {
        guard loadedURL == url, state != .idle, !state.isFailed else { return false }
        self.autoplay = autoplay
        configureBuffering(forPreload: false)
        if autoplay { play() }
        return true
    }

    public func stop() {
        cancelSegment()
        seekGeneration &+= 1
        command("stop")
        loadedURL = nil
        currentTime = 0
        observedTime = 0
        bufferedTime = 0
        duration = 0
        state = .idle
    }

    public func applyCacheLimit() {
        resources.streamRegistry.applyConfiguredLimit(excludingActive: state != .idle)
    }

    public func prepareForCacheClear() {
        stop()
        resources.streamRegistry.reset()
    }

    public func play() {
        if state == .ended { Task { await seek(to: 0, exact: true); setFlag("pause", false) }; return }
        setDouble("speed", rate)
        setFlag("pause", false)
        state = .playing
    }

    public func pause() {
        setFlag("pause", true)
        if state != .ended { state = .paused }
    }

    public func togglePlay() {
        state == .playing ? pause() : play()
    }

    /// 跳转采用“最后一次请求生效”：连续拖动或连点字幕时，旧请求不会覆盖新位置。
    public func seek(to seconds: Double, exact: Bool = false) async {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        seekGeneration &+= 1
        let generation = seekGeneration
        command("seek", [String(format: "%.3f", target), exact ? "absolute+exact" : "absolute"])

        let deadline = ContinuousClock.now + .seconds(5)
        let tolerance = exact ? 0.18 : 0.8
        while generation == seekGeneration, ContinuousClock.now < deadline {
            if abs(observedTime - target) <= tolerance, !getFlag("seeking") { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    public func skip(by seconds: Double) {
        Task { await seek(to: absoluteTime + seconds) }
    }

    public func selectAudio(_ id: Int) {
        setInt("aid", id)
        selectedAudioID = id
    }

    /// 学习层字幕尚未就绪时由 mpv 直接显示 ASS/PGS；文本字幕下载完成后切回可点击的自绘字幕。
    public func setNativeSubtitlesVisible(_ visible: Bool) {
        nativeSubtitlesVisible = visible
        setFlag("sub-visibility", visible)
    }

    public func diagnostics() -> PlaybackDiagnostics {
        let hardwareDecoder = getString("hwdec-current")
        let decoder = hardwareDecoder.map { $0 == "no" ? "software" : $0 } ?? "检测中"
        return PlaybackDiagnostics(
            indicatedBitrate: nil,
            observedBitrate: getDouble("cache-speed").nonZero,
            droppedFrames: getInt("frame-drop-count"),
            playbackType: "libmpv / \(decoder)",
            lastError: lastError)
    }

    // MARK: SegmentPlayer

    public func play(_ range: TimeRange, rate: Double) async throws {
        try Task.checkCancellation()
        cancelSegment()
        let generation = segmentGeneration
        await seek(to: range.start.seconds, exact: true)
        guard generation == segmentGeneration else { throw CancellationError() }
        try Task.checkCancellation()
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
            Task { @MainActor [weak self] in
                guard let self, self.segmentGeneration == generation else { return }
                self.pause()
            }
        }
    }

    private func cancelSegment() {
        segmentGeneration &+= 1
    }

    // MARK: mpv

    private func configure(_ handle: OpaquePointer) {
        if !headless {
            var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(surface.metalLayer).toOpaque()))
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer)
        }
        var options: [(String, String)] = [
            ("hwdec", "videotoolbox"),
            ("hwdec-codecs", "all"),
            ("video-sync", "audio"),
            ("audio-pitch-correction", "yes"),
            ("sub-visibility", "yes"),
            ("sub-auto", "fuzzy"),
            ("slang", "eng,en,zho,chi,zh"),
            ("sub-ass-override", "no"),
            ("cache", "yes"),
            ("cache-pause", "yes"),
            ("cache-pause-initial", "no"),
            ("cache-pause-wait", "1"),
            ("cache-secs", "60"),
            ("demuxer-max-bytes", "512MiB"),
            ("demuxer-max-back-bytes", "128MiB"),
            ("demuxer-seekable-cache", "yes"),
            ("demuxer-thread", "yes"),
            ("hr-seek", "yes"),
            ("hr-seek-framedrop", "yes"),
            ("keep-open", "yes"),
            ("osc", "no"),
            ("input-default-bindings", "no"),
        ]
        if headless {
            options += [("vo", "null"), ("ao", "null")]
        } else {
            options += [("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk")]
        }
        for (name, value) in options { mpv_set_option_string(handle, name, value) }
        let registry = Unmanaged.passUnretained(resources.streamRegistry).toOpaque()
        mpv_stream_cb_add_ro(handle, "elcache", registry, mpvCacheOpen)
        mpv_request_log_messages(handle, "warn")
        guard mpv_initialize(handle) >= 0 else {
            resources.handle = nil
            state = .failed("libmpv 初始化失败")
            return
        }
        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("seeking", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("width", MPV_FORMAT_INT64)
        observe("height", MPV_FORMAT_INT64)
        observe("track-list", MPV_FORMAT_NONE)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("demuxer-cache-time", MPV_FORMAT_DOUBLE)
        observe("demuxer-cache-duration", MPV_FORMAT_DOUBLE)
    }

    private func configureBuffering(forPreload preload: Bool) {
        setInt("demuxer-max-bytes", preload ? 32 * 1024 * 1024 : 512 * 1024 * 1024)
        setInt("demuxer-max-back-bytes", preload ? 8 * 1024 * 1024 : 128 * 1024 * 1024)
        setDouble("cache-secs", preload ? 5 : 60)
    }

    private func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    fileprivate func drainEvents() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                fileLoaded()
            case MPV_EVENT_PROPERTY_CHANGE:
                propertyChanged(event.pointee.data)
            case MPV_EVENT_END_FILE:
                endFile(event.pointee.data)
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    if let text = message.text { NSLog("libmpv: %s", text) }
                }
            default:
                break
            }
        }
    }

    private func fileLoaded() {
        let mpvDuration = getDouble("duration")
        if mpvDuration > 0 { duration = mpvDuration }
        reloadPresentationInfo()
        state = autoplay ? .playing : .paused
        setFlag("pause", !autoplay)
    }

    private func propertyChanged(_ data: UnsafeMutableRawPointer?) {
        guard let data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let rawName = property.name else { return }
        let name = String(cString: rawName)
        switch name {
        case "time-pos":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee, value.isFinite {
                observedTime = value
                currentTime = value
                if bufferedTime < value { bufferedTime = value }
            }
        case "duration":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee, value > 0 { duration = value }
        case "pause":
            if state != .loading, state != .ended, let value = flag(from: property.data) {
                state = value ? .paused : .playing
            }
        case "paused-for-cache":
            if flag(from: property.data) == true { state = .loading }
            else if state == .loading { state = getFlag("pause") ? .paused : .playing }
        case "eof-reached":
            if flag(from: property.data) == true { state = .ended }
        case "width", "height", "track-list", "hwdec-current":
            reloadPresentationInfo()
        case "demuxer-cache-time":
            if let value = property.data?.assumingMemoryBound(to: Double.self).pointee, value.isFinite {
                hasAbsoluteCacheTime = true
                bufferedTime = min(duration > 0 ? duration : value, max(currentTime, value))
            }
        case "demuxer-cache-duration":
            if !hasAbsoluteCacheTime,
               let value = property.data?.assumingMemoryBound(to: Double.self).pointee, value.isFinite {
                bufferedTime = min(duration > 0 ? duration : currentTime + value, currentTime + max(0, value))
            }
        default:
            break
        }
    }

    private func endFile(_ data: UnsafeMutableRawPointer?) {
        guard let data else { state = .ended; return }
        let event = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if event.reason == MPV_END_FILE_REASON_ERROR {
            let message = String(cString: mpv_error_string(event.error))
            lastError = message
            state = .failed(message)
        } else if loadedURL != nil {
            state = .ended
        }
    }

    private func reloadPresentationInfo() {
        let width = getInt("width")
        let height = getInt("height")
        if width > 0, height > 0 { presentationSize = CGSize(width: width, height: height) }
        let codec = getString("video-codec") ?? getString("video-format")
        if let codec, width > 0, height > 0 {
            let hwdec = getString("hwdec-current")
            let decoder = hwdec == nil ? "" : hwdec == "no" ? " · 软件解码" : " · 硬件解码"
            videoDescription = "\(codec.uppercased()) \(width)×\(height)\(decoder)"
        }

        let count = getInt("track-list/count")
        var options: [TrackOption] = []
        var selected: Int?
        var firstSubtitleID: Int?
        var selectedSubtitle: String?
        for index in 0..<count {
            let type = getString("track-list/\(index)/type")
            let id = getInt("track-list/\(index)/id")
            let language = getString("track-list/\(index)/lang")
            let title = getString("track-list/\(index)/title") ?? language
            if type == "audio" {
                options.append(TrackOption(id: id, title: title ?? "音轨 \(options.count + 1)", language: language))
                if getFlag("track-list/\(index)/selected") { selected = id }
            } else if type == "sub" {
                firstSubtitleID = firstSubtitleID ?? id
                if getFlag("track-list/\(index)/selected") { selectedSubtitle = title ?? "字幕 \(id)" }
            }
        }
        audioOptions = options
        selectedAudioID = selected
        if selectedSubtitle == nil, !didAutoSelectSubtitle, let firstSubtitleID {
            didAutoSelectSubtitle = true
            setInt("sid", firstSubtitleID)
            selectedSubtitle = "字幕 \(firstSubtitleID)"
        }
        nativeSubtitleDescription = selectedSubtitle
    }

    private func flag(from pointer: UnsafeMutableRawPointer?) -> Bool? {
        pointer?.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func command(_ name: String, _ arguments: [String] = []) {
        guard let handle else { return }
        var values: [UnsafePointer<CChar>?] = ([name] + arguments).map { value in
            guard let pointer = strdup(value) else { return nil }
            return UnsafePointer(pointer)
        }
        values.append(nil)
        defer {
            values.dropLast().forEach { pointer in
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }
        values.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setInt(_ name: String, _ value: Int) {
        guard let handle else { return }
        var number = Int64(value)
        mpv_set_property(handle, name, MPV_FORMAT_INT64, &number)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var number = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number)
    }

    private func getFlag(_ name: String) -> Bool {
        guard let handle else { return false }
        var flag: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &flag)
        return flag != 0
    }

    private func getInt(_ name: String) -> Int {
        guard let handle else { return 0 }
        var number: Int64 = 0
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &number)
        return Int(number)
    }

    private func getDouble(_ name: String) -> Double {
        guard let handle else { return 0 }
        var number = 0.0
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &number)
        return number
    }

    private func getString(_ name: String) -> String? {
        guard let handle, let pointer = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(pointer) }
        return String(cString: pointer)
    }
}

public final class MPVSurfaceView: NSView {
    public let metalLayer = CAMetalLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var mouseDownCanMoveWindow: Bool { true }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
