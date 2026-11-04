import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Synchronization

/// 解码后的位图。CGImage 本身是不可变的，可以安全地跨线程传递。
public struct DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
}

/// 一张图的平均色。用来实现「背景随内容变色」：从海报或剧照取色、压暗，作为整页底色。
public struct ArtworkColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 页面底色：深色主题压暗到不抢内容，浅色主题提亮成同色相的淡色。
    public func pageTint(dark: Bool) -> Color {
        let ns = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let tint = dark
            ? NSColor(hue: h, saturation: min(max(s * 0.85, 0.18), 0.55), brightness: min(max(b * 0.5, 0.16), 0.3), alpha: 1)
            : NSColor(hue: h, saturation: min(s * 0.35, 0.14), brightness: 0.94, alpha: 1)
        return Color(nsColor: tint)
    }
}

/// 需要认证的图片服务器。认证头只发给登记过的地址（协议、主机、端口都相同），TMDB 等第三方图片拿不到。
struct ImageAuthorization: Sendable {
    private var headersByOrigin: [String: [String: String]] = [:]

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    mutating func setHeaders(_ headers: [String: String]?, forServer url: URL) {
        guard let origin = Self.origin(of: url) else { return }
        headersByOrigin[origin] = headers
    }

    func headers(for url: URL) -> [String: String] {
        Self.origin(of: url).flatMap { headersByOrigin[$0] } ?? [:]
    }

    /// 图片跳转到别的地址（比如对象存储）时去掉认证头，否则令牌会泄露给第三方。
    static func redirect(_ request: URLRequest, from original: URL?, removing names: [String]) -> URLRequest {
        guard let original, let target = request.url, origin(of: original) != origin(of: target) else { return request }
        var request = request
        for name in names { request.setValue(nil, forHTTPHeaderField: name) }
        return request
    }
}

private final class ImageRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let headerNames: [String]

    init(headerNames: [String]) {
        self.headerNames = headerNames
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        ImageAuthorization.redirect(request, from: task.originalRequest?.url, removing: headerNames)
    }
}

/// 图片加载管线：内存缓存 + URLCache 磁盘缓存 + ImageIO 按显示尺寸降采样解码。
/// 海报墙一屏几十张图，降采样能把解码内存和 CPU 占用降一个数量级。
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private let session: URLSession
    private nonisolated(unsafe) let memory = NSCache<NSString, CGImageBox>()
    private var colors: [URL: ArtworkColor] = [:]
    private var inFlight: [String: Task<DecodedImage, Error>] = [:]
    private nonisolated let authorization = Mutex(ImageAuthorization())

    public init(diskCapacityMB: Int = 512) {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.elenglish/Images", isDirectory: true)
        let config = URLSessionConfiguration.default
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        config.httpAdditionalHeaders = ["User-Agent": "Pixon/\(version) (macOS)"]
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: diskCapacityMB << 20, directory: cacheURL)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.totalCostLimit = 128 << 20
    }

    /// 登记服务器的认证头，传 nil 取消。有些服务器的图片接口也要求令牌。
    public nonisolated func setHeaders(_ headers: [String: String]?, forServer url: URL) {
        authorization.withLock { $0.setHeaders(headers, forServer: url) }
    }

    /// 内存里已经解码好的图，可以在渲染时同步读取。NSCache 本身线程安全。
    public nonisolated func cachedImage(for url: URL, maxPixelSize: Int) -> DecodedImage? {
        let key = "\(url.absoluteString)#\(maxPixelSize)"
        return memory.object(forKey: key as NSString).map { DecodedImage(cgImage: $0.image) }
    }

    public func image(for url: URL, maxPixelSize: Int) async throws -> DecodedImage {
        let key = "\(url.absoluteString)#\(maxPixelSize)"
        if let cached = cachedImage(for: url, maxPixelSize: maxPixelSize) { return cached }
        if let task = inFlight[key] { return try await task.value }

        var request = URLRequest(url: url)
        let headers = authorization.withLock { $0.headers(for: url) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = Task { [session, request] in
            let redirectGuard = headers.isEmpty ? nil : ImageRedirectGuard(headerNames: Array(headers.keys))
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  ] as CFDictionary)
            else { throw URLError(.cannotDecodeContentData) }
            return DecodedImage(cgImage: image)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let decoded = try await task.value
        memory.setObject(CGImageBox(decoded.cgImage), forKey: key as NSString,
                         cost: decoded.cgImage.bytesPerRow * decoded.cgImage.height)
        return decoded
    }

    /// 图片的平均色。先解码成 24px 的小图再缩成 1 个像素，开销可以忽略；结果按地址缓存。
    public func averageColor(for url: URL) async -> ArtworkColor? {
        if let cached = colors[url] { return cached }
        guard let small = try? await image(for: url, maxPixelSize: 24) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(small.cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let color = ArtworkColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
        colors[url] = color
        return color
    }
}

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// 远程图片。maxPixelSize 应该等于显示尺寸 × 屏幕缩放倍数。
public struct RemoteImage: View {
    private let url: URL?
    private let maxPixelSize: Int
    private let contentMode: ContentMode
    private let showsPlaceholder: Bool
    @State private var image: DecodedImage?
    @Environment(\.theme) private var theme

    /// contentMode 为 .fit 且不显示占位底色时，适合透明的片名 Logo。
    public init(url: URL?, maxPixelSize: Int = 600, contentMode: ContentMode = .fill, showsPlaceholder: Bool = true) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.showsPlaceholder = showsPlaceholder
        // 内存命中时第一帧就有图，返回列表时海报不会闪一下占位色。
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) })
    }

    public var body: some View {
        ZStack {
            if showsPlaceholder { theme.colors.surfaceControl.color }
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
                image = cached
                return
            }
            image = nil
            let loaded = try? await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}
