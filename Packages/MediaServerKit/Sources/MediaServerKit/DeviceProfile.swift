import Foundation

// 设备能力描述：告诉 Emby「这个客户端能直接播什么」，服务器据此决定直接播放、转封装还是转码。

public struct DirectPlayProfile: Codable, Sendable {
    public var type: String
    public var container: String
    public var videoCodec: String?
    public var audioCodec: String?
}

public struct TranscodingProfile: Codable, Sendable {
    public var type: String
    public var container: String
    public var `protocol`: String
    public var videoCodec: String?
    public var audioCodec: String?
    public var context: String
    public var maxAudioChannels: String?
    public var minSegments: Int?
    public var breakOnNonKeyFrames: Bool?
}

public struct SubtitleProfile: Codable, Sendable {
    public var format: String
    public var method: String
}

public struct DeviceProfile: Codable, Sendable {
    public var name: String
    public var maxStreamingBitrate: Int
    public var maxStaticBitrate: Int
    public var musicStreamingTranscodingBitrate: Int
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var subtitleProfiles: [SubtitleProfile]

    public func allowsDirectPlay(container: String?) -> Bool {
        guard let container = container?.lowercased() else { return false }
        return directPlayProfiles.contains { $0.container.lowercased().split(separator: ",").contains { $0 == container } }
    }
}

extension DeviceProfile {
    /// libmpv 直接读取原文件，Emby 只提供地址，不参与转封装或转码。
    public static let libmpv = DeviceProfile(
        name: "ELEnglish libmpv",
        maxStreamingBitrate: 1_000_000_000,
        maxStaticBitrate: 1_000_000_000,
        musicStreamingTranscodingBitrate: 384_000,
        directPlayProfiles: [
            DirectPlayProfile(type: "Video", container: "mkv,mp4,m4v,mov,avi,ts,mpegts,m2ts,webm",
                              videoCodec: "h264,hevc,h265,av1,vp9,mpeg2video,vc1",
                              audioCodec: "aac,mp3,ac3,eac3,truehd,dts,flac,alac,opus,vorbis,pcm"),
        ],
        transcodingProfiles: [],
        subtitleProfiles: ["srt", "subrip", "ass", "ssa", "vtt", "pgssub", "dvdsub"]
            .map { SubtitleProfile(format: $0, method: "External") })
}
