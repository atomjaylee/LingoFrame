import AetherEngine
import Foundation

enum DiscRangeError: Error {
    case unavailable
}

/// 远程 ISO 的共享字节源。
///
/// 引擎自带的读取器每段都请求原地址，重新走一遍跳转；网盘 CDN 每次还会分到不同节点，连接也复用不上。
/// 打开 ISO 要读很多分散的小块，这些开销会把起播拖到一分钟。这里只解析一次跳转，之后直连同一节点，
/// 块缓存由主读取器和字幕等独立读取器共用。
final class RemoteDiscSource: @unchecked Sendable {
    static let blockSize = 256 * 1024
    /// 约 96 MB，足够放下目录结构和近期读过的视频数据。
    static let maxCachedBlocks = 384
    private static let maxAttempts = 3

    struct Response {
        var status: Int
        var contentRange: String?
        var body: Data
        var finalURL: URL?
    }

    struct Stats {
        var requests = 0
        var resolves = 0
        var bytes: Int64 = 0
        var cacheHits = 0
    }

    private struct Block {
        var data: Data
        var lastUsed: UInt64
    }

    let totalSize: Int64
    private let originURL: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var resolvedURL: URL
    private var blocks: [Int64: Block] = [:]
    private var useCounter: UInt64 = 0
    private var readerCount = 1
    private var statistics = Stats()

    /// 同步等待网络，不要在主线程调用。
    init(url: URL, headers: [String: String], configuration: URLSessionConfiguration? = nil) throws {
        let config = configuration ?? Self.defaultConfiguration()
        session = URLSession(configuration: config)
        originURL = url
        self.headers = headers
        guard let response = Self.send(session: session, url: url, headers: headers, offset: 0, length: 1, onTask: { _ in }),
              response.status == 206,
              let total = Self.totalSize(fromContentRange: response.contentRange),
              total > 0,
              let finalURL = response.finalURL else {
            session.invalidateAndCancel()
            throw DiscRangeError.unavailable
        }
        totalSize = total
        resolvedURL = finalURL
        statistics.requests = 1
        statistics.resolves = 1
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 4
        return config
    }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return statistics
    }

    func retain() {
        lock.lock(); readerCount += 1; lock.unlock()
    }

    func release() {
        lock.lock()
        readerCount -= 1
        let isLast = readerCount == 0
        lock.unlock()
        if isLast { session.invalidateAndCancel() }
    }

    /// `offset` 所在块的缓存内容，以及它在块内的位置。
    func cached(at offset: Int64) -> (data: Data, offset: Int)? {
        let start = Self.blockStart(of: offset)
        lock.lock(); defer { lock.unlock() }
        guard var block = blocks[start] else { return nil }
        let inner = Int(offset - start)
        guard inner < block.data.count else { return nil }
        useCounter += 1
        block.lastUsed = useCounter
        blocks[start] = block
        statistics.cacheHits += 1
        return (block.data, inner)
    }

    /// `start` 必须按块对齐。
    func store(_ data: Data, at start: Int64) {
        lock.lock(); defer { lock.unlock() }
        var cursor = data.startIndex
        var blockOffset = start
        while cursor < data.endIndex {
            let end = min(cursor + Self.blockSize, data.endIndex)
            useCounter += 1
            blocks[blockOffset] = Block(data: Data(data[cursor..<end]), lastUsed: useCounter)
            cursor = end
            blockOffset += Int64(Self.blockSize)
        }
        guard blocks.count > Self.maxCachedBlocks else { return }
        let overflow = blocks.count - Self.maxCachedBlocks
        let oldest = blocks.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(overflow)
        for (key, _) in oldest { blocks[key] = nil }
    }

    /// 读取失败时重新解析原地址，覆盖直链过期和节点故障。
    func fetch(offset: Int64, length: Int, isCancelled: () -> Bool,
               onTask: @Sendable @escaping (URLSessionTask) -> Void) -> Data? {
        for attempt in 0..<Self.maxAttempts {
            if isCancelled() { return nil }
            lock.lock()
            let url = resolvedURL
            statistics.requests += 1
            lock.unlock()
            if let response = Self.send(session: session, url: url, headers: headers, offset: offset,
                                        length: length, onTask: onTask),
               response.status == 206,
               Self.startOffset(fromContentRange: response.contentRange) == offset,
               !response.body.isEmpty {
                lock.lock(); statistics.bytes += Int64(response.body.count); lock.unlock()
                return response.body
            }
            if isCancelled() { return nil }
            if attempt > 0 { Thread.sleep(forTimeInterval: Double(attempt) * 0.3) }
            refreshResolvedURL(onTask: onTask)
        }
        return nil
    }

    private func refreshResolvedURL(onTask: @Sendable @escaping (URLSessionTask) -> Void) {
        guard let response = Self.send(session: session, url: originURL, headers: headers, offset: 0,
                                       length: 1, onTask: onTask),
              response.status == 206,
              let finalURL = response.finalURL else { return }
        lock.lock()
        resolvedURL = finalURL
        statistics.resolves += 1
        statistics.requests += 1
        lock.unlock()
    }

    static func blockStart(of offset: Int64) -> Int64 {
        offset - offset % Int64(blockSize)
    }

    /// `bytes 0-0/12345` → 12345。总大小未知（`*`）时返回 nil。
    static func totalSize(fromContentRange value: String?) -> Int64? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// `bytes 100-200/12345` → 100。
    static func startOffset(fromContentRange value: String?) -> Int64? {
        guard let value, let space = value.firstIndex(of: " "), let dash = value.firstIndex(of: "-") else { return nil }
        return Int64(value[value.index(after: space)..<dash])
    }

    private final class ResponseBox: @unchecked Sendable {
        var response: Response?
    }

    private static func send(session: URLSession, url: URL, headers: [String: String], offset: Int64, length: Int,
                             onTask: (URLSessionTask) -> Void) -> Response? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                box.response = Response(status: http.statusCode,
                                        contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                        body: data ?? Data(), finalURL: http.url)
            }
            done.signal()
        }
        onTask(task)
        task.resume()
        done.wait()
        return box.response
    }
}

