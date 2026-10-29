import CryptoKit
import Foundation
import libmpv

enum MediaCacheTesting {
    nonisolated(unsafe) static var protocolClasses: [AnyClass]?
}

public enum MediaCachePolicy {
    public static let limitGBKey = "player.cache.limitGB"
    public static let defaultLimitGB = 20
    public static let allowedLimitGB = [5, 10, 20, 50, 100, 200]

    public static var limitGB: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: limitGBKey)
            return allowedLimitGB.contains(saved) ? saved : defaultLimitGB
        }
        set {
            UserDefaults.standard.set(allowedLimitGB.contains(newValue) ? newValue : defaultLimitGB,
                                      forKey: limitGBKey)
        }
    }

    public static var limitBytes: Int64 { Int64(limitGB) * 1024 * 1024 * 1024 }

    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ELEnglish/Media", isDirectory: true)
    }

    public static func currentUsageBytes() -> Int64 { allocatedSize(of: directory) }

    public static func pruneNow() {
        MPVStreamRegistry.pruneGlobalCache(root: directory, excluding: nil)
    }

    public static func clear() throws {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in contents { try manager.removeItem(at: item) }
    }

    fileprivate static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
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

/// libmpv 自定义协议的注册表。一个媒体源只保留一条连续上游连接，跳转时才重新发 Range 请求。
final class MPVStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: ContinuousMediaSource] = [:]
    private var activeToken: String?
    private let root: URL

    init() {
        root = MediaCachePolicy.directory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.removeLegacyBlockCache(from: root)
    }

    func register(_ descriptor: CachedMediaSource) -> URL {
        let token = Self.token(for: descriptor.cacheKey)
        let directory = root.appendingPathComponent(token, isDirectory: true)
        lock.lock()
        if let source = sources[token] {
            source.update(url: descriptor.url, size: descriptor.size)
        } else {
            sources[token] = ContinuousMediaSource(descriptor: descriptor, directory: directory)
        }
        activeToken = token
        lock.unlock()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        schedulePrune(excludingActive: true)
        let rawExtension = descriptor.fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "media"
        let sanitizedExtension = rawExtension.filter { $0.isLetter || $0.isNumber }
        let ext = sanitizedExtension.isEmpty ? "media" : String(sanitizedExtension.prefix(16))
        var components = URLComponents()
        components.scheme = "elcache"
        components.host = token
        components.path = "/source.\(ext)"
        return components.url ?? descriptor.url
    }

    fileprivate func source(for uri: String) -> ContinuousMediaSource? {
        guard let url = URL(string: uri), let token = url.host else { return nil }
        return lock.withLock {
            sources[token]?.prepareForOpen()
            return sources[token]
        }
    }

    func applyConfiguredLimit(excludingActive: Bool) {
        schedulePrune(excludingActive: excludingActive)
    }

    private func schedulePrune(excludingActive: Bool) {
        let root = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let token = self.lock.withLock { excludingActive ? self.activeToken : nil }
            Self.pruneGlobalCache(root: root, excluding: token)
        }
    }

    func reset() {
        let oldSources = lock.withLock { () -> [ContinuousMediaSource] in
            let values = Array(sources.values)
            sources.removeAll()
            activeToken = nil
            return values
        }
        oldSources.forEach { $0.cancel() }
    }

    private static func token(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func pruneGlobalCache(root: URL, excluding activeToken: String?) {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, date: Date, size: Int64)] = directories.compactMap { directory in
            guard directory.lastPathComponent != activeToken else { return nil }
            let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (directory, date, MediaCachePolicy.allocatedSize(of: directory))
        }
        let activeSize = activeToken.map { MediaCachePolicy.allocatedSize(of: root.appendingPathComponent($0, isDirectory: true)) } ?? 0
        var total = activeSize + entries.reduce(Int64(0)) { $0 + $1.size }
        let limit = MediaCachePolicy.limitBytes
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit * 9 / 10 {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// v1 的 2MB 独立请求缓存不能复用，并会绕过新限额；升级时只删除这些可再生缓存块。
    private static func removeLegacyBlockCache(from root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.pathExtension == "block" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private struct CachedRange {
    var start: Int64
    var length: Int64
    var file: URL
    var end: Int64 { start + length }
}

/// 持久缓存的一个 64MB 文件段。网络连接不切断，只在磁盘上滚动分段，便于限额和回收。
private final class SegmentWriter {
    static let limit: Int64 = 64 * 1024 * 1024
    let start: Int64
    let file: URL
    private let handle: FileHandle
    private(set) var length: Int64 = 0

    init(start: Int64, directory: URL) throws {
        self.start = start
        file = directory.appendingPathComponent("segment-\(start)-\(UUID().uuidString).range")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
    }

    func append(_ data: Data) throws -> Int {
        let count = min(data.count, Int(Self.limit - length))
        guard count > 0 else { return 0 }
        try handle.write(contentsOf: data.prefix(count))
        length += Int64(count)
        return count
    }

    var isFull: Bool { length >= Self.limit }
    func close() { try? handle.close() }
    deinit { close() }
}

/// 单连接连续读取器：URLSession 持续收数据，libmpv 每次 read 都从已落盘范围直接返回。
private final class ContinuousMediaSource: @unchecked Sendable {
    private static let maximumAhead: Int64 = 16 * 1024 * 1024
    private static let resumeAhead: Int64 = 8 * 1024 * 1024
    private static let maximumBack: Int64 = 512 * 1024 * 1024

    private let condition = NSCondition()
    private let directory: URL
    private var remoteURL: URL
    private var redirectedURL: URL?
    private var knownSize: Int64?
    private var ranges: [CachedRange] = []
    private var writer: SegmentWriter?
    private var request: ContinuousRequest?
    private var generation: UInt64 = 0
    private var requestStart: Int64 = 0
    private var downloadedEnd: Int64 = 0
    private var consumerOffset: Int64 = 0
    private var eofOffset: Int64?
    private var networkError: Error?
    private var retryingOriginal = false
    private var networkRetryCount = 0

    init(descriptor: CachedMediaSource, directory: URL) {
        remoteURL = descriptor.url
        knownSize = descriptor.size
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ranges = Self.loadRanges(from: directory)
    }

    func update(url: URL, size: Int64?) {
        condition.withLock {
            remoteURL = url
            if let size { knownSize = size }
            if request == nil { ranges = Self.loadRanges(from: directory) }
        }
    }

    func size() -> Int64? { condition.withLock { knownSize } }

    func prepareForOpen() {
        condition.withLock {
            networkError = nil
            networkRetryCount = 0
        }
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        condition.lock()
        defer { condition.unlock() }
        consumerOffset = offset
        let deadline = Date().addingTimeInterval(30)
        while true {
            if let data = readCached(offset: offset, count: count), !data.isEmpty {
                consumerOffset = offset + Int64(data.count)
                resumeIfNeeded()
                pruneIfNeeded()
                return data
            }
            if let knownSize, offset >= knownSize { return Data() }
            if let eofOffset, offset >= eofOffset { return Data() }
            if let error = networkError {
                networkError = nil
                throw error
            }
            if !requestCanReach(offset) { startRequest(at: offset) }
            guard condition.wait(until: deadline) else { throw URLError(.timedOut) }
        }
    }

    func prioritize(_ offset: Int64) {
        condition.withLock {
            consumerOffset = offset
            guard cachedRange(containing: offset) == nil, !requestCanReach(offset) else {
                resumeIfNeeded()
                return
            }
            startRequest(at: offset)
        }
    }

    func cancel() {
        condition.withLock {
            generation &+= 1
            request?.cancel()
            request = nil
            writer?.close()
            writer = nil
            networkError = URLError(.cancelled)
            condition.broadcast()
        }
    }

    fileprivate func accepted(generation: UInt64, response: HTTPURLResponse, usedRedirect: Bool) -> Bool {
        condition.withLock {
            guard generation == self.generation else { return false }
            if let total = Self.totalSize(from: response) { knownSize = total }
            if let finalURL = response.url, finalURL.host != remoteURL.host { redirectedURL = finalURL }
            let valid = response.statusCode == 206 || (requestStart == 0 && response.statusCode == 200)
            if !valid {
                if usedRedirect, [401, 403].contains(response.statusCode), !retryingOriginal {
                    redirectedURL = nil
                    retryingOriginal = true
                }
                networkError = URLError(.badServerResponse)
            }
            return valid
        }
    }

    fileprivate func rememberRedirect(generation: UInt64, url: URL) {
        condition.withLock {
            guard generation == self.generation else { return }
            redirectedURL = url
        }
    }

    fileprivate func receive(generation: UInt64, data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard generation == self.generation else { return }
        do {
            var remainder = data
            while !remainder.isEmpty {
                if writer == nil { writer = try SegmentWriter(start: downloadedEnd, directory: directory) }
                guard let writer else { break }
                let written = try writer.append(remainder)
                if let index = ranges.firstIndex(where: { $0.file == writer.file }) {
                    ranges[index].length = writer.length
                } else {
                    ranges.append(CachedRange(start: writer.start, length: writer.length, file: writer.file))
                }
                downloadedEnd += Int64(written)
                remainder.removeFirst(written)
                if writer.isFull { writer.close(); self.writer = nil }
            }
            if downloadedEnd - consumerOffset >= Self.maximumAhead { request?.suspend() }
            condition.broadcast()
        } catch {
            networkError = error
            condition.broadcast()
        }
    }

    fileprivate func completed(generation: UInt64, error: Error?) {
        condition.withLock {
            guard generation == self.generation else { return }
            request = nil
            writer?.close()
            writer = nil
            if let error, (error as? URLError)?.code != .cancelled {
                if retryingOriginal {
                    retryingOriginal = false
                    startRequest(at: downloadedEnd, forceOriginal: true, isRetry: true)
                } else if networkRetryCount < 2 {
                    networkRetryCount += 1
                    startRequest(at: downloadedEnd, isRetry: true)
                } else {
                    networkError = error
                }
            } else if error == nil {
                eofOffset = downloadedEnd
            }
            #if DEBUG
            NSLog("媒体缓存连接结束 bytes=%lld error=%@", downloadedEnd - requestStart,
                  error?.localizedDescription ?? "-")
            #endif
            condition.broadcast()
        }
    }

    private func startRequest(at offset: Int64, forceOriginal: Bool = false, isRetry: Bool = false) {
        if !isRetry { networkRetryCount = 0 }
        generation &+= 1
        request?.cancel()
        writer?.close()
        writer = nil
        requestStart = offset
        downloadedEnd = offset
        eofOffset = nil
        networkError = nil
        let url = forceOriginal ? remoteURL : (redirectedURL ?? remoteURL)
        #if DEBUG
        NSLog("媒体缓存连接开始 offset=%lld direct=%@", offset, url == remoteURL ? "no" : "yes")
        #endif
        let request = ContinuousRequest(source: self, generation: generation, url: url, offset: offset,
                                        usedRedirect: !forceOriginal && redirectedURL != nil)
        self.request = request
        request.start()
    }

    private func requestCanReach(_ offset: Int64) -> Bool {
        guard request != nil else { return false }
        // 持续连接只能继续向后读；已经越过但又不在磁盘缓存里的位置必须重新发 Range。
        return offset >= downloadedEnd && offset <= downloadedEnd + Self.maximumAhead
    }

    private func resumeIfNeeded() {
        if downloadedEnd - consumerOffset < Self.resumeAhead { request?.resume() }
    }

    private func readCached(offset: Int64, count: Int) -> Data? {
        guard let range = cachedRange(containing: offset) else { return nil }
        let available = min(Int64(count), range.end - offset)
        guard available > 0, let handle = try? FileHandle(forReadingFrom: range.file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset - range.start))
        return try? handle.read(upToCount: Int(available))
    }

    private func cachedRange(containing offset: Int64) -> CachedRange? {
        ranges.filter { offset >= $0.start && offset < $0.end }.max { $0.end < $1.end }
    }

    private func pruneIfNeeded() {
        var total = ranges.reduce(Int64(0)) { $0 + $1.length }
        let limit = MediaCachePolicy.limitBytes
        guard total > limit else { return }
        let keepBack = min(Self.maximumBack, max(64 * 1024 * 1024, limit / 4))
        let keepAfter = max(0, consumerOffset - keepBack)
        let activeFile = writer?.file
        for range in ranges.sorted(by: { $0.start < $1.start })
        where total > limit * 9 / 10 && range.end < keepAfter && range.file != activeFile {
            try? FileManager.default.removeItem(at: range.file)
            ranges.removeAll { $0.file == range.file }
            total -= range.length
        }
    }

    private static func loadRanges(from directory: URL) -> [CachedRange] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { file in
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.first == "segment", parts.count >= 3, let start = Int64(parts[1]),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
            return CachedRange(start: start, length: Int64(size), file: file)
        }.sorted { $0.start < $1.start }
    }

    private static func totalSize(from response: HTTPURLResponse) -> Int64? {
        response.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int64($0) }
            ?? (response.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil)
    }
}

