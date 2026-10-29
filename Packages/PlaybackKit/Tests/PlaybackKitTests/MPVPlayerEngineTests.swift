import AppKit
import QuartzCore
import Testing
@testable import PlaybackKit

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytes = Data()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let total = Self.bytes.count
        let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-\(max(total - 1, 0))"
        let values = range.dropFirst(6).split(separator: "-", maxSplits: 1)
        let start = Int(values.first ?? "0") ?? 0
        let end = min(Int(values.count > 1 ? values[1] : "") ?? (total - 1), total - 1)
        let data = start <= end && start < total ? Self.bytes.subdata(in: start..<(end + 1)) : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Length": "\(data.count)", "Content-Range": "bytes \(start)-\(end)/\(total)",
            "Accept-Ranges": "bytes",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let ffmpeg = "/usr/local/bin/ffmpeg"

private func makeTestMKV(duration: Int = 6) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("elenglish-mpv-\(UUID().uuidString).mkv")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "\(duration)", "-c:v", "h264_videotoolbox", "-b:v", "1M", "-g", "12",
        "-c:a", "aac", "-shortest", url.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return url
}

@MainActor
private func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
@Suite(.serialized)
struct MPVPlayerEngineTests {
    @Test func surfaceUsesMetalLayer() {
        let engine = MPVPlayerEngine()
        #expect(engine.surface.wantsLayer)
        #expect(engine.surface.layer === engine.surface.metalLayer)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func directlyLoadsMKVAndSeeksWithoutRemuxing() async throws {
        let source = try makeTestMKV()
        defer { try? FileManager.default.removeItem(at: source) }

        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: source, autoplay: false)
        try await waitUntil { engine.state == .paused && engine.duration > 0 }
        #expect(abs(engine.duration - 6) < 0.3)
        #expect(engine.presentationSize == CGSize(width: 640, height: 360))

        await engine.seek(to: 3.2, exact: true)
        #expect(abs(engine.currentTime - 3.2) < 0.4)
        engine.stop()
        #expect(engine.state == .idle)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func preloadedFileActivatesWithoutReload() async throws {
        let source = try makeTestMKV(duration: 3)
        defer { try? FileManager.default.removeItem(at: source) }

        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: source, autoplay: false, preload: true)
        try await waitUntil { engine.state == .paused }
        #expect(engine.activatePreloaded(url: source, autoplay: true))
        try await waitUntil { engine.state == .playing }
        engine.stop()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func cachedRemoteMKVUsesCustomByteStream() async throws {
        let source = try makeTestMKV(duration: 3)
        defer { try? FileManager.default.removeItem(at: source) }
        RangeProtocol.bytes = try Data(contentsOf: source)
        MediaCacheTesting.protocolClasses = [RangeProtocol.self]
        defer { MediaCacheTesting.protocolClasses = nil }

        let remote = URL(string: "https://cache.test/video.mkv")!
        let descriptor = CachedMediaSource(cacheKey: UUID().uuidString, url: remote,
                                           size: Int64(RangeProtocol.bytes.count), fileExtension: "mkv")
        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: remote, autoplay: false, cachedSource: descriptor)
        try await waitUntil { engine.state == .paused && engine.duration > 0 }
        #expect(abs(engine.duration - 3) < 0.3)
        engine.stop()
    }
}
