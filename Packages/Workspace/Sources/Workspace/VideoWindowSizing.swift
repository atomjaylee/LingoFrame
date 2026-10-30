import CoreGraphics

/// 视频播放窗口的初始尺寸：优先一源像素对应一屏幕像素，放不下时再等比例缩小。
public enum VideoWindowSizing {
    public static func contentSize(for video: CGSize, backingScale: CGFloat,
                                   maximum: CGSize, minimumWidth: CGFloat = 720) -> CGSize {
        guard video.width > 0, video.height > 0, maximum.width > 0, maximum.height > 0 else { return .zero }
        let density = max(backingScale, 1)
        let native = CGSize(width: video.width / density, height: video.height / density)
        let downscale = min(1, maximum.width / native.width, maximum.height / native.height)
        var target = CGSize(width: native.width * downscale, height: native.height * downscale)

        let aspect = video.width / video.height
        let safeMinimumWidth = min(minimumWidth, maximum.width, maximum.height * aspect)
        if target.width < safeMinimumWidth {
            let upscale = safeMinimumWidth / target.width
            target = CGSize(width: target.width * upscale, height: target.height * upscale)
        }
        return CGSize(width: target.width.rounded(), height: target.height.rounded())
    }
}