/// 一次连续 Range 请求。收到的数据立即交给 ContinuousMediaSource 落盘，不等整段下载完。
private final class ContinuousRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var source: ContinuousMediaSource?
    private let generation: UInt64
    private let initialURL: URL
    private let offset: Int64
    private let usedRedirect: Bool
    private let stateLock = NSLock()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var suspended = false
    private var rejected = false

    init(source: ContinuousMediaSource, generation: UInt64, url: URL, offset: Int64, usedRedirect: Bool) {
        self.source = source
        self.generation = generation
        initialURL = url
        self.offset = offset
        self.usedRedirect = usedRedirect
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        if let protocolClasses = MediaCacheTesting.protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: initialURL)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        let task = session.dataTask(with: request)
        stateLock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func suspend() {
        stateLock.withLock {
            guard !suspended else { return }
            suspended = true
            task?.suspend()
        }
    }

    func resume() {
        stateLock.withLock {
            guard suspended else { return }
            suspended = false
            task?.resume()
        }
    }

    func cancel() {
        stateLock.withLock {
            task?.cancel()
            session?.invalidateAndCancel()
            task = nil
            session = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(request); return }
        source?.rememberRedirect(generation: generation, url: url)
        var redirected = request
        redirected.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              source?.accepted(generation: generation, response: response, usedRedirect: usedRedirect) == true else {
            rejected = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        source?.receive(generation: generation, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finalError = rejected ? URLError(.badServerResponse) : error
        source?.completed(generation: generation, error: finalError)
        session.finishTasksAndInvalidate()
    }
}

private final class CachedStreamCursor: @unchecked Sendable {
    let source: ContinuousMediaSource
    private let lock = NSLock()
    private var position: Int64 = 0
    private var cancelled = false

    init(source: ContinuousMediaSource) { self.source = source }

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
        let result = lock.withLock { () -> Int64 in
            guard !cancelled else { return Int64(MPV_ERROR_GENERIC.rawValue) }
            position = offset
            return position
        }
        if result >= 0 { source.prioritize(offset) }
        return result
    }

    func cancel() {
        lock.withLock { cancelled = true }
        source.cancel()
    }
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

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
