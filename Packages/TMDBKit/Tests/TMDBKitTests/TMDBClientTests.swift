import Foundation
import Synchronization
import Testing
@testable import TMDBKit

/// 拦截请求的测试桩，按主机名区分，测试可以并行。
final class Stub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    private static let handlers = Mutex<[String: Handler]>([:])
    static let calls = Mutex<[String: Int]>([:])

    static func session(host: String, _ handler: @escaping Handler) -> URLSession {
        handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url!.host()!
        Self.calls.withLock { $0[host, default: 0] += 1 }
        let (status, body) = Self.handlers.withLock { $0[host] }!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func config(_ host: String) -> TMDBConfig {
    TMDBConfig(apiBase: URL(string: "https://\(host)/3")!, imageBase: URL(string: "https://img.\(host)/t/p")!)
}

private let officeJSON = """
{"id":2316,"name":"办公室","original_name":"The Office","overview":"","tagline":"","first_air_date":"2005-03-24",
 "genres":[{"name":"喜剧"}],"vote_average":8.6,"episode_run_time":[22],"number_of_seasons":9,"networks":[{"name":"NBC"}],
 "original_language":"en","poster_path":"/p.jpg","backdrop_path":"/b.jpg",
 "images":{"logos":[{"file_path":"/zh.png","iso_639_1":"zh","vote_average":5},{"file_path":"/en1.png","iso_639_1":"en","vote_average":3},
   {"file_path":"/en2.png","iso_639_1":"en","vote_average":5.5}],"backdrops":[]},
 "credits":{"cast":[{"id":2,"name":"Rainn Wilson","character":"Dwight","order":1},{"id":1,"name":"Steve Carell","character":"Michael","order":0}]},
 "seasons":[{"season_number":0,"name":"特别篇"},{"season_number":1,"name":"第 1 季","episode_count":6,"air_date":"2005-03-24"}]}
"""

@Test func detailsPickEnglishLogoAndFallBackToEnglishOverview() async throws {
    let session = Stub.session(host: "details.test") { request in
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Pixon/") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasSuffix(" (macOS)") == true)
        let q = request.url!.query ?? ""
        #expect(q.contains("api_key=0123456789abcdef0123456789abcdef"))
        if q.contains("language=en-US") { return (200, #"{"id":2316,"name":"The Office","overview":"A mockumentary."}"#) }
        #expect(q.contains("append_to_response=images,credits"))
        return (200, officeJSON)
    }
    let client = TMDBClient(token: "0123456789abcdef0123456789abcdef", config: config("details.test"), session: session, cacheDirectory: nil)
    let t = try await client.details(TMDBRef(type: .tv, id: 2316))
    #expect(t.title == "办公室")
    #expect(t.originalTitle == "The Office")
    #expect(t.overview == "A mockumentary.")
    #expect(t.year == 2005)
    #expect(t.logoPath == "/en2.png")
    #expect(t.cast.map(\.name) == ["Steve Carell", "Rainn Wilson"])
    #expect(t.seasons.map(\.number) == [1])
    #expect(t.runtimeMinutes == 22)
    #expect(client.imageURL(t.posterPath, size: .poster)?.absoluteString == "https://img.details.test/t/p/w500/p.jpg")
}

@Test func detailsPreferHighestResolutionBackdrop() async throws {
    let session = Stub.session(host: "high-res.test") { _ in
        (200, #"{"id":2316,"name":"办公室","overview":"简介","backdrop_path":"/default.jpg","images":{"backdrops":[{"file_path":"/hd.jpg","width":1920,"height":1080,"vote_average":9},{"file_path":"/4k.jpg","width":3840,"height":2160,"vote_average":6},{"file_path":"/unknown.jpg","vote_average":10}]}}"#)
    }
    let client = TMDBClient(token: "0123456789abcdef0123456789abcdef", config: config("high-res.test"), session: session, cacheDirectory: nil)
    let title = try await client.details(TMDBRef(type: .tv, id: 2316))
    #expect(title.backdropPath == "/4k.jpg")
    #expect(client.imageURL(title.backdropPath, size: .original)?.path == "/t/p/original/4k.jpg")
}

@Test func detailsPreferRecommendedBackdropWhenAlreadyHighResolution() async throws {
    let session = Stub.session(host: "recommended-backdrop.test") { _ in
        (200, #"{"id":1668,"name":"老友记","backdrop_path":"/recommended.jpg","images":{"backdrops":[{"file_path":"/recommended.jpg","width":2560,"height":1440,"vote_average":6},{"file_path":"/larger.jpg","width":3840,"height":2160,"vote_average":5}]}}"#)
    }
    let client = TMDBClient(token: "0123456789abcdef0123456789abcdef", config: config("recommended-backdrop.test"), session: session, cacheDirectory: nil)
    let title = try await client.details(TMDBRef(type: .tv, id: 1668))
    #expect(title.backdropPath == "/recommended.jpg")
    #expect(client.imageURL(title.backdropPath, size: .original)?.path == "/t/p/original/recommended.jpg")
}

@Test func detailsReplaceSmallRecommendedBackdropWithHigherResolutionImage() async throws {
    let session = Stub.session(host: "small-backdrop.test") { _ in
        (200, #"{"id":1668,"name":"老友记","backdrop_path":"/small.jpg","images":{"backdrops":[{"file_path":"/small.jpg","width":1280,"height":720,"vote_average":9},{"file_path":"/4k.jpg","width":3840,"height":2160,"vote_average":6}]}}"#)
    }
    let client = TMDBClient(token: "0123456789abcdef0123456789abcdef", config: config("small-backdrop.test"), session: session, cacheDirectory: nil)
    let title = try await client.details(TMDBRef(type: .tv, id: 1668))
    #expect(title.backdropPath == "/4k.jpg")
}

@Test func bearerTokenGoesInHeaderAndResultsAreCached() async throws {
    let token = String(repeating: "x", count: 120)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = Stub.session(host: "bearer.test") { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.url!.query?.contains("api_key") == false)
        return (200, #"{"results":[{"id":1668,"name":"老友记","first_air_date":"1994-09-22","popularity":200},{"id":9,"name":"Friends (2009)","first_air_date":"2009-01-01","popularity":900}]}"#)
    }
    let client = TMDBClient(token: token, config: config("bearer.test"), session: session, cacheDirectory: dir)
    let ref = try await client.resolve(.tv, title: "Friends", year: 1994)
    #expect(ref == TMDBRef(type: .tv, id: 1668))
    _ = try await client.resolve(.tv, title: "Friends", year: 1994)
    // 换一个客户端实例，从磁盘缓存读取，不再发请求。
    let second = TMDBClient(token: token, config: config("bearer.test"), session: session, cacheDirectory: dir)
    _ = try await second.search(.tv, query: "Friends", year: 1994)
    #expect(Stub.calls.withLock { $0["bearer.test"] } == 1)
}

@Test func corruptedDiskCacheIsRefetchedImmediately() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = "search/tv?first_air_date_year=1994&language=zh-CN&query=Friends"
    try Data("not-json".utf8).write(to: dir.appendingPathComponent(TMDBClient.hash(key) + ".json"))
    let session = Stub.session(host: "corrupt.test") { _ in
        (200, #"{"results":[{"id":1668,"name":"老友记","first_air_date":"1994-09-22"}]}"#)
    }
    let client = TMDBClient(token: "0123456789abcdef0123456789abcdef",
                            config: config("corrupt.test"), session: session, cacheDirectory: dir)
    let hits = try await client.search(.tv, query: "Friends", year: 1994)
    #expect(hits.first?.ref.id == 1668)
    #expect(Stub.calls.withLock { $0["corrupt.test"] } == 1)
}

@Test func errorsAreReadable() async {
    let session = Stub.session(host: "deny.test") { _ in (401, "{}") }
    await #expect(throws: TMDBError.unauthorized) {
        try await TMDBClient(token: "bad", config: config("deny.test"), session: session, cacheDirectory: nil)
            .details(TMDBRef(type: .movie, id: 1))
    }
    await #expect(throws: TMDBError.missingCredential) {
        try await TMDBClient(token: " ", config: config("deny.test"), session: session, cacheDirectory: nil)
            .details(TMDBRef(type: .movie, id: 1))
    }
}
