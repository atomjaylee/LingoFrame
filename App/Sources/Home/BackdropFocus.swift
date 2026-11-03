import CoreGraphics
import Foundation
import Vision

/// 大图裁切的焦点：先找人脸，没有人脸再找画面里最显眼的区域，都找不到就偏上取景。
/// 坐标归一化到 0...1，原点在左上角。每张图只算一次，按地址缓存。
actor BackdropFocus {
    static let shared = BackdropFocus()

    /// 识别不到主体时的焦点：海报的人物和主体大多在上半部分，底部又压着渐变和文字。
    static let fallback = CGPoint(x: 0.5, y: 0.3)

    private var cache: [URL: CGPoint] = [:]

    func point(for image: CGImage, url: URL) -> CGPoint {
        if let cached = cache[url] { return cached }
        let point = Self.detect(in: image) ?? Self.fallback
        cache[url] = point
        return point
    }

    private static func detect(in image: CGImage) -> CGPoint? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, saliency])

        // 太小的脸多半是背景里的路人，只看最大那张脸一半尺寸以上的。
        let faceBoxes = (faces.results ?? []).map(\.boundingBox)
        if let largest = faceBoxes.map({ $0.width * $0.height }).max() {
            let main = faceBoxes.filter { $0.width * $0.height >= largest * 0.25 }
            return topLeftCenter(of: main)
        }
        let salient = (saliency.results ?? []).flatMap { $0.salientObjects ?? [] }.map(\.boundingBox)
        return salient.isEmpty ? nil : topLeftCenter(of: salient)
    }

    /// Vision 的坐标原点在左下角，转成左上角。
    private static func topLeftCenter(of boxes: [CGRect]) -> CGPoint? {
        guard let first = boxes.first else { return nil }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: union.midX, y: 1 - union.midY)
    }
}
