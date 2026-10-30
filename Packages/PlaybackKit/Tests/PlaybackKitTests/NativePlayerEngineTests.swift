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
