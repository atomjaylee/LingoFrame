import AppKit
import SwiftUI

/// libmpv 视频画面。渲染视图由播放内核长期持有，详情页预热后切进播放窗口时不重建解码链路。
public struct PlayerSurface: NSViewRepresentable {
    let engine: MPVPlayerEngine

    public init(engine: MPVPlayerEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> NSView {
        let view = MPVSurfaceHostView(surface: engine.surface)
        view.presentationSize = engine.presentationSize
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? MPVSurfaceHostView else { return }
        view.presentationSize = engine.presentationSize
    }
}

/// 窗口缩放时只缩放已经渲染好的 Metal 画面，不改视频输出，避免拖动时闪烁或部分片源黑屏。
@MainActor
final class MPVSurfaceHostView: NSView {
    let surface: MPVSurfaceView
    var renderSize: CGSize { surface.renderSize }
    var presentationSize: CGSize = .zero {
        didSet { needsLayout = presentationSize != oldValue }
    }

    init(surface: MPVSurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if surface.renderSize == .zero {
            surface.renderSize = bounds.size
            surface.frame = NSRect(origin: .zero, size: surface.renderSize)
        }
        guard renderSize.width > 0, renderSize.height > 0 else { return }
        let videoSize = presentationSize.width > 0 && presentationSize.height > 0 ? presentationSize : renderSize
        let renderedVideo = videoSize.aspectFit(in: renderSize)
        let targetVideo = videoSize.aspectFit(in: bounds.size)
        let scale = min(targetVideo.width / renderedVideo.width, targetVideo.height / renderedVideo.height)
        surface.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        let scaledSurface = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
        surface.layer?.position = CGPoint(x: bounds.midX - scaledSurface.width / 2,
                                          y: bounds.midY - scaledSurface.height / 2)
    }
}

private extension CGSize {
    func aspectFit(in container: CGSize) -> CGSize {
        guard width > 0, height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / width, container.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}
