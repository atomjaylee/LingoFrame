import Foundation
import Testing
@testable import PlaybackNative

private let totalBytes = 3 * 1024 * 1024 + 123
private let originURL = URL(string: "https://origin.test/Videos/1/stream.iso")!
private let edgeURL = URL(string: "https://edge.test/file")!

private func byte(at offset: Int) -> UInt8 { UInt8(offset % 251) }

/// 模拟“源站 302 到 CDN”的链路，并统计每一跳的请求数。
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var originRequests = 0
    nonisolated(unsafe) static var edgeRequests = 0
    nonisolated(unsafe) static var edgeFailuresLeft = 0
    nonisolated(unsafe) static var ignoresRange = false
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        originRequests = 0
        edgeRequests = 0
        edgeFailuresLeft = 0
        ignoresRange = false
    }

    static func counts() -> (origin: Int, edge: Int) {
        lock.lock(); defer { lock.unlock() }
        return (originRequests, edgeRequests)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "origin.test" {
            Self.lock.lock(); Self.originRequests += 1; Self.lock.unlock()
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": edgeURL.absoluteString])!
            var next = request
            next.url = edgeURL
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        Self.lock.lock()
        Self.edgeRequests += 1
        let shouldFail = Self.edgeFailuresLeft > 0
        if shouldFail { Self.edgeFailuresLeft -= 1 }
        let ignoresRange = Self.ignoresRange
        Self.lock.unlock()
        if shouldFail { return respond(url, 403, [:], Data()) }
        if ignoresRange { return respond(url, 200, [:], Data(repeating: 0, count: 16)) }
        let header = request.value(forHTTPHeaderField: "Range")!
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").map { Int($0)! }
        let end = min(bounds[1], totalBytes - 1)
        let body = Data((bounds[0]...end).map(byte(at:)))
        respond(url, 206, ["Content-Range": "bytes \(bounds[0])-\(end)/\(totalBytes)"], body)
    }

    private func respond(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeReader() throws -> DiscRangeReader {
    let config = RemoteDiscSource.defaultConfiguration()
    config.protocolClasses = [StubProtocol.self]
    return DiscRangeReader(source: try RemoteDiscSource(url: originURL, headers: [:], configuration: config))
}

private func read(_ reader: DiscRangeReader, at offset: Int64, count: Int) -> [UInt8] {
    _ = reader.seek(offset: offset, whence: SEEK_SET)
    var out = [UInt8](repeating: 0, count: count)
    var filled = 0
    out.withUnsafeMutableBufferPointer { buffer in
        while filled < count {
            let n = reader.read(buffer.baseAddress! + filled, size: Int32(count - filled))
            if n <= 0 { break }
            filled += Int(n)
        }
    }
    return Array(out.prefix(filled))
}

@Suite(.serialized)
struct DiscRangeReaderTests {
    @Test func scatteredReadsResolveRedirectOnce() throws {
        StubProtocol.reset()
        let reader = try makeReader()
        defer { reader.close() }
        for offset in [0, 900_000, 32_768, 2_000_000, 524_288, 3_000_000] as [Int64] {
            #expect(read(reader, at: offset, count: 2048).count == 2048)
        }
        #expect(StubProtocol.counts().origin == 1)
    }

    @Test func readsAcrossBlocksAndStopsAtEnd() throws {
        StubProtocol.reset()
        let reader = try makeReader()
        defer { reader.close() }
        let start = Int64(RemoteDiscSource.blockSize - 100)
        let middle = read(reader, at: start, count: 1000)
        #expect(middle == (Int(start)..<Int(start) + 1000).map(byte(at:)))
        let tail = read(reader, at: Int64(totalBytes - 10), count: 100)
        #expect(tail == ((totalBytes - 10)..<totalBytes).map(byte(at:)))
        #expect(reader.seek(offset: 0, whence: 65536) == Int64(totalBytes))
    }

    @Test func expiredEdgeLinkIsResolvedAgain() throws {
        StubProtocol.reset()
        let reader = try makeReader()
        defer { reader.close() }
        StubProtocol.edgeFailuresLeft = 1
        #expect(read(reader, at: 1_000_000, count: 512).count == 512)
        #expect(StubProtocol.counts().origin == 2)
    }

    @Test func independentReaderSharesCache() throws {
        StubProtocol.reset()
        let reader = try makeReader()
        #expect(read(reader, at: 700_000, count: 4096).count == 4096)
        let before = StubProtocol.counts()
        let other = try #require(reader.makeIndependentReader() as? DiscRangeReader)
        #expect(read(other, at: 700_000, count: 4096).count == 4096)
        #expect(StubProtocol.counts().edge == before.edge)
        reader.close()
        // 第一个读取器关闭后，另一个仍能继续读。
        #expect(read(other, at: 2_500_000, count: 512).count == 512)
        other.close()
    }

    @Test func cancelDoesNotBreakLaterReads() throws {
        StubProtocol.reset()
        let reader = try makeReader()
        defer { reader.close() }
        reader.cancel()
        #expect(read(reader, at: 1_500_000, count: 512).count == 512)
    }

    @Test func refusesOriginWithoutRangeSupport() {
        StubProtocol.reset()
        StubProtocol.ignoresRange = true
        #expect(throws: DiscRangeError.self) { _ = try makeReader() }
    }

    @Test func prewarmStoreHandsSourceOverOnce() throws {
        StubProtocol.reset()
        let config = RemoteDiscSource.defaultConfiguration()
        config.protocolClasses = [StubProtocol.self]
        let source = try RemoteDiscSource(url: originURL, headers: [:], configuration: config)
        let store = DiscPrewarmStore()
        store.store(source, for: originURL)
        #expect(!store.isReady(originURL))
        store.markReady(source)
        #expect(store.isReady(originURL))
        #expect(store.take(edgeURL) == nil)
        let taken = try #require(store.take(originURL))
        #expect(store.take(originURL) == nil)
        #expect(!store.isReady(originURL))
        DiscRangeReader(source: taken).close()
    }

    @Test func parsesContentRange() {
        #expect(RemoteDiscSource.totalSize(fromContentRange: "bytes 0-0/65068924928") == 65_068_924_928)
        #expect(RemoteDiscSource.totalSize(fromContentRange: "bytes 0-0/*") == nil)
        #expect(RemoteDiscSource.startOffset(fromContentRange: "bytes 100-200/300") == 100)
        #expect(DiscRangeReader.handles(URL(string: "https://a/stream.ISO?x=1")!))
        #expect(!DiscRangeReader.handles(URL(string: "https://a/stream.mkv")!))
    }
}
