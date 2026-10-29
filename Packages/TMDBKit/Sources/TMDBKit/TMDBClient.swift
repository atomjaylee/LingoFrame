import Foundation
import os

/// TMDB 的接入配置。国内网络经常连不上官方地址，所以接口和图片地址都可以换成代理。
public struct TMDBConfig: Hashable, Codable, Sendable {
    public var apiBase: URL
    public var imageBase: URL
    /// 简介、片名、类型使用的语言。
    public var language: String

    public init(apiBase: URL = URL(string: "https://api.themoviedb.org/3")!,
                imageBase: URL = URL(string: "https://image.tmdb.org/t/p")!,
                language: String = "zh-CN") {
        self.apiBase = apiBase
        self.imageBase = imageBase
        self.language = language
    }

    public static let `default` = TMDBConfig()
}

/// TMDB 客户端。只读请求，带内存和磁盘缓存（7 天），同一部作品不会反复请求。
public actor TMDBClient {
    public nonisolated let config: TMDBConfig
    private let token: String
    private let session: URLSession
    private let cacheDirectory: URL?
    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private static let log = Logger(subsystem: "app.elenglish", category: "tmdb")
    private static let cacheLifetime: TimeInterval = 7 * 24 * 3600

    /// token 可以是 v3 的 API Key（32 位），也可以是 v4 的 Read Access Token（很长的一串）。
    public init(token: String, config: TMDBConfig = .default, session: URLSession = .shared, cacheDirectory: URL? = TMDBClient.defaultCacheDirectory) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.config = config
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.elenglish/tmdb", isDirectory: true)
    }

    // MARK: 图片

    public nonisolated func imageURL(_ path: String?, size: TMDBImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return config.imageBase.appendingPathComponent(size.rawValue).appendingPathComponent(String(path.drop { $0 == "/" }))
    }

    // MARK: 接口

    /// 详情 + 图片（Logo）+ 演员。中文简介为空时用英文简介补上。
    public func details(_ ref: TMDBRef) async throws -> TMDBTitle {
        let path = "\(ref.type.rawValue)/\(ref.id)"
        var title = TMDBTitle(raw: try await get(path, [
            "language": config.language,
            "append_to_response": "images,credits",
            "include_image_language": "en,zh,null",
        ], as: RawDetails.self), type: ref.type)
        if title.overview == nil, config.language != "en-US",
           let english = try? await get(path, ["language": "en-US"], as: RawDetails.self) {
            title.overview = english.overview?.isEmpty == false ? english.overview : nil
        }
        return title
    }

    public func search(_ type: TMDBMediaType, query: String, year: Int? = nil) async throws -> [TMDBSearchHit] {
        let yearKey = type == .movie ? "year" : "first_air_date_year"
        let raw = try await get("search/\(type.rawValue)", [
            "query": query, "language": config.language, yearKey: year.map(String.init),
        ], as: RawSearch.self)
        return raw.results.map {
            TMDBSearchHit(ref: TMDBRef(type: type, id: $0.id), title: $0.title ?? $0.name ?? "",
                          year: parseYear($0.releaseDate ?? $0.firstAirDate), posterPath: $0.posterPath,
                          popularity: $0.popularity)
        }
    }

    /// 按片名和年份找到 TMDB 条目：年份相差一年以内的结果里取最热门的一个。
    public func resolve(_ type: TMDBMediaType, title: String, year: Int?) async throws -> TMDBRef? {
        let hits = try await search(type, query: title, year: year)
        let close = hits.filter { hit in year.map { y in hit.year.map { abs($0 - y) <= 1 } ?? false } ?? true }
        return (close.isEmpty ? hits : close).max { ($0.popularity ?? 0) < ($1.popularity ?? 0) }?.ref
    }

    // MARK: 请求与缓存

    private func get<T: Decodable>(_ path: String, _ query: [String: String?], as type: T.Type) async throws -> T {
        guard !token.isEmpty else { throw TMDBError.missingCredential }
        var components = URLComponents(url: config.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        let usesBearer = token.count > 40
        if !usesBearer { items.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = items
        let url = components.url!
        // 缓存键不含密钥。
        let key = path + "?" + items.filter { $0.name != "api_key" }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")

        let data = try await cachedData(key: key) { [session, token] in
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if usesBearer { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw TMDBError.network(error.localizedDescription)
            }
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return data
            case 401: throw TMDBError.unauthorized
            case 404: throw TMDBError.notFound
            case let status: throw TMDBError.http(status)
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("解码失败 \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw TMDBError.decoding(String(describing: T.self))
        }
    }

    private func cachedData(key: String, fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let data = memory[key] { return data }
        let file = cacheDirectory?.appendingPathComponent(Self.hash(key) + ".json")
        if let file, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < Self.cacheLifetime,
           let data = try? Data(contentsOf: file) {
            memory[key] = data
            return data
        }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        memory[key] = data
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 36)
    }
}
