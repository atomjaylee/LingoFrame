import Foundation
import Synchronization
import Testing
@testable import MediaServerKit

private let identity = ClientIdentity(appName: "ELEnglish", appVersion: "0.1.0", deviceName: "Test Mac", deviceID: "dev-1")

private func item(_ id: String) -> EmbyItem {
    EmbyItem(id: id, name: nil, type: nil)
}

private func ids(_ range: ClosedRange<Int>) -> [String] {
    range.map { "i\($0)" }
}

/// 假的媒体库服务器：列表可变、记录请求，用 fail 模拟离线。
private final class FakeServer: Sendable {
    struct State {
        var ids: [String] = []
        var played: Set<String> = []
        var fail = false
        /// 服务器报的总数比实际多几条，模拟统计和列表不一致。
        var phantomCount = 0
        var limits: [Int] = []
    }

    final class LockedState: Sendable {
        private let mutex: Mutex<State>
        init(_ state: State) { mutex = Mutex(state) }
        func withLock<Result: Sendable>(_ body: (inout State) -> Result) -> Result {
            mutex.withLock { body(&$0) }
        }
    }

    let state: LockedState
    let client: EmbyClient

    init(host: String, ids: [String]) {
        let state = LockedState(State(ids: ids))
        self.state = state
        let session = StubProtocol.session(host: host) { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let number = { (name: String) in Int(query.first { $0.name == name }?.value ?? "") ?? 0 }
            let start = number("StartIndex"), limit = number("Limit")
            return state.withLock { state in
                state.limits.append(limit)
                if state.fail { return .json("{}", status: 500) }
                let rows = state.ids.dropFirst(start).prefix(limit).map { id in
                    #"{"Id":"\#(id)","UserData":{"Played":\#(state.played.contains(id))}}"#
                }
                return .json(#"{"Items":[\#(rows.joined(separator: ","))],"TotalRecordCount":\#(state.ids.count + state.phantomCount)}"#)
            }
        }
        let account = EmbyAccount(serverURL: URL(string: "http://\(host):8096")!, serverID: "s1", serverName: "Home",
                                  userID: "u1", userName: "atom", accessToken: "secret-token")
        client = EmbyClient(account: account, identity: identity, session: session)
    }

    var requests: Int { state.withLock { $0.limits.count } }
}

private final class Clock: Sendable {
    let date = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

private let key = LibraryListKey(serverID: "u1@home", libraryID: "lib", sort: .dateAdded, descending: true)

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
}

@MainActor private func store(_ directory: URL, _ clock: Clock) -> LibraryStore {
    LibraryStore(directory: directory, now: { clock.now })
}

@Test @MainActor func freshListDoesNotRefetchWhenPageReappears() async {
    let server = FakeServer(host: "fresh.test", ids: ids(1...3))
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    await list.revalidate()
    await list.revalidate()
    #expect(list.items.map(\.id) == ids(1...3))
    #expect(server.requests == 1)
}

@Test @MainActor func storeSharesOneListAcrossPages() async {
    let server = FakeServer(host: "shared.test", ids: ids(1...3))
    let store = store(temporaryDirectory(), Clock())
    await store.list(for: key, client: server.client).revalidate()
    #expect(store.list(for: key, client: server.client).items.count == 3)
    #expect(server.requests == 1)
}

@Test @MainActor func staleRevalidationKeepsLoadedPagesAndPicksUpNewHead() async {
    let server = FakeServer(host: "stale.test", ids: ids(1...150))
    let clock = Clock()
    let list = store(temporaryDirectory(), clock).list(for: key, client: server.client)
    await list.revalidate()
    await list.loadMore()
    #expect(list.items.count == 120)

    server.state.withLock { $0.ids.insert("new", at: 0) }
    clock.advance(LibraryList.staleAfter)
    await list.revalidate()
    #expect(list.items.first?.id == "new")
    #expect(list.items.count == 121)
    #expect(Set(list.items.map(\.id)).count == 121)
    #expect(list.total == 151)
}

@Test @MainActor func deletionDropsPagesThatMayBeStale() async {
    let server = FakeServer(host: "deleted.test", ids: ids(1...150))
    let clock = Clock()
    let list = store(temporaryDirectory(), clock).list(for: key, client: server.client)
    await list.revalidate()
    await list.loadMore()

    server.state.withLock { $0.ids.remove(at: 100) }
    clock.advance(LibraryList.staleAfter)
    await list.revalidate()
    #expect(list.items.count == LibraryList.pageSize)
    #expect(list.hasMore)
}

@Test @MainActor func failedRevalidationKeepsCachedItemsWithoutError() async {
    let server = FakeServer(host: "offline.test", ids: ids(1...3))
    let clock = Clock()
    let list = store(temporaryDirectory(), clock).list(for: key, client: server.client)
    await list.revalidate()

    server.state.withLock { $0.fail = true }
    clock.advance(LibraryList.staleAfter)
    await list.revalidate()
    #expect(list.items.count == 3)
    #expect(list.errorMessage == nil)
}

@Test @MainActor func firstLoadFailureIsReportedAndRetried() async {
    let server = FakeServer(host: "first-failure.test", ids: ids(1...3))
    server.state.withLock { $0.fail = true }
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    await list.revalidate()
    #expect(list.errorMessage != nil)
    #expect(!list.isConfirmedEmpty)

    server.state.withLock { $0.fail = false }
    await list.revalidate()
    #expect(list.items.count == 3)
    #expect(list.errorMessage == nil)
}

@Test @MainActor func emptyLibraryIsOnlyConfirmedAfterLoading() async {
    let server = FakeServer(host: "empty.test", ids: [])
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    #expect(list.isLoadingFirstPage)
    #expect(!list.isConfirmedEmpty)
    await list.revalidate()
    #expect(list.isConfirmedEmpty)
}

@Test @MainActor func watchProgressChangeRefreshesLoadedItemsEvenWhenFresh() async {
    let server = FakeServer(host: "progress.test", ids: ids(1...150))
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    await list.revalidate(progressRevision: 1)
    await list.loadMore()

    server.state.withLock { $0.played.insert("i100") }
    await list.revalidate(progressRevision: 1)
    #expect(list.items[99].isPlayed == false)

    await list.revalidate(progressRevision: 2)
    #expect(list.items[99].isPlayed == true)
    #expect(list.items.count == 120)
    #expect(server.state.withLock { $0.limits.last } == 120)
}

@Test @MainActor func manualRefreshBypassesFreshness() async {
    let server = FakeServer(host: "manual.test", ids: ids(1...3))
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    await list.revalidate()
    server.state.withLock { $0.ids.append("new") }
    await list.refresh()
    #expect(list.items.count == 4)
}

@Test @MainActor func coldStartRestoresFromDiskWithoutNetworkWhileFresh() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = FakeServer(host: "cold.test", ids: ids(1...3))
    let clock = Clock()
    await store(directory, clock).list(for: key, client: server.client).revalidate()

