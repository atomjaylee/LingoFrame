import AppKit
import SwiftUI
import Testing
@testable import PlaybackKit

private let ffmpeg = "/usr/local/bin/ffmpeg"

private func makeTestMKV(duration: Int = 4, videoCodec: String = "h264_videotoolbox") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("elenglish-native-\(UUID().uuidString).mkv")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    var arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "\(duration)", "-c:v", videoCodec, "-b:v", "1M", "-g", "12",
    ]
    if videoCodec == "hevc_videotoolbox" { arguments += ["-tag:v", "hvc1"] }
    arguments += ["-c:a", "aac", "-shortest", url.path]
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return url
}

@MainActor
private func waitUntil(timeout: Double = 20, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
@Suite(.serialized)
struct NativePlayerEngineTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(2)))
    func styledASSKeepsAuthoredAppearanceAndPlainLearningText() async throws {
        let video = try makeTestMKV(duration: 8)
        let subtitle = video.deletingPathExtension().appendingPathExtension("ass")
        let muxed = video.deletingPathExtension().appendingPathExtension("styled.mkv")
        defer {
            for url in [video, subtitle, muxed] { try? FileManager.default.removeItem(at: url) }
        }
        try (ASSSubtitleRendererTests.header + "\nDialogue: 0,0:00:00.20,0:00:03.50,Default,,0,0,0,,{\\pos(80,60)}Styled dialogue\nDialogue: 1,0:00:00.20,0:00:03.50,Default,,0,0,0,,{\\pos(320,180)}Second line\n")
            .write(to: subtitle, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-i", video.path, "-i", subtitle.path,
                             "-map", "0", "-map", "1", "-c", "copy", "-metadata:s:s:0", "language=eng",
                             "-disposition:s:0", "default", muxed.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let engine = try NativePlayerEngine()
        defer { engine.stop() }
        engine.setBitmapSubtitleRecognitionEnabled(true, language: "eng")
        try await engine.load(url: muxed)
        try await waitUntil {
            !engine.currentSubtitleImages.isEmpty && engine.recognizedSubtitleCues.count >= 2
        }
        #expect(engine.currentSubtitleText == nil)
        #expect(engine.recognizedSubtitleCues.contains { $0.text == "Styled dialogue" })
        #expect(engine.recognizedSubtitleCues.contains { $0.text == "Second line" })
        let image = try #require(engine.currentSubtitleImages.first)
        #expect(image.position.minY < 0.3)
        #expect(image.position.minX < 0.2)
        #expect(engine.hasStyledSubtitleTrack)
        engine.usesOriginalSubtitleStyle = false
        #expect(engine.currentSubtitleImages.isEmpty)
        #expect(engine.currentSubtitleText?.contains("Styled dialogue") == true)
        #expect(engine.currentSubtitleText?.contains("Second line") == true)
        engine.usesOriginalSubtitleStyle = true
        #expect(engine.currentSubtitleText == nil)
        #expect(!engine.currentSubtitleImages.isEmpty)
        engine.selectSubtitle(nil)
        #expect(engine.currentSubtitleImages.isEmpty)
        #expect(engine.currentSubtitleText == nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(2)))
    func learningSubtitleTrackSurvivesVideoTrackChangesAndPause() async throws {
        let video = try makeTestMKV(duration: 8)
        let english = video.deletingPathExtension().appendingPathExtension("en.srt")
        let chinese = video.deletingPathExtension().appendingPathExtension("zh.srt")
        let muxed = video.deletingPathExtension().appendingPathExtension("dual.mkv")
        defer {
            for url in [video, english, chinese, muxed] { try? FileManager.default.removeItem(at: url) }
        }
        try "1\n00:00:00,200 --> 00:00:07,500\nHello, welcome back.\n".write(to: english, atomically: true, encoding: .utf8)
        try "1\n00:00:00,200 --> 00:00:07,500\n你好，欢迎回来。\n".write(to: chinese, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-i", video.path, "-i", english.path, "-i", chinese.path,
                             "-map", "0", "-map", "1", "-map", "2", "-c", "copy",
                             "-metadata:s:s:0", "language=eng", "-disposition:s:0", "default",
                             "-metadata:s:s:1", "language=zho", muxed.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let engine = try NativePlayerEngine()
        defer { engine.stop() }
        try await engine.load(url: muxed, startAt: 1, autoplay: false)
        try await waitUntil { engine.state == .paused && engine.subtitleOptions.count == 2 }
        let englishID = try #require(engine.subtitleOptions.first { $0.language == "eng" }?.id)
        let chineseID = try #require(engine.subtitleOptions.first { $0.language == "zho" }?.id)
        engine.setBitmapSubtitleRecognitionEnabled(true, language: "eng", trackID: englishID)
        engine.selectSubtitle(chineseID)
        try await waitUntil {
            engine.currentSubtitleText?.contains("你好") == true && !engine.recognizedSubtitleCues.isEmpty
        }
        #expect(engine.recognizedSubtitleCues.allSatisfy { $0.text == "Hello, welcome back." })
        engine.setLearningCompanionSubtitle(chineseID, language: "zho")
        try await waitUntil { !engine.recognizedCompanionSubtitleCues.isEmpty }
        #expect(engine.recognizedCompanionSubtitleCues.allSatisfy { $0.text == "你好，欢迎回来。" })
        #expect(engine.recognizedSubtitleCues.allSatisfy { $0.text == "Hello, welcome back." })
        #expect(engine.selectedSubtitleID == chineseID)
        let cached = engine.recognizedSubtitleCues
        let cachedChinese = engine.recognizedCompanionSubtitleCues
        engine.pauseBitmapSubtitleRecognition()
        #expect(engine.recognizedSubtitleCues == cached)
        #expect(engine.recognizedCompanionSubtitleCues == cachedChinese)
        #expect(!engine.isRecognizingBitmapSubtitles)
        #expect(engine.selectedSubtitleID == chineseID)
        engine.selectSubtitle(nil)
        #expect(engine.currentSubtitleText == nil)
        #expect(engine.recognizedSubtitleCues == cached)
        #expect(engine.recognizedCompanionSubtitleCues == cachedChinese)
        engine.setBitmapSubtitleRecognitionEnabled(true, language: "eng", trackID: englishID)
        #expect(engine.selectedSubtitleID == nil)
        #expect(engine.recognizedSubtitleCues.contains { $0.text == "Hello, welcome back." })
        #expect(engine.recognizedCompanionSubtitleCues.contains { $0.text == "你好，欢迎回来。" })
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(2)))
    func subtitleRecognitionConfiguredBeforeLoadWorksWithoutSwitchingTracks() async throws {
        let video = try makeTestMKV()
        let subtitle = video.deletingPathExtension().appendingPathExtension("srt")
        let muxed = video.deletingPathExtension().appendingPathExtension("subtitled.mkv")
        defer {
            for url in [video, subtitle, muxed] { try? FileManager.default.removeItem(at: url) }
        }
        try "1\n00:00:00,200 --> 00:00:03,500\nHello, welcome back.\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-i", video.path, "-i", subtitle.path,
                             "-map", "0", "-map", "1", "-c", "copy",
                             "-metadata:s:s:0", "language=eng", "-disposition:s:0", "default", muxed.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let engine = try NativePlayerEngine()
        defer { engine.stop() }
        engine.setBitmapSubtitleRecognitionEnabled(true, language: "eng")
        try await engine.load(url: muxed)
        try await waitUntil(timeout: 8) { !engine.recognizedSubtitleCues.isEmpty }
        #expect(engine.recognizedSubtitleCues.first?.text == "Hello, welcome back.")
    }

    @Test func bitmapSubtitleKeepsDiscCanvasPosition() throws {
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
                                bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try #require(context?.makeImage())
        let subtitle = NativeSubtitleImage(id: 1, cgImage: image,
                                           position: CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1),
                                           canvasSize: CGSize(width: 1_920, height: 1_080))
        let frame = subtitle.frame(in: CGRect(x: 100, y: 50, width: 960, height: 540))
        #expect(frame == CGRect(x: 340, y: 482, width: 480, height: 54))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ffmpeg)), .timeLimit(.minutes(2)))
    func nativeSurfaceResizesAndSwitchesCodecsWithoutRebuildingTheWindow() async throws {
        let h264 = try makeTestMKV()
        let hevc = try makeTestMKV(duration: 3, videoCodec: "hevc_videotoolbox")
        defer {
            try? FileManager.default.removeItem(at: h264)
            try? FileManager.default.removeItem(at: hevc)
        }

        let engine = try NativePlayerEngine()
        let host = NSHostingView(rootView: PlayerSurface(engine: engine))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { engine.stop(); window.close() }

        try await engine.load(url: h264, autoplay: false)
        try await waitUntil {
            engine.state == .paused && engine.presentationSize.width > 0
                && engine.diagnostics().startupMilliseconds != nil
        }
        #expect(engine.presentationSize == CGSize(width: 640, height: 360))
        #expect(engine.diagnostics().startupStage == "首帧已显示")
        #expect(engine.diagnostics().startupMilliseconds ?? 0 > 0)
        let surface = host.subviews.first

        for size in [CGSize(width: 1_280, height: 720), CGSize(width: 800, height: 450),
                     CGSize(width: 1_920, height: 1_080)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            #expect(host.subviews.first === surface)
            #expect(engine.state == .paused)
        }

        await engine.seek(to: 1.5, exact: true)
        #expect(abs(engine.currentTime - 1.5) < 0.5)
        #expect(!engine.isSeeking)
        #expect(!engine.isBuffering)
        #expect(!engine.isWaitingForMedia)

        try await engine.load(url: hevc, autoplay: false)
        try await waitUntil { engine.state == .paused && engine.videoDescription?.contains("HEVC") == true }
        #expect(host.subviews.first === surface)
        #expect(engine.diagnostics().playbackType?.contains("Apple") == true)
    }
}
