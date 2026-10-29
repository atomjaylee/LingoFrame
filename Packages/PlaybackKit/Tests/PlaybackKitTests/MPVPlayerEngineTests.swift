import AppKit
import QuartzCore
import Testing
@testable import PlaybackKit

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytes = Data()
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var failuresRemaining = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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

private func makeMultiTrackMKV() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elenglish-tracks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let subtitle = directory.appendingPathComponent("subtitle.srt")
    try "1\n00:00:00,000 --> 00:00:02,000\nHello\n".write(to: subtitle, atomically: true, encoding: .utf8)
    let url = directory.appendingPathComponent("tracks.mkv")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000", "-i", subtitle.path,
        "-t", "3", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s",
        "-c:v", "h264_videotoolbox", "-b:v", "1M", "-c:a", "aac", "-c:s", "srt",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=zho",
        "-metadata:s:s:0", "language=eng", url.path,
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
    @Test func cacheLimitCanBeConfigured() {
        let old = MediaCachePolicy.limitGB
        defer { MediaCachePolicy.limitGB = old }
        MediaCachePolicy.limitGB = 50
        #expect(MediaCachePolicy.limitGB == 50)
        #expect(MediaCachePolicy.limitBytes == 50 * 1024 * 1024 * 1024)
    }

    @Test func surfaceUsesMetalLayer() {
        let engine = MPVPlayerEngine()
        #expect(engine.surface.wantsLayer)
        #expect(engine.surface.layer === engine.surface.metalLayer)
        #expect(engine.nativeSubtitlesVisible)
        engine.setNativeSubtitlesVisible(false)
        #expect(!engine.nativeSubtitlesVisible)
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
        #expect(engine.bufferedTime >= engine.currentTime)

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
    func replacingFileIgnoresStoppedEndEvent() async throws {
        let first = try makeTestMKV(duration: 3)
        let second = try makeTestMKV(duration: 4)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: first, autoplay: false)
        try await waitUntil { engine.state == .paused }
        engine.load(url: second, autoplay: false)
        try await waitUntil { engine.state == .paused && abs(engine.duration - 4) < 0.3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state == .paused)
        engine.stop()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func exposesAndSelectsAudioAndSubtitleTracks() async throws {
        let source = try makeMultiTrackMKV()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: source, autoplay: false)
        try await waitUntil { engine.state == .paused && engine.audioOptions.count == 2 && engine.subtitleOptions.count == 1 }
        let secondAudio = engine.audioOptions[1].id
        engine.selectAudio(secondAudio)
        #expect(engine.selectedAudioID == secondAudio)
        let subtitle = engine.subtitleOptions[0].id
        engine.selectSubtitle(subtitle)
        #expect(engine.selectedSubtitleID == subtitle)
        engine.selectSubtitle(nil)
        #expect(engine.selectedSubtitleID == nil)
        engine.stop()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func replayAfterEndRestartsPlayback() async throws {
        let source = try makeTestMKV(duration: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: source)
        try await waitUntil { engine.state == .ended }
        engine.play()
        try await waitUntil { engine.state == .playing && engine.currentTime < 0.8 }
        engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.state == .idle)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(1)))
    func cachedRemoteMKVUsesCustomByteStream() async throws {
        let source = try makeTestMKV(duration: 3)
        defer { try? FileManager.default.removeItem(at: source) }
        RangeProtocol.bytes = try Data(contentsOf: source)
        RangeProtocol.requestCount = 0
        RangeProtocol.failuresRemaining = 1
        MediaCacheTesting.protocolClasses = [RangeProtocol.self]
        defer { MediaCacheTesting.protocolClasses = nil }

        let remote = URL(string: "https://cache.test/video.mkv")!
        let descriptor = CachedMediaSource(cacheKey: UUID().uuidString, url: remote,
                                           size: Int64(RangeProtocol.bytes.count), fileExtension: "mkv")
        let engine = MPVPlayerEngine(headless: true)
        engine.load(url: remote, autoplay: false, cachedSource: descriptor)
        try await waitUntil { engine.state == .paused && engine.duration > 0 }
        #expect(abs(engine.duration - 3) < 0.3)
        await engine.seek(to: 1.8, exact: true)
        #expect(abs(engine.currentTime - 1.8) < 0.4)
        #expect(RangeProtocol.requestCount <= 4)
        engine.stop()
        engine.load(url: remote, autoplay: false, cachedSource: descriptor)
        try await waitUntil { engine.state == .paused && engine.duration > 0 }
        #expect(RangeProtocol.requestCount <= 5)
        engine.stop()
    }
}