    server.state.withLock { $0.fail = true }
    let restored = store(directory, clock).list(for: key, client: server.client)
    await restored.revalidate()
    #expect(restored.items.map(\.id) == ids(1...3))
    #expect(restored.total == 3)
    #expect(server.requests == 1)

    clock.advance(LibraryList.staleAfter)
    let offline = store(directory, clock).list(for: key, client: server.client)
    await offline.revalidate()
    #expect(offline.items.count == 3)
    #expect(offline.errorMessage == nil)
    #expect(server.requests > 1)
}

@Test @MainActor func diskKeepsOnlyTheFirstItemsAndPagingContinues() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = FakeServer(host: "cap.test", ids: ids(1...400))
    let clock = Clock()
    let list = store(directory, clock).list(for: key, client: server.client)
    await list.revalidate()
    while list.items.count < 360 { await list.loadMore() }

    let restored = store(directory, clock).list(for: key, client: server.client)
    await restored.revalidate()
    #expect(restored.items.count == LibraryList.diskItemLimit)
    #expect(restored.hasMore)
    await restored.loadMore()
    #expect(restored.items.count == 360)
}

@Test @MainActor func pagingStopsWhenServerOnlyReturnsDuplicates() async {
    let server = FakeServer(host: "duplicates.test", ids: ids(1...3))
    let list = store(temporaryDirectory(), Clock()).list(for: key, client: server.client)
    server.state.withLock { $0.phantomCount = 1 }
    await list.revalidate()
    #expect(list.hasMore)
    await list.loadMore()
    #expect(!list.hasMore)
    let requests = server.requests
    await list.loadMore()
    #expect(server.requests == requests)
}

@Test @MainActor func removingServerClearsMemoryAndDisk() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = FakeServer(host: "remove.test", ids: ids(1...3))
    let clock = Clock()
    let store = store(directory, clock)
    await store.list(for: key, client: server.client).revalidate()
    await store.removeServer(key.serverID)

    server.state.withLock { $0.ids = [] }
    let list = store.list(for: key, client: server.client)
    await list.revalidate()
    #expect(list.items.isEmpty)
    #expect(server.requests == 2)
}

@Test func librariesSurviveRestart() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = LibraryDiskCache(directory: directory)
    await disk.writeLibraries([item("movies")], serverID: "u1@home")
    #expect(LibraryDiskCache(directory: directory).readLibraries(serverID: "u1@home").map(\.id) == ["movies"])
    #expect(LibraryDiskCache(directory: directory).readLibraries(serverID: "other").isEmpty)
}

@Test func mergeKeepsTailOnlyWhenPagesConnect() {
    let cached = ids(1...6).map(item)
    #expect(LibraryList.merge(cached: cached, cachedTotal: 6, fresh: ids(1...3).map(item), freshTotal: 6).map(\.id) == ids(1...6))
    // 新数据和旧列表接不上：后面的条目位置已经不可信。
    #expect(LibraryList.merge(cached: cached, cachedTotal: 6, fresh: ["x", "y"].map(item), freshTotal: 8).map(\.id) == ["x", "y"])
    #expect(LibraryList.merge(cached: cached, cachedTotal: 6, fresh: [], freshTotal: 0).isEmpty)
}

@Test func imageRequestsCarryTheServerToken() {
    let headers = FakeServer(host: "image-token.test", ids: []).client.imageHTTPHeaders
    #expect(headers["X-Emby-Token"] == "secret-token")
    #expect(headers["X-Emby-Authorization"]?.contains(#"Token="secret-token""#) == true)
}
