import AetherEngine
import PlaybackCore
import SwiftUI

public struct PlayerSurface: View {
    private let engine: NativePlayerEngine
    @Environment(\.displayScale) private var displayScale

    public init(engine: NativePlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        GeometryReader { proxy in
            AetherPlayerSurface(engine: engine.backend)
                .background(Color.black)
                .onChange(of: proxy.size, initial: true) { _, size in updateSubtitleSize(size) }
                .onChange(of: engine.presentationSize) { _, _ in updateSubtitleSize(proxy.size) }
                .onChange(of: displayScale) { _, _ in updateSubtitleSize(proxy.size) }
        }
    }

    private func updateSubtitleSize(_ size: CGSize) {
        let video = engine.presentationSize
        guard video.width > 0, video.height > 0 else { return }
        let scale = min(size.width / video.width, size.height / video.height) * displayScale
        engine.setSubtitleRenderSize(CGSize(width: video.width * scale, height: video.height * scale))
    }
}
