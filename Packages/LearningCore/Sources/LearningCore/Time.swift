/// 媒体时间，毫秒精度。字幕、单词时间戳、循环区间全部用它，避免浮点误差累积。
public struct MediaTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var ms: Int64

    public init(ms: Int64) { self.ms = ms }
    public init(seconds: Double) { self.ms = Int64((seconds * 1000).rounded()) }

    public var seconds: Double { Double(ms) / 1000 }
    public var description: String { String(format: "%.3fs", seconds) }

    public static func < (a: MediaTime, b: MediaTime) -> Bool { a.ms < b.ms }
    public static func + (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ms: a.ms + b.ms) }
    public static func - (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ms: a.ms - b.ms) }
    public static let zero = MediaTime(ms: 0)
}

/// 半开区间 [start, end)。
public struct TimeRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = max(start, end)
    }

    public init(startMs: Int64, endMs: Int64) {
        self.init(start: MediaTime(ms: startMs), end: MediaTime(ms: endMs))
    }

    public var duration: MediaTime { end - start }
    public var description: String { "[\(start) – \(end))" }

    public func contains(_ t: MediaTime) -> Bool { t >= start && t < end }
    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    public func overlapDuration(with other: TimeRange) -> MediaTime {
        let s = max(start, other.start), e = min(end, other.end)
        return e > s ? e - s : .zero
    }

    public func shifted(by offset: MediaTime) -> TimeRange {
        TimeRange(start: start + offset, end: end + offset)
    }

    /// 句首、句尾留白：句首提前一点，避免吞掉第一个音；句尾多留一点给语气收尾。
    public func padded(_ padding: Padding) -> TimeRange {
        TimeRange(start: max(.zero, start - MediaTime(ms: padding.leadMs)),
                  end: end + MediaTime(ms: padding.trailMs))
    }
}

public struct Padding: Hashable, Codable, Sendable {
    public var leadMs: Int64
    public var trailMs: Int64

    public init(leadMs: Int64, trailMs: Int64) {
        self.leadMs = leadMs
        self.trailMs = trailMs
    }

    public static let none = Padding(leadMs: 0, trailMs: 0)
    public static let `default` = Padding(leadMs: 80, trailMs: 200)
}
