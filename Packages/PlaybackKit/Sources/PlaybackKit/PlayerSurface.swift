import AppKit
import QuartzCore
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
    private let initialRenderSize: CGSize?
    private let initialContentsScale: CGFloat?
    var renderSize: CGSize { surface.renderSize }
    var presentationSize: CGSize = .zero {
        didSet { needsLayout = presentationSize != oldValue }
    }

    init(surface: MPVSurfaceView, renderSize: CGSize? = nil, contentsScale: CGFloat? = nil) {
        self.surface = surface
        initialRenderSize = renderSize
        initialContentsScale = contentsScale
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
            let configuration = initialRenderSize.map {
                ($0, initialContentsScale ?? surface.metalLayer.contentsScale)
            } ?? Self.screenRenderConfiguration()
            surface.renderSize = configuration.0
            surface.metalLayer.contentsScale = configuration.1
            surface.frame = NSRect(origin: .zero, size: surface.renderSize)
        }
        guard renderSize.width > 0, renderSize.height > 0 else { return }
        let videoSize = presentationSize.width > 0 && presentationSize.height > 0 ? presentationSize : renderSize
        let renderedVideo = videoSize.aspectFit(in: renderSize)
        let targetVideo = videoSize.aspectFit(in: bounds.size)
        let scale = min(targetVideo.width / renderedVideo.width, targetVideo.height / renderedVideo.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        let scaledSurface = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
        surface.layer?.position = CGPoint(x: bounds.midX - scaledSurface.width / 2,
                                          y: bounds.midY - scaledSurface.height / 2)
        CATransaction.commit()
    }

    private static func screenRenderConfiguration() -> (CGSize, CGFloat) {
        let screen = NSScreen.screens.max { lhs, rhs in
            let lhsPixels = lhs.frame.width * lhs.frame.height * lhs.backingScaleFactor * lhs.backingScaleFactor
            let rhsPixels = rhs.frame.width * rhs.frame.height * rhs.backingScaleFactor * rhs.backingScaleFactor
            return lhsPixels < rhsPixels
        } ?? NSScreen.main
        return (screen?.frame.size ?? CGSize(width: 1920, height: 1080),
                screen?.backingScaleFactor ?? 2)
    }
}

private extension CGSize {
    func aspectFit(in container: CGSize) -> CGSize {
        guard width > 0, height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / width, container.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}
