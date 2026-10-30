import CoreGraphics
import Foundation
import Vision

/// 图形字幕经本机 Vision 识别后的纯文本句子，时间轴沿用原字幕，不上传画面或文字。
public struct RecognizedNativeSubtitleCue: Identifiable, Hashable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let text: String

    public init(id: Int, startTime: Double, endTime: Double, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

/// Vision 会同步等待系统模型，用独立线程执行，避免占住 Swift 并发线程池和播放器主线程。
enum BitmapSubtitleRecognizer {
    nonisolated static func recognize(_ image: CGImage, language: String?) async -> String? {
        await withCheckedContinuation { continuation in
            let worker = Thread {
                let result = autoreleasepool { recognizeSynchronously(image, language: language) }
                continuation.resume(returning: result)
            }
            worker.name = "app.elenglish.subtitle-ocr"
            worker.qualityOfService = .utility
            worker.start()
        }
    }

    private nonisolated static func recognizeSynchronously(_ image: CGImage, language: String?) -> String? {
        guard let flattened = flattenedOntoBlack(image) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        if let language = visionLanguage(language),
           let supported = try? request.supportedRecognitionLanguages(),
           let match = supported.first(where: { $0 == language || $0.hasPrefix(language + "-") }) {
            request.recognitionLanguages = [match]
        }
        do {
            try VNImageRequestHandler(cgImage: flattened).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation -> (String, CGFloat)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, observation.boundingBox.midY)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func flattenedOntoBlack(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private nonisolated static func visionLanguage(_ value: String?) -> String? {
        guard let value = value?.lowercased() else { return nil }
        if value == "eng" || value == "en" || value.hasPrefix("en-") { return "en" }
        if ["chi", "zho", "zh", "chs", "cht"].contains(value) || value.hasPrefix("zh-") { return "zh" }
        return value
    }
}
