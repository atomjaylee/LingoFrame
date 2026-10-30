import Foundation
import LearningCore
import Testing
@testable import PlaybackKit

private let seekFFmpeg = "/usr/local/bin/ffmpeg"

private final class SeekRangeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytes = Data()
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "seek.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let total = Self.bytes.count
        let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
        let start = Int(range.dropFirst(6).split(separator: "-").first ?? "0") ?? 0
        let data = Self.bytes.subdata(in: min(start, total)..<total)
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Length": "\(data.count)", "Content-Range": "bytes \(start)-\(total - 1)/\(total)",
            "Accept-Ranges": "bytes",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSeekFixture(duration: Int = 18) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cached-seek-\(UUID().uuidString).mkv")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: seekFFmpeg)
    // 六秒一个关键帧，覆盖快速跳转落点与点击位置相差超过原来 0.8 秒容差的情况。
    process.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12",
                         "-t", "\(duration)", "-c:v", "mpeg4", "-g", "72", "-q:v", "4", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return url
}

@MainActor
private func waitForSeekFixture(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
extension MPVPlayerEngineTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: seekFFmpeg)), .timeLimit(.minutes(1)))
    func progressSeekUsesNearbyKeyframeAndFinishesPromptly() async throws {
        let source = try makeSeekFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let engine = MPVPlayerEngine(headless: true)
        defer { engine.stop() }
        engine.load(url: source, autoplay: false)
        try await waitForSeekFixture { engine.state == .paused && engine.bufferedTime > 15 }

        for target in [8.3, 14.3, 2.3] {
            let began = ContinuousClock.now
            await engine.seek(to: target)
            #expect(began.duration(to: .now) < .seconds(1))
            print("缓存内快速跳转 \(target) 秒：\(began.duration(to: .now))")
            #expect(abs(engine.currentTime - (target - 2.3)) < 0.2)
            #expect(engine.state == .paused)
        }
        engine.play()
        try await waitForSeekFixture { engine.currentTime > 0.2 }
        #expect(engine.state == .playing)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: seekFFmpeg)), .timeLimit(.minutes(1)))
    func subtitleSeekStillLandsAtExactTime() async throws {
        let source = try makeSeekFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let engine = MPVPlayerEngine(headless: true)
        defer { engine.stop() }
        engine.load(url: source, autoplay: false)
        try await waitForSeekFixture { engine.state == .paused && engine.bufferedTime > 15 }

        await engine.seek(to: 8.3, exact: true)
        #expect(abs(engine.currentTime - 8.3) < 0.2)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: seekFFmpeg)), .timeLimit(.minutes(1)))
    func cachedRangesPreserveGapsAndSeekingReusesDownloadedBytes() async throws {
        let source = try makeSeekFixture(duration: 150)
        defer { try? FileManager.default.removeItem(at: source) }
        SeekRangeProtocol.bytes = try Data(contentsOf: source)
        SeekRangeProtocol.requestCount = 0
        MediaCacheTesting.protocolClasses = [SeekRangeProtocol.self]
        defer { MediaCacheTesting.protocolClasses = nil }

        let remote = URL(string: "https://seek.test/video.mkv")!
        let descriptor = CachedMediaSource(cacheKey: UUID().uuidString, url: remote,
                                           size: Int64(SeekRangeProtocol.bytes.count), fileExtension: "mkv")
        let engine = MPVPlayerEngine(headless: true)
        defer { engine.stop() }
        engine.load(url: remote, autoplay: false, cachedSource: descriptor)
        try await waitForSeekFixture { engine.state == .paused && engine.bufferedTime > 50 }

        let requestsBeforeSeek = SeekRangeProtocol.requestCount
        engine.play()
        let began = ContinuousClock.now
        await engine.seek(to: 14.3)
        let resumedAt = engine.currentTime
        try await waitForSeekFixture { engine.currentTime > resumedAt + 0.2 }
        #expect(began.duration(to: .now) < .seconds(1))
        #expect(engine.state == .playing)
        #expect(SeekRangeProtocol.requestCount == requestsBeforeSeek)

        await engine.seek(to: 110, exact: true)
        try await waitForSeekFixture { engine.bufferedRanges.contains { $0.contains(MediaTime(seconds: 120)) } }
        #expect(engine.bufferedRanges.contains { $0.contains(MediaTime(seconds: 12)) })
        #expect(!engine.bufferedRanges.contains { $0.contains(MediaTime(seconds: 90)) })
        #expect(SeekRangeProtocol.requestCount == requestsBeforeSeek)

        engine.stop()
        #expect(engine.bufferedRanges.isEmpty)
        #expect(engine.bufferedTime == 0)
    }
}
