import Foundation

// Emby 的 JSON 字段是 PascalCase（"RunTimeTicks"），解码时统一转成 camelCase（runTimeTicks）。
// 所有字段都是可选的：不同版本的 Emby / Jellyfin 返回的字段差异很大，缺字段不能导致整页解码失败。

/// Emby 的时间单位：1 tick = 100 纳秒。
public enum Ticks {
    public static let perSecond: Int64 = 10_000_000
    public static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(perSecond) }
    public static func from(seconds: Double) -> Int64 { Int64((seconds * Double(perSecond)).rounded()) }
}

public struct ServerInfo: Hashable, Codable, Sendable {
    public var serverName: String?
    public var version: String?
    public var id: String?
}

public struct UserItemData: Hashable, Codable, Sendable {
    public var playbackPositionTicks: Int64?
    public var playedPercentage: Double?
    public var played: Bool?
    public var isFavorite: Bool?
    public var unplayedItemCount: Int?
}

public struct MediaStream: Hashable, Codable, Sendable {
    public var type: String?
    public var index: Int?
    public var codec: String?
    public var profile: String?
    public var language: String?
    public var title: String?
    public var displayTitle: String?
    public var isDefault: Bool?
    public var isForced: Bool?
    public var isExternal: Bool?
    public var isTextSubtitleStream: Bool?
    public var deliveryUrl: String?
    public var width: Int?
    public var height: Int?
    public var bitRate: Int?
    public var bitDepth: Int?
    public var averageFrameRate: Double?
    public var isInterlaced: Bool?
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: Int?
    /// "SDR"、"HDR"、"HDR 10" 等。
    public var videoRange: String?
    /// Jellyfin：如 "DOVIWithHDR10"、"HDR10Plus"。
    public var videoRangeType: String?
    /// Emby 4.8+：如 "DolbyVision"。
    public var extendedVideoType: String?
    /// Emby 4.8+：如 "DoviProfile81"。
    public var extendedVideoSubType: String?
    public var extendedVideoSubTypeDescription: String?
    /// Jellyfin：DV profile 数字。
    public var dvProfile: Int?
    public var colorTransfer: String?
    public var colorPrimaries: String?

    public var kind: Kind {
        switch type?.lowercased() {
        case "video": .video
        case "audio": .audio
        case "subtitle": .subtitle
        default: .other
        }
    }

    public enum Kind: Sendable { case video, audio, subtitle, other }
}

public struct MediaSourceInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String?
    public var path: String?
    public var container: String?
    public var size: Int64?
    public var bitrate: Int?
    public var runTimeTicks: Int64?
    public var isRemote: Bool?
    public var supportsDirectPlay: Bool?
    public var supportsDirectStream: Bool?
    public var supportsTranscoding: Bool?
    public var transcodingUrl: String?
    public var transcodingSubProtocol: String?
    public var transcodingContainer: String?
    public var mediaStreams: [MediaStream]?
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?

    public var streams: [MediaStream] { mediaStreams ?? [] }
    public var videoStream: MediaStream? { streams.first { $0.kind == .video } }
    public var audioStreams: [MediaStream] { streams.filter { $0.kind == .audio } }
    public var subtitleStreams: [MediaStream] { streams.filter { $0.kind == .subtitle } }
}

