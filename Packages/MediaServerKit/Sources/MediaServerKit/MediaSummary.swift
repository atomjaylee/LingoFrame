// 把 Emby 返回的媒体流信息整理成界面上的标签：4K、杜比视界、HDR10、全景声……

public struct MediaSummary: Hashable, Sendable {
    public enum DynamicRange: Hashable, Sendable {
        case sdr
        case hdr10
        case hdr10Plus
        case hlg
        /// profile 例如 "5"、"8.1"、"7"；拿不到时为 nil。
        case dolbyVision(profile: String?)

        public var title: String {
            switch self {
            case .sdr: "SDR"
            case .hdr10: "HDR10"
            case .hdr10Plus: "HDR10+"
            case .hlg: "HLG"
            case .dolbyVision(let p): p.map { "杜比视界 P\($0)" } ?? "杜比视界"
            }
        }
    }

    public var resolution: String?
    public var dynamicRange: DynamicRange
    public var videoCodec: String?
    public var audio: String?
    public var isAtmos: Bool
    public var isDTSX: Bool

    public init(source: MediaSourceInfo?) {
        let video = source?.videoStream
        let audioStream = source.flatMap { s in
            s.audioStreams.first { $0.index == s.defaultAudioStreamIndex } ?? s.audioStreams.first { $0.isDefault == true }
                ?? s.audioStreams.first
        }
        resolution = video.flatMap(Self.resolution)
        dynamicRange = video.map(Self.dynamicRange) ?? .sdr
        videoCodec = video?.codec?.uppercased()

        let audioText = [audioStream?.profile, audioStream?.title, audioStream?.displayTitle].compactMap { $0 }
            .joined(separator: " ").lowercased()
        isAtmos = audioText.contains("atmos")
        isDTSX = audioText.contains("dts:x") || audioText.contains("dts-x")
        audio = audioStream.map(Self.audioTitle)
    }

    static func resolution(_ s: MediaStream) -> String? {
        guard let w = s.width, let h = s.height else { return nil }
        if w >= 3200 || h >= 2000 { return "4K" }
        if w >= 1800 || h >= 1000 { return "1080p" }
        if w >= 1200 || h >= 700 { return "720p" }
        return "SD"
    }

    static func dynamicRange(_ s: MediaStream) -> DynamicRange {
        let text = [s.videoRange, s.videoRangeType, s.extendedVideoType, s.extendedVideoSubType,
                    s.extendedVideoSubTypeDescription, s.colorTransfer, s.title, s.displayTitle]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if s.dvProfile != nil || text.contains("dolbyvision") || text.contains("dolby vision") || text.contains("dovi") {
            return .dolbyVision(profile: dvProfile(s))
        }
        if text.contains("hdr10+") || text.contains("hdr10plus") { return .hdr10Plus }
        if text.contains("hlg") || text.contains("arib-std-b67") { return .hlg }
        if text.contains("hdr") || text.contains("smpte2084") || text.contains("pq") { return .hdr10 }
        return .sdr
    }

    static func dvProfile(_ s: MediaStream) -> String? {
        if let p = s.dvProfile {
            // Jellyfin 只给数字，P8 时用 HDR10 兼容标记推断 8.1。
            if p == 8, (s.videoRangeType ?? "").uppercased().contains("HDR10") { return "8.1" }
            return "\(p)"
        }
        // Emby："DoviProfile81" → "8.1"，"DoviProfile5" → "5"。
        if let sub = s.extendedVideoSubType?.lowercased(), let r = sub.range(of: "doviprofile") {
            let digits = sub[r.upperBound...].filter(\.isNumber)
            guard let first = digits.first else { return nil }
            return digits.count > 1 ? "\(first).\(digits.dropFirst())" : "\(first)"
        }
        return nil
    }

    static func audioTitle(_ s: MediaStream) -> String {
        let codec: String = switch s.codec?.lowercased() ?? "" {
        case "truehd": "TrueHD"
        case "eac3": "DD+"
        case "ac3": "DD"
        case "dts":
            (s.profile?.lowercased().contains("ma") ?? false) ? "DTS-HD MA" : "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case let other: other.uppercased()
        }
        let channels: String? = s.channels.map { c in
            switch c {
            case 8: "7.1"
            case 6: "5.1"
            case 2: "2.0"
            case 1: "1.0"
            default: "\(c)ch"
            }
        }
        return [codec, channels].compactMap { $0 }.joined(separator: " ")
    }
}
