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

struct VideoCrop: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum VideoBlackBarDetector {
    static func horizontalCrop(bytes: UnsafeRawPointer, width: Int, height: Int, stride: Int) -> VideoCrop? {
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        let pixels = bytes.assumingMemoryBound(to: UInt8.self)
        let xStep = max(1, width / 256)
        let xStart = width / 20
        let xEnd = width - xStart

        func rowIsBlack(_ y: Int) -> Bool {
            var samples = 0
            var black = 0
            for x in Swift.stride(from: xStart, to: xEnd, by: xStep) {
                let offset = y * stride + x * 4
                let brightest = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
                samples += 1
                if brightest <= 12 { black += 1 }
            }
            return samples > 0 && black * 100 >= samples * 98
        }

        var top = 0
        while top < height / 4, rowIsBlack(top) { top += 1 }
        var bottom = 0
        while bottom < height / 4, rowIsBlack(height - bottom - 1) { bottom += 1 }
        var inset = min(top, bottom)
        guard inset >= max(2, Int(Double(height) * 0.015)) else { return nil }
        inset -= inset % 2
        let croppedHeight = height - inset * 2
        guard croppedHeight > height / 2 else { return nil }
        return VideoCrop(x: 0, y: inset, width: width, height: croppedHeight)
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
    public private(set) var subtitleOptions: [TrackOption] = []
    public private(set) var selectedSubtitleID: Int?
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
    @ObservationIgnored private var mediaGeneration: UInt64 = 0
    @ObservationIgnored private var videoRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var needsVideoReloadOnAttach = false
    @ObservationIgnored private var fileIsLoaded = false
    @ObservationIgnored private var cropDetectionTask: Task<Void, Never>?

    public init(headless: Bool = false) {
        self.headless = headless
        let resources = MPVResources(handle: mpv_create())
        self.resources = resources
        surface.onWindowChanged = { [weak self] attached in
            self?.surfaceAttachmentChanged(attached)
        }
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
        videoRecoveryTask?.cancel()
        cropDetectionTask?.cancel()
        mediaGeneration &+= 1
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
        subtitleOptions = []
        selectedSubtitleID = nil
        videoDescription = nil
        nativeSubtitleDescription = nil
        didAutoSelectSubtitle = false
        setNativeSubtitlesVisible(true)
        lastError = nil
        loadedURL = url
        needsVideoReloadOnAttach = surface.window == nil
        fileIsLoaded = false
        setString("video-crop", "")
        self.autoplay = autoplay && !preload
        configureBuffering(forPreload: preload)
        setFlag("pause", true)
        var options: [String] = ["pause=yes", "vid=auto", "sid=auto"]
        if let startAt, startAt > 0 { options.append("start=\(startAt)") }
        let playbackURL = cachedSource.map(resources.streamRegistry.register) ?? url
        let result = command("loadfile", [playbackURL.isFileURL ? playbackURL.path : playbackURL.absoluteString,
                                          "replace", "-1", options.joined(separator: ",")])
        if result < 0 {
            let message = String(cString: mpv_error_string(result))
            lastError = message
            state = .failed(message)
        }
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
        videoRecoveryTask?.cancel()
        cropDetectionTask?.cancel()
        mediaGeneration &+= 1
        seekGeneration &+= 1
        command("stop")
        loadedURL = nil
        needsVideoReloadOnAttach = false
        fileIsLoaded = false
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
        if state == .ended {
            state = .paused
            Task { [weak self] in
                guard let self else { return }
                await self.seek(to: 0, exact: true)
                guard self.state == .paused else { return }
                self.play()
            }
            return
        }
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
        guard command("seek", [String(format: "%.3f", target), exact ? "absolute+exact" : "absolute"]) >= 0 else { return }

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

    public func selectSubtitle(_ id: Int?) {
        if let id {
            setInt("sid", id)
            selectedSubtitleID = id
            setNativeSubtitlesVisible(true)
        } else {
            setString("sid", "no")
            selectedSubtitleID = nil
            setNativeSubtitlesVisible(false)
        }
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
            mpv_terminate_destroy(handle)
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
        observe("dwidth", MPV_FORMAT_INT64)
        observe("dheight", MPV_FORMAT_INT64)
        observe("track-list", MPV_FORMAT_NONE)
        observe("hwdec-current", MPV_FORMAT_STRING)
        observe("demuxer-cache-time", MPV_FORMAT_DOUBLE)
        observe("demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        observe("vo-configured", MPV_FORMAT_FLAG)
    }

    private func configureBuffering(forPreload preload: Bool) {
        setInt("demuxer-max-bytes", preload ? 32 * 1024 * 1024 : 512 * 1024 * 1024)
        setInt("demuxer-max-back-bytes", preload ? 8 * 1024 * 1024 : 128 * 1024 * 1024)
        setDouble("cache-secs", preload ? 5 : 60)
    }

    private func surfaceAttachmentChanged(_ attached: Bool) {
        guard attached else { return }
        recoverVideoAfterAttachmentIfNeeded()
    }

    private func recoverVideoAfterAttachmentIfNeeded() {
        guard needsVideoReloadOnAttach, fileIsLoaded, surface.window != nil, loadedURL != nil else { return }
        needsVideoReloadOnAttach = false
        setString("vid", "auto")
        command("video-reload")
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
        fileIsLoaded = true
        recoverVideoAfterAttachmentIfNeeded()
        let mpvDuration = getDouble("duration")
        if mpvDuration > 0 { duration = mpvDuration }
        reloadPresentationInfo()
        state = autoplay ? .playing : .paused
        setFlag("pause", !autoplay)
        let generation = mediaGeneration
        videoRecoveryTask?.cancel()
        videoRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, generation == self.mediaGeneration,
                  self.loadedURL != nil, self.getString("video-codec") != nil,
                  !self.getFlag("vo-configured") else { return }
            self.setString("vid", "auto")
            self.command("video-reload")
        }
        if !headless {
            cropDetectionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled, generation == self.mediaGeneration else { return }
                self.detectAndApplyBlackBarCrop()
            }
        }
    }

    private func propertyChanged(_ data: UnsafeMutableRawPointer?) {
        guard let data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let rawName = property.name else { return }
        let name = String(cString: rawName)
        guard loadedURL != nil else { return }
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
            if flag(from: property.data) == true, state != .loading, loadedURL != nil { state = .ended }
        case "width", "height", "dwidth", "dheight", "track-list", "hwdec-current":
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
        guard loadedURL != nil, let data else { return }
        let event = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if event.reason == MPV_END_FILE_REASON_ERROR {
            let message = String(cString: mpv_error_string(event.error))
            lastError = message
            state = .failed(message)
        } else if event.reason == MPV_END_FILE_REASON_EOF, loadedURL != nil {
            state = .ended
        }
        // loadfile replace 和主动 stop 都会产生 STOP；它不是当前文件播放完毕，不能展示“下一集”。
    }

    private func reloadPresentationInfo() {
        let width = getInt("width")
        let height = getInt("height")
        let displayWidth = getInt("dwidth")
        let displayHeight = getInt("dheight")
        let fittedWidth = displayWidth > 0 ? displayWidth : width
        let fittedHeight = displayHeight > 0 ? displayHeight : height
        if fittedWidth > 0, fittedHeight > 0 {
            presentationSize = CGSize(width: fittedWidth, height: fittedHeight)
        }
        let codec = getString("video-codec") ?? getString("video-format")
        if let codec, width > 0, height > 0 {
            let hwdec = getString("hwdec-current")
            let decoder = hwdec == nil ? "" : hwdec == "no" ? " · 软件解码" : " · 硬件解码"
            videoDescription = "\(codec.uppercased()) \(width)×\(height)\(decoder)"
        }

        let count = getInt("track-list/count")
        var options: [TrackOption] = []
        var selected: Int?
        var subtitles: [TrackOption] = []
        var firstSubtitleID: Int?
        var selectedSubtitleID: Int?
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
                subtitles.append(TrackOption(id: id, title: title ?? "字幕 \(subtitles.count + 1)", language: language))
                if getFlag("track-list/\(index)/selected") { selectedSubtitle = title ?? "字幕 \(id)" }
                if getFlag("track-list/\(index)/selected") { selectedSubtitleID = id }
            }
        }
        audioOptions = options
        selectedAudioID = selected
        if selectedSubtitle == nil, !didAutoSelectSubtitle, let firstSubtitleID {
            didAutoSelectSubtitle = true
            setInt("sid", firstSubtitleID)
            selectedSubtitleID = firstSubtitleID
            selectedSubtitle = "字幕 \(firstSubtitleID)"
        }
        subtitleOptions = subtitles
        self.selectedSubtitleID = selectedSubtitleID
        nativeSubtitleDescription = selectedSubtitle
    }

    private func detectAndApplyBlackBarCrop() {
        guard let handle else { return }
        var values: [UnsafePointer<CChar>?] = (["screenshot-raw", "video", "bgr0"]).map { value in
            guard let pointer = strdup(value) else { return nil }
            return UnsafePointer(pointer)
        }
        values.append(nil)
        defer {
            values.dropLast().forEach { pointer in
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }

        var result = mpv_node()
        let status = values.withUnsafeMutableBufferPointer { buffer in
            mpv_command_ret(handle, buffer.baseAddress, &result)
        }
        guard status >= 0 else {
            #if DEBUG
            NSLog("黑边检测截图失败 %s", mpv_error_string(status))
            #endif
            return
        }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP,
              let width = nodeInt(result, key: "w"),
              let height = nodeInt(result, key: "h"),
              let stride = nodeInt(result, key: "stride"),
              let data = nodeBytes(result, key: "data"),
              let crop = VideoBlackBarDetector.horizontalCrop(bytes: data, width: width,
                                                               height: height, stride: stride)
        else {
            #if DEBUG
            NSLog("黑边检测未发现可裁剪区域")
            #endif
            return
        }

        #if DEBUG
        NSLog("黑边检测 %ldx%ld -> %ldx%ld+%ld+%ld", width, height,
              crop.width, crop.height, crop.x, crop.y)
        #endif

        setString("video-crop", "\(crop.width)x\(crop.height)+\(crop.x)+\(crop.y)")
        let displayWidth = getInt("dwidth")
        let displayHeight = getInt("dheight")
        guard displayWidth > 0, displayHeight > 0 else { return }
        presentationSize = CGSize(width: Double(displayWidth) * Double(crop.width) / Double(width),
                                  height: Double(displayHeight) * Double(crop.height) / Double(height))
    }

    private func node(_ node: mpv_node, key: String) -> mpv_node? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee,
              let keys = list.keys, let values = list.values else { return nil }
        for index in 0..<Int(list.num) {
            if let rawKey = keys[index], String(cString: rawKey) == key { return values[index] }
        }
        return nil
    }

    private func nodeInt(_ node: mpv_node, key: String) -> Int? {
        guard let value = self.node(node, key: key), value.format == MPV_FORMAT_INT64 else { return nil }
        return Int(value.u.int64)
    }

    private func nodeBytes(_ node: mpv_node, key: String) -> UnsafeRawPointer? {
        guard let value = self.node(node, key: key), value.format == MPV_FORMAT_BYTE_ARRAY,
              let bytes = value.u.ba?.pointee.data else { return nil }
        return UnsafeRawPointer(bytes)
    }

    private func flag(from pointer: UnsafeMutableRawPointer?) -> Bool? {
        pointer?.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    @discardableResult
    private func command(_ name: String, _ arguments: [String] = []) -> Int32 {
        guard let handle else { return MPV_ERROR_UNINITIALIZED.rawValue }
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
        return values.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
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

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
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
    var onWindowChanged: (@MainActor (Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window != nil)
    }

    public override var mouseDownCanMoveWindow: Bool { true }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