/// 详情页提前打开的 ISO，点播放时由引擎接管，只保留最近一部。
final class DiscPrewarmStore: @unchecked Sendable {
    static let shared = DiscPrewarmStore()

    private struct Entry {
        var url: URL
        var source: RemoteDiscSource
        var isReady: Bool
    }

    private let lock = NSLock()
    private var entry: Entry?

    func store(_ source: RemoteDiscSource, for url: URL) {
        lock.lock()
        let previous = entry?.source
        entry = Entry(url: url, source: source, isReady: false)
        lock.unlock()
        previous?.release()
    }

    func markReady(_ source: RemoteDiscSource) {
        lock.lock(); defer { lock.unlock() }
        if entry?.source === source { entry?.isReady = true }
    }

    func isReady(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entry?.url == url && entry?.isReady == true
    }

    /// 取走数据源，调用方接手它的引用。
    func take(_ url: URL) -> RemoteDiscSource? {
        lock.lock(); defer { lock.unlock() }
        guard entry?.url == url else { return nil }
        defer { entry = nil }
        return entry?.source
    }
}

/// 给引擎用的读取游标。读取窗口的做法和引擎一致：零散读取用小窗口，连续读取逐步翻倍。
final class DiscRangeReader: IOReader, @unchecked Sendable {
    static let baseWindow = RemoteDiscSource.blockSize
    /// 引擎跳转时要等当前读取结束，窗口太大会拖慢跳转。4 MB 在 75 Mbps 下约 0.45 秒。
    static let maxWindow = 4 * 1024 * 1024

    let source: RemoteDiscSource
    private let lock = NSLock()
    private var position: Int64 = 0
    private var lastFetchEnd: Int64 = -1
    private var window = DiscRangeReader.baseWindow

    private let cancelLock = NSLock()
    private var cancelGeneration = 0
    private var activeTask: URLSessionTask?

    /// 提前读好光盘结构和流信息，放进共享块缓存。预热失败不影响播放，点击后会重新打开。
    static func prewarm(url: URL, headers: [String: String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let source = try? RemoteDiscSource(url: url, headers: headers) else { return false }
            source.retain()
            DiscPrewarmStore.shared.store(source, for: url)
            let reader = DiscRangeReader(source: source)
            defer { reader.close() }
            guard (try? AetherEngine.probe(source: .custom(reader))) != nil else { return false }
            DiscPrewarmStore.shared.markReady(source)
            return true
        }.value
    }

    /// 只有地址看起来是光盘镜像时才走这条路。
    static func handles(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "iso"
    }

    init(source: RemoteDiscSource) {
        self.source = source
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard position < source.totalSize else { return 0 }
        guard let (data, offset) = cachedOrFetched() else { return -1 }
        let count = min(Int(size), data.count - offset)
        guard count > 0 else { return 0 }
        data.withUnsafeBytes { bytes in
            buffer.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), count: count)
        }
        position += Int64(count)
        return Int32(count)
    }

    private func cachedOrFetched() -> (data: Data, offset: Int)? {
        if let hit = source.cached(at: position) { return hit }
        let start = RemoteDiscSource.blockStart(of: position)
        window = position == lastFetchEnd || start == lastFetchEnd
            ? min(window * 2, Self.maxWindow) : Self.baseWindow
        let length = Int(min(Int64(window), source.totalSize - start))
        let generation = currentGeneration()
        guard let data = source.fetch(offset: start, length: length,
                                      isCancelled: { [self] in currentGeneration() != generation },
                                      onTask: { [self] task in setActiveTask(task) }) else { return nil }
        source.store(data, at: start)
        lastFetchEnd = start + Int64(data.count)
        return source.cached(at: position)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return source.totalSize } // AVSEEK_SIZE
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = source.totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    /// 引擎重载时会继续用同一个读取器，这里只打断当前请求，之后的读取照常进行。
    func cancel() {
        cancelLock.lock()
        cancelGeneration += 1
        let task = activeTask
        cancelLock.unlock()
        task?.cancel()
    }

    func close() {
        #if DEBUG
        let stats = source.stats
        NSLog("ISO读取 请求 %d 解析 %d 下载 %lldMB 缓存命中 %d", stats.requests, stats.resolves,
              stats.bytes / 1_048_576, stats.cacheHits)
        #endif
        source.release()
    }

    func makeIndependentReader() -> IOReader? {
        source.retain()
        return DiscRangeReader(source: source)
    }

    private func currentGeneration() -> Int {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelGeneration
    }

    private func setActiveTask(_ task: URLSessionTask) {
        cancelLock.lock(); activeTask = task; cancelLock.unlock()
    }
}