public struct EmbyItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String?
    public var type: String?
    public var collectionType: String?
    public var isFolder: Bool?
    public var childCount: Int?
    public var seriesId: String?
    public var seriesName: String?
    public var seasonId: String?
    public var seasonName: String?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var productionYear: Int?
    public var premiereDate: String?
    public var overview: String?
    public var runTimeTicks: Int64?
    public var officialRating: String?
    public var communityRating: Double?
    public var genres: [String]?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public var parentBackdropItemId: String?
    public var parentBackdropImageTags: [String]?
    public var parentThumbItemId: String?
    public var parentThumbImageTag: String?
    public var seriesPrimaryImageTag: String?
    public var primaryImageAspectRatio: Double?
    public var userData: UserItemData?
    public var mediaSources: [MediaSourceInfo]?
    public var mediaStreams: [MediaStream]?
    /// 外部数据库编号，比如 ["Tmdb": "2316", "Imdb": "tt0386676"]。
    public var providerIds: [String: String]?

    /// TMDB 编号。JSON 键名转换会把字典键也转成小写开头，所以忽略大小写查找。
    public var tmdbID: Int? {
        providerIds?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }
    }

    /// 只知道 ID 时构造一个占位条目（比如从单集跳到所属剧集），详情页会再按 ID 加载完整信息。
    public init(id: String, name: String?, type: String?) {
        self.id = id
        self.name = name
        self.type = type
    }

    public enum Kind: Sendable { case movie, series, season, episode, collection, video, other }

    public var kind: Kind {
        switch type?.lowercased() {
        case "movie": .movie
        case "series": .series
        case "season": .season
        case "episode": .episode
        case "collectionfolder", "folder", "boxset", "userview": .collection
        case "video", "musicvideo", "trailer": .video
        default: .other
        }
    }

    public var isPlayable: Bool { [.movie, .episode, .video].contains(kind) }
    public var displayName: String { name ?? "未命名" }

    /// 观看进度 0...1；没看过返回 nil。
    public var progress: Double? {
        if let p = userData?.playedPercentage, p > 0 { return p / 100 }
        guard let pos = userData?.playbackPositionTicks, pos > 0, let total = runTimeTicks, total > 0 else { return nil }
        return Double(pos) / Double(total)
    }

    public var resumePositionSeconds: Double? {
        guard let pos = userData?.playbackPositionTicks, pos > 0 else { return nil }
        return Ticks.seconds(pos)
    }

    public var isPlayed: Bool { userData?.played ?? false }

    /// "S01E03" 形式的集数编号。
    public var episodeCode: String? {
        guard kind == .episode, let e = indexNumber else { return nil }
        if let s = parentIndexNumber { return String(format: "S%02dE%02d", s, e) }
        return "E\(e)"
    }

    /// 取图片标签。JSON 键名转换会把字典键也转成小写开头，所以两种大小写都查。
    public func imageTag(_ type: ImageType) -> String? {
        imageTags?[type.rawValue] ?? imageTags?[type.rawValue.prefix(1).lowercased() + type.rawValue.dropFirst()]
    }
}

public enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
}

public struct ItemsPage: Codable, Sendable {
    public var items: [EmbyItem]
    public var totalRecordCount: Int?

    public init(items: [EmbyItem], totalRecordCount: Int?) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }
}

public struct PlaybackInfoResponse: Codable, Sendable {
    public var mediaSources: [MediaSourceInfo]
    public var playSessionId: String?
    public var errorCode: String?
}

public enum PlayMethod: String, Codable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"

    public var title: String {
        switch self {
        case .directPlay: "直接播放"
        case .directStream: "服务器转封装"
        case .transcode: "服务器转码"
        }
    }
}

/// 决定好的播放地址。url 里带访问令牌，不要写进日志。
public struct ResolvedStream: Sendable {
    public var url: URL
    public var method: PlayMethod
    public var mediaSource: MediaSourceInfo
    public var playSessionID: String?
}

/// 播放状态上报。字段名按 Emby 要求编码成 PascalCase。
public struct PlaybackReport: Codable, Sendable {
    public var itemId: String
    public var mediaSourceId: String?
    public var playSessionId: String?
    public var positionTicks: Int64
    public var isPaused: Bool
    public var isMuted: Bool
    public var canSeek: Bool
    public var playMethod: PlayMethod
    public var playbackRate: Double?
    public var eventName: String?
    public var audioStreamIndex: Int?
    public var subtitleStreamIndex: Int?

    public init(itemId: String, mediaSourceId: String?, playSessionId: String?, positionSeconds: Double,
                isPaused: Bool, isMuted: Bool = false, canSeek: Bool = true, playMethod: PlayMethod,
                playbackRate: Double? = nil, eventName: String? = nil,
                audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.positionTicks = Ticks.from(seconds: positionSeconds)
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.canSeek = canSeek
        self.playMethod = playMethod
        self.playbackRate = playbackRate
        self.eventName = eventName
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}
