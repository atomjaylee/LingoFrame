import Foundation

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case ended
    case failed(String)

    public var isActive: Bool { self == .playing || self == .paused }
    public var isFailed: Bool { if case .failed = self { true } else { false } }
}

public struct PlaybackSource: Sendable, Equatable {
    public var id: String
    public var url: URL
    public var startAt: Double?
    public var durationHint: Double?
    public var httpHeaders: [String: String]
    public var autoplay: Bool

    public init(id: String, url: URL, startAt: Double? = nil, durationHint: Double? = nil,
                httpHeaders: [String: String] = [:], autoplay: Bool = true) {
        self.id = id
        self.url = url
        self.startAt = startAt
        self.durationHint = durationHint
        self.httpHeaders = httpHeaders
        self.autoplay = autoplay
    }
}

public struct TrackOption: Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var language: String?

    public init(id: Int, title: String, language: String?) {
        self.id = id
        self.title = title
        self.language = language
    }
}

public struct BufferedRange: Hashable, Sendable {
    public var lowerBound: Double
    public var upperBound: Double

    public init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct PlaybackDiagnostics: Sendable {
    public var indicatedBitrate: Double?
    public var observedBitrate: Double?
    public var droppedFrames: Int?
    public var playbackType: String?
    public var lastError: String?

    public init(indicatedBitrate: Double?, observedBitrate: Double?, droppedFrames: Int?,
                playbackType: String?, lastError: String?) {
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.droppedFrames = droppedFrames
        self.playbackType = playbackType
        self.lastError = lastError
    }
}

@MainActor
public protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var bufferedRanges: [BufferedRange] { get }
    var presentationSize: CGSize { get }
    var rate: Double { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var audioOptions: [TrackOption] { get }
    var selectedAudioID: Int? { get }
    var subtitleOptions: [TrackOption] { get }
    var selectedSubtitleID: Int? { get }

    func load(_ source: PlaybackSource) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double, exact: Bool) async
    func selectAudio(_ id: Int)
    func selectSubtitle(_ id: Int?)
    func diagnostics() -> PlaybackDiagnostics
}
