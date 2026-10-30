import Foundation

public enum TMDBMediaType: String, Hashable, Codable, Sendable {
    case movie, tv
}

/// 指向 TMDB 上的一部电影或剧集。
public struct TMDBRef: Hashable, Codable, Sendable {
    public var type: TMDBMediaType
    public var id: Int

    public init(type: TMDBMediaType, id: Int) {
        self.type = type
        self.id = id
    }
}

public struct TMDBCast: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
}

public struct TMDBSeason: Hashable, Sendable {
    public var number: Int
    public var name: String
    public var episodeCount: Int?
    public var posterPath: String?
    public var year: Int?
}

/// 详情页需要的全部信息，已经从 TMDB 原始结构整理好。
public struct TMDBTitle: Hashable, Sendable {
    public var ref: TMDBRef
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var tagline: String?
    public var year: Int?
    public var genres: [String]
    public var voteAverage: Double?
    public var runtimeMinutes: Int?
    public var seasonCount: Int?
    public var networks: [String]
    public var originalLanguage: String?
    public var posterPath: String?
    public var backdropPath: String?
    /// 片名 Logo（透明 PNG），优先英文，其次中文、无文字。
    public var logoPath: String?
    public var cast: [TMDBCast]
    public var seasons: [TMDBSeason]
    /// 上映或首播日期，形如 2005-03-24。
    public var releaseDate: String? = nil
    /// 出品国家或地区代码，比如 US、GB。
    public var countries: [String] = []
}

public struct TMDBSearchHit: Hashable, Sendable {
    public var ref: TMDBRef
    public var title: String
    public var year: Int?
    public var posterPath: String?
    public var popularity: Double?
}

public enum TMDBImageSize: String, Sendable {
    case posterSmall = "w342"
    case poster = "w500"
    case posterLarge = "w780"
    case backdrop = "w1280"
    case profile = "w185"
    case original = "original"
}

public enum TMDBError: Error, LocalizedError, Equatable {
    case missingCredential
    case unauthorized
    case notFound
    case http(Int)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "还没有填写 TMDB 密钥"
        case .unauthorized: "TMDB 密钥无效"
        case .notFound: "TMDB 上找不到这部作品"
        case .http(let status): "TMDB 返回错误 \(status)"
        case .network(let message): "连接 TMDB 失败：\(message)。国内网络可能需要在设置里填写代理地址"
        case .decoding(let message): "无法解析 TMDB 数据：\(message)"
        }
    }
}

// MARK: - TMDB 原始 JSON（snake_case，解码时自动转换）

struct RawImage: Decodable {
    var filePath: String
    var iso6391: String?
    var voteAverage: Double?
    var width: Int?
    var height: Int?
}

struct RawImages: Decodable {
    var logos: [RawImage]?
    var backdrops: [RawImage]?
}

struct RawCredits: Decodable {
    struct Cast: Decodable {
        var id: Int
        var name: String
        var character: String?
        var profilePath: String?
        var order: Int?
    }

    var cast: [Cast]?
}

struct RawDetails: Decodable {
    struct Named: Decodable { var name: String }
    struct Season: Decodable {
        var seasonNumber: Int
        var name: String?
        var episodeCount: Int?
        var posterPath: String?
        var airDate: String?
    }

    var id: Int
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var tagline: String?
    var releaseDate: String?
    var firstAirDate: String?
    var genres: [Named]?
    var voteAverage: Double?
    var runtime: Int?
    var episodeRunTime: [Int]?
    var numberOfSeasons: Int?
    var networks: [Named]?
    var originalLanguage: String?
    var posterPath: String?
    var backdropPath: String?
    var images: RawImages?
    var credits: RawCredits?
    var seasons: [Season]?
    var productionCountries: [Country]?
    var originCountry: [String]?
    struct Country: Decodable { var iso31661: String }
}

struct RawSearch: Decodable {
    struct Hit: Decodable {
        var id: Int
        var title: String?
        var name: String?
        var releaseDate: String?
        var firstAirDate: String?
        var posterPath: String?
        var popularity: Double?
    }

    var results: [Hit]
}

func parseYear(_ date: String?) -> Int? {
    guard let date, date.count >= 4 else { return nil }
    return Int(date.prefix(4))
}

extension TMDBTitle {
    init(raw: RawDetails, type: TMDBMediaType) {
        let logos = raw.images?.logos ?? []
        func best(_ lang: String?) -> RawImage? {
            logos.filter { $0.iso6391 == lang }.max { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) }
        }
        let backdrop = (raw.images?.backdrops ?? [])
            .filter { ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 }
            .max { lhs, rhs in
                let leftPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
                let rightPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
                return leftPixels == rightPixels
                    ? (lhs.voteAverage ?? 0) < (rhs.voteAverage ?? 0) : leftPixels < rightPixels
            }?.filePath ?? raw.backdropPath
        self.init(
            ref: TMDBRef(type: type, id: raw.id),
            title: raw.title ?? raw.name ?? "",
            originalTitle: raw.originalTitle ?? raw.originalName,
            overview: raw.overview?.isEmpty == false ? raw.overview : nil,
            tagline: raw.tagline?.isEmpty == false ? raw.tagline : nil,
            year: parseYear(raw.releaseDate ?? raw.firstAirDate),
            genres: raw.genres?.map(\.name) ?? [],
            voteAverage: raw.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            runtimeMinutes: raw.runtime ?? raw.episodeRunTime?.first,
            seasonCount: raw.numberOfSeasons,
            networks: raw.networks?.map(\.name) ?? [],
            originalLanguage: raw.originalLanguage,
            posterPath: raw.posterPath,
            backdropPath: backdrop,
            logoPath: (best("en") ?? best("zh") ?? best(nil) ?? logos.first)?.filePath,
            cast: (raw.credits?.cast ?? []).sorted { ($0.order ?? 999) < ($1.order ?? 999) }.prefix(12).map {
                TMDBCast(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profilePath)
            },
            seasons: (raw.seasons ?? []).filter { $0.seasonNumber > 0 }.map {
                TMDBSeason(number: $0.seasonNumber, name: $0.name ?? "第 \($0.seasonNumber) 季",
                           episodeCount: $0.episodeCount, posterPath: $0.posterPath, year: parseYear($0.airDate))
            },
            releaseDate: (raw.releaseDate ?? raw.firstAirDate).flatMap { $0.isEmpty ? nil : $0 },
            countries: raw.originCountry.flatMap { $0.isEmpty ? nil : $0 }
                ?? (raw.productionCountries ?? []).map(\.iso31661))
    }
}
