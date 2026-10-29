import CryptoKit
import Foundation
import libmpv

enum MediaCacheTesting {
    nonisolated(unsafe) static var protocolClasses: [AnyClass]?
}

/// 远程媒体的稳定身份与当前可用地址。cacheKey 不包含会过期的签名 URL。
public struct CachedMediaSource: Sendable {
    public var cacheKey: String
    public var url: URL
    public var size: Int64?
    public var fileExtension: String?

    public init(cacheKey: String, url: URL, size: Int64?, fileExtension: String? = nil) {
        self.cacheKey = cacheKey
        self.url = url
        self.size = size
        self.fileExtension = fileExtension
    }
}

/// libmpv 自定义协议的注册表。播放地址变化时替换源信息，磁盘块仍按稳定 cacheKey 复用。
final class MPVStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: PersistentMediaSource] = [:]
    private let root: URL

    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ELEnglish/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func register(_ descriptor: CachedMediaSource) -> URL {
        let token = Self.token(for: descriptor.cacheKey)
        lock.lock()
        if let source = sources[token] {
            source.update(url: descriptor.url, size: descriptor.size)
        } else {
            sources[token] = PersistentMediaSource(descriptor: descriptor,
                                                   directory: root.appendingPathComponent(token, isDirectory: true))
        }
        lock.unlock()
        let ext = descriptor.fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "media"
        return URL(string: "elcache://\(token)/source.\(ext)")!
    }

    fileprivate func source(for uri: String) -> PersistentMediaSource? {
        guard let url = URL(string: uri), let token = url.host else { return nil }
        return lock.withLock { sources[token] }
    }

    private static func token(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class PersistentMediaSource: @unchecked Sendable {
    private static let blockSize = 2 * 1024 * 1024
    private let lock = NSLock()
    private let directory: URL
    private var remoteURL: URL
    private var knownSize: Int64?

    init(descriptor: CachedMediaSource, directory: URL) {
        remoteURL = descriptor.url
        knownSize = descriptor.size
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func update(url: URL, size: Int64?) {
        lock.withLock {
            remoteURL = url
            if let size { knownSize = size }
        }
    }

    func size() -> Int64? { lock.withLock { knownSize } }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        return try lock.withLock {
            if let knownSize, offset >= knownSize { return Data() }
            var result = Data()
            var cursor = offset
            let requestedEnd = offset + Int64(count)
            let finalEnd = min(requestedEnd, knownSize ?? requestedEnd)
            while cursor < finalEnd {
                let index = cursor / Int64(Self.blockSize)
                let blockStart = index * Int64(Self.blockSize)
                let block = try blockData(index: index, start: blockStart)
                let inside = Int(cursor - blockStart)
                guard inside < block.count else { break }
                let take = min(block.count - inside, Int(finalEnd - cursor))
                result.append(block.subdata(in: inside..<(inside + take)))
                cursor += Int64(take)
            }
            return result
        }
    }

    private func blockData(index: Int64, start: Int64) throws -> Data {
        let file = directory.appendingPathComponent("\(index).block")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }

        let end = min(start + Int64(Self.blockSize) - 1, (knownSize ?? .max) - 1)
        var request = URLRequest(url: remoteURL)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        let response = SynchronousResponse(expectedStart: start, maximumBytes: Self.blockSize,
                                           allowsWholeFile: (knownSize ?? .max) <= Int64(Self.blockSize))
        #if DEBUG
        let began = ContinuousClock.now
        #endif
        response.fetch(request)
        #if DEBUG
        NSLog("块缓存 下载 块%lld 状态 %ld 字节 %ld 用时 %@ %@", index, response.response?.statusCode ?? -1,
              response.data?.count ?? 0, "\(began.duration(to: .now))", response.error.map { "\($0)" } ?? "")
        #endif
        if let error = response.error { throw error }
        guard let data = response.data, !data.isEmpty else { throw URLError(.zeroByteResource) }
        if start > 0, response.response?.statusCode != 206 { throw URLError(.badServerResponse) }
        if let range = response.response?.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            knownSize = total
        } else if response.response?.statusCode == 200, start == 0,
                  let length = response.response?.expectedContentLength, length > 0 {
            knownSize = length
        }
        try data.write(to: file, options: .atomic)
        return data
    }
}

