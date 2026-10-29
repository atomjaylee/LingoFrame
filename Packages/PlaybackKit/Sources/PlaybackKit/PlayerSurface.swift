import AppKit
import SwiftUI

/// libmpv 视频画面。渲染视图由播放内核长期持有，详情页预热后切进播放窗口时不重建解码链路。
public struct PlayerSurface: NSViewRepresentable {
    let engine: MPVPlayerEngine

    public init(engine: MPVPlayerEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> MPVSurfaceView {
        engine.surface
    }

    public func updateNSView(_ view: MPVSurfaceView, context: Context) {}
}
