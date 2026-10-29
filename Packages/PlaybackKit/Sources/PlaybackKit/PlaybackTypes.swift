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

public struct TrackOption: Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var language: String?
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