private final class SynchronousResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let expectedStart: Int64
    private let maximumBytes: Int
    private let allowsWholeFile: Bool
    private var buffer = Data()
    private var finished = false
    private(set) var data: Data?
    private(set) var response: HTTPURLResponse?
    private(set) var error: Error?

    init(expectedStart: Int64, maximumBytes: Int, allowsWholeFile: Bool) {
        self.expectedStart = expectedStart
        self.maximumBytes = maximumBytes
        self.allowsWholeFile = allowsWholeFile
    }

    func fetch(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses = MediaCacheTesting.protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        self.response = http
        if http?.statusCode == 206 || (expectedStart == 0 && allowsWholeFile && http?.statusCode == 200) {
            completionHandler(.allow)
        } else {
            error = URLError(.badServerResponse)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.withLock {
            guard buffer.count < maximumBytes else { return }
            buffer.append(chunk.prefix(maximumBytes - buffer.count))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError taskError: Error?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            data = buffer
            if error == nil, let taskError, (taskError as? URLError)?.code != .cancelled { error = taskError }
        }
        semaphore.signal()
    }
}

private final class CachedStreamCursor: @unchecked Sendable {
    let source: PersistentMediaSource
    private let lock = NSLock()
    private var position: Int64 = 0
    private var cancelled = false

    init(source: PersistentMediaSource) { self.source = source }

    func read(_ buffer: UnsafeMutablePointer<CChar>?, count: UInt64) -> Int64 {
        guard let buffer else { return -1 }
        do {
            let (offset, allowed) = lock.withLock { (position, !cancelled) }
            guard allowed else { return -1 }
            let data = try source.read(offset: offset, count: min(Int(count), 4 * 1024 * 1024))
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: data.count))
            lock.withLock { position += Int64(data.count) }
            return Int64(data.count)
        } catch {
            return -1
        }
    }

    func seek(_ offset: Int64) -> Int64 {
        guard offset >= 0 else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        return lock.withLock {
            guard !cancelled else { return Int64(MPV_ERROR_GENERIC.rawValue) }
            position = offset
            return position
        }
    }

    func cancel() { lock.withLock { cancelled = true } }
}

func mpvCacheOpen(_ userData: UnsafeMutableRawPointer?, _ uri: UnsafeMutablePointer<CChar>?,
                  _ info: UnsafeMutablePointer<mpv_stream_cb_info>?) -> Int32 {
    guard let userData, let uri, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
    let registry = Unmanaged<MPVStreamRegistry>.fromOpaque(userData).takeUnretainedValue()
    guard let source = registry.source(for: String(cString: uri)) else { return MPV_ERROR_LOADING_FAILED.rawValue }
    info.pointee.cookie = Unmanaged.passRetained(CachedStreamCursor(source: source)).toOpaque()
    info.pointee.read_fn = mpvCacheRead
    info.pointee.seek_fn = mpvCacheSeek
    info.pointee.size_fn = mpvCacheSize
    info.pointee.close_fn = mpvCacheClose
    info.pointee.cancel_fn = mpvCacheCancel
    return 0
}

private func mpvCacheRead(_ cookie: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<CChar>?,
                          _ count: UInt64) -> Int64 {
    guard let cookie else { return -1 }
    return Unmanaged<CachedStreamCursor>.fromOpaque(cookie).takeUnretainedValue().read(buffer, count: count)
}

private func mpvCacheSeek(_ cookie: UnsafeMutableRawPointer?, _ offset: Int64) -> Int64 {
    guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
    return Unmanaged<CachedStreamCursor>.fromOpaque(cookie).takeUnretainedValue().seek(offset)
}

private func mpvCacheSize(_ cookie: UnsafeMutableRawPointer?) -> Int64 {
    guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
    return Unmanaged<CachedStreamCursor>.fromOpaque(cookie).takeUnretainedValue().source.size()
        ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
}

private func mpvCacheClose(_ cookie: UnsafeMutableRawPointer?) {
    guard let cookie else { return }
    Unmanaged<CachedStreamCursor>.fromOpaque(cookie).release()
}

private func mpvCacheCancel(_ cookie: UnsafeMutableRawPointer?) {
    guard let cookie else { return }
    Unmanaged<CachedStreamCursor>.fromOpaque(cookie).takeUnretainedValue().cancel()
}
