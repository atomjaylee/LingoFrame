import CryptoKit
import Foundation
import Observation
import os

/// 一份片目列表的身份。同一媒体库的货架和海报墙用同一个键时共享数据，点进海报墙不用重新等第一页。
public struct LibraryListKey: Hashable, Sendable {
    public var serverID: String
    public var libraryID: String
    public var sort: EmbyClient.Sort
    public var descending: Bool

    public init(serverID: String, libraryID: String, sort: EmbyClient.Sort, descending: Bool) {
        self.serverID = serverID
        self.libraryID = libraryID
        self.sort = sort
        self.descending = descending
    }
}

/// 写到磁盘的列表快照。结构变化时递增 version，旧文件会被当作没有缓存。
struct LibrarySnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version = LibrarySnapshot.currentVersion
    var items: [EmbyItem]
    var total: Int?
    var fetchedAt: Date
}

/// 片目的磁盘缓存：放在 Caches 里，内容可以随时被系统清掉。每台服务器一个目录，删除服务器时整体移除。
public actor LibraryDiskCache {
    private struct LibrariesFile: Codable {
        var libraries: [EmbyItem]
    }

    nonisolated let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func read(_ key: LibraryListKey) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
              snapshot.version == LibrarySnapshot.currentVersion else { return nil }
        return snapshot
    }

    func write(_ snapshot: LibrarySnapshot, for key: LibraryListKey) {
        store(snapshot, at: url(for: key))
    }

    /// 媒体库列表很小，服务器连接创建时同步读取，这样冷启动第一帧就能排出货架。
    nonisolated func readLibraries(serverID: String) -> [EmbyItem] {
        guard let data = try? Data(contentsOf: librariesURL(serverID: serverID)),
              let file = try? JSONDecoder().decode(LibrariesFile.self, from: data) else { return [] }
        return file.libraries
    }

    func writeLibraries(_ libraries: [EmbyItem], serverID: String) {
        store(LibrariesFile(libraries: libraries), at: librariesURL(serverID: serverID))
    }

    func removeServer(_ serverID: String) {
        try? FileManager.default.removeItem(at: serverDirectory(serverID))
    }

    private func store(_ value: some Encodable, at url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated func serverDirectory(_ serverID: String) -> URL {
        directory.appendingPathComponent(Self.digest(serverID), isDirectory: true)
    }

    private nonisolated func librariesURL(serverID: String) -> URL {
        serverDirectory(serverID).appendingPathComponent("libraries.json")
    }

    private nonisolated func url(for key: LibraryListKey) -> URL {
        let name = Self.digest("\(key.libraryID)|\(key.sort.rawValue)|\(key.descending)")
        return serverDirectory(key.serverID).appendingPathComponent("\(name).json")
    }

    /// 编号来自服务器、地址里有斜杠，统一哈希后才能安全地当文件名。
    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 一份可以跨页面共享的片目列表：先显示缓存，再在后台校验，刷新时不清空已经显示的内容。
@MainActor
@Observable
public final class LibraryList {
    public static let pageSize = 60
    /// 超过这个时间的数据下次出现时会在后台校验。
    static let staleAfter: TimeInterval = 5 * 60
    /// 观看进度变化时最多重新读取多少条。列表再长，靠后条目的进度等下一次校验。
    static let progressRefreshLimit = 200
    /// 磁盘只存前面这些条目，够冷启动铺满几屏，更多的按需分页。
    static let diskItemLimit = 300

    private static let log = Logger(subsystem: "app.elenglish", category: "LibraryList")

    public private(set) var items: [EmbyItem] = []
    public private(set) var total: Int?
    public private(set) var errorMessage: String?
    private var isRevalidating = false
    public private(set) var isLoadingMore = false
    /// 已经有结论（缓存命中，或网络请求成功或失败过）。在这之前不能显示“媒体库是空的”。
    private var hasLoaded = false

    @ObservationIgnored let key: LibraryListKey
    @ObservationIgnored var client: EmbyClient
    @ObservationIgnored private let disk: LibraryDiskCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var seenProgressRevision: UInt64?
    @ObservationIgnored private var userDataIsStale = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    init(key: LibraryListKey, client: EmbyClient, disk: LibraryDiskCache, now: @escaping @Sendable () -> Date = { .now }) {
        self.key = key
        self.client = client
        self.disk = disk
        self.now = now
    }

    public var hasMore: Bool { !reachedEnd && total.map { items.count < $0 } ?? true }
    /// 还没有任何内容可显示，需要占位的加载状态。
    public var isLoadingFirstPage: Bool { items.isEmpty && (isRevalidating || !hasLoaded) }
    public var isConfirmedEmpty: Bool { items.isEmpty && !isLoadingFirstPage && errorMessage == nil }

    private var isStale: Bool {
        guard let fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) >= Self.staleAfter
    }

    /// 页面出现时调用：恢复磁盘缓存，数据过期或观看进度变化时在后台校验。重复调用没有代价。
    public func revalidate(progressRevision: UInt64? = nil) async {
        await restoreIfNeeded()
        if let progressRevision {
            if let seen = seenProgressRevision, seen != progressRevision { userDataIsStale = true }
            seenProgressRevision = progressRevision
        }
        guard !Task.isCancelled, isStale || userDataIsStale else { return }
        await fetchFirstPage()
    }

    /// 用户手动刷新：不管数据多新都校验，但不清空已显示的内容。
    public func refresh() async {
        await restoreIfNeeded()
        await fetchFirstPage()
    }

    /// 让下一次 revalidate 一定发请求。
    func markStale() {
        fetchedAt = nil
    }

    public func loadMore() async {
        guard !isRevalidating, !isLoadingMore, hasMore else { return }
        let current = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let previousCount = items.count
            let page = try await client.items(in: key.libraryID, sort: key.sort, descending: key.descending,
                                              start: previousCount, limit: Self.pageSize)
            // 这一页是按校验之前的偏移取的，校验已经改了列表时不能再拼上去。
            guard !Task.isCancelled, current == generation else { return }
            let known = Set(items.map(\.id))
            let added = page.items.filter { !known.contains($0.id) }
            items += added
            total = page.totalRecordCount ?? items.count
            // 服务器端条目变动时 total 可能偏大，一页都是重复条目就说明到头了。
            if added.isEmpty { reachedEnd = true }
            if previousCount < Self.diskItemLimit { await persist() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            report(error)
        }
    }

    private func restoreIfNeeded() async {
        if restoreTask == nil {
            restoreTask = Task { [disk, key] in
                guard let snapshot = await disk.read(key), !snapshot.items.isEmpty, items.isEmpty else { return }
                items = snapshot.items
                total = snapshot.total
                fetchedAt = snapshot.fetchedAt
                hasLoaded = true
            }
        }
        await restoreTask?.value
    }

    private func fetchFirstPage() async {
        generation &+= 1
        let current = generation
        isRevalidating = true
        defer { if current == generation { isRevalidating = false } }
        // 观看进度变了时要覆盖已经加载的条目，否则用户滚到后面看到的还是旧进度。
        let limit = userDataIsStale ? max(Self.pageSize, min(items.count, Self.progressRefreshLimit)) : Self.pageSize
        do {
            let page = try await client.items(in: key.libraryID, sort: key.sort, descending: key.descending,
                                              start: 0, limit: limit)
            guard !Task.isCancelled, current == generation else { return }
            let freshTotal = page.totalRecordCount ?? page.items.count
            let merged = Self.merge(cached: items, cachedTotal: total, fresh: page.items, freshTotal: freshTotal)
            if merged != items { items = merged }
            if total != freshTotal { total = freshTotal }
            reachedEnd = false
            fetchedAt = now()
            userDataIsStale = false
            errorMessage = nil
            hasLoaded = true
            await persist()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            report(error)
        }
    }

    /// 已有内容时失败不打扰用户，继续显示缓存；下次出现时会再试。
    private func report(_ error: any Error) {
        hasLoaded = true
        Self.log.error("片目加载失败 \(self.key.libraryID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if items.isEmpty { errorMessage = error.localizedDescription }
    }

    private func persist() async {
        guard let fetchedAt else { return }
        let snapshot = LibrarySnapshot(items: Array(items.prefix(Self.diskItemLimit)), total: total, fetchedAt: fetchedAt)
        await disk.write(snapshot, for: key)
    }

    /// 用新取到的开头替换列表开头，并尽量保留后面已经加载的部分，这样校验时滚动位置不会丢。
    /// 新数据的最后一条在旧列表里找得到，才说明两段能接上；总数变少时后面可能混着已删除的条目，只留新数据。
    nonisolated static func merge(cached: [EmbyItem], cachedTotal: Int?, fresh: [EmbyItem], freshTotal: Int) -> [EmbyItem] {
        guard cached.count > fresh.count, freshTotal >= cachedTotal ?? 0,
              let last = fresh.last, let joint = cached.firstIndex(where: { $0.id == last.id }) else { return fresh }
        let known = Set(fresh.map(\.id))
        return fresh + cached[(joint + 1)...].filter { !known.contains($0.id) }
    }
}

/// 全 App 共用的片目缓存。列表对象常驻内存，页面销毁后再进入可以立刻显示。
@MainActor
public final class LibraryStore {
    private let disk: LibraryDiskCache
    private let now: @Sendable () -> Date
    private var lists: [LibraryListKey: LibraryList] = [:]

    public convenience init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.init(directory: caches.appendingPathComponent("app.elenglish/Libraries", isDirectory: true))
    }

    public init(directory: URL, now: @escaping @Sendable () -> Date = { .now }) {
        disk = LibraryDiskCache(directory: directory)
        self.now = now
    }

    public func list(for key: LibraryListKey, client: EmbyClient) -> LibraryList {
        if let list = lists[key] {
            // 重新登录后令牌会变，身份相同的列表要换用新客户端。
            list.client = client
            return list
        }
        let list = LibraryList(key: key, client: client, disk: disk, now: now)
        lists[key] = list
        return list
    }

    public func cachedLibraries(serverID: String) -> [EmbyItem] {
        disk.readLibraries(serverID: serverID)
    }

    public func saveLibraries(_ libraries: [EmbyItem], serverID: String) {
        Task { [disk] in await disk.writeLibraries(libraries, serverID: serverID) }
    }

    /// 手动刷新服务器后，这台服务器的列表下次出现时都要重新校验。
    public func markStale(serverID: String) {
        for (key, list) in lists where key.serverID == serverID { list.markStale() }
    }

    public func removeServer(_ serverID: String) async {
        lists = lists.filter { $0.key.serverID != serverID }
        await disk.removeServer(serverID)
    }
}
