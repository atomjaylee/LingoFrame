import AppKit
import DesignSystem
import LearningCore
import MediaServerKit
import Observation
import PlaybackKit
import SwiftUI
import TMDBKit
import Workspace

/// 一个已添加的 Emby 服务器：账号、客户端、在线状态、媒体库，以及用来和 TMDB 对号的片目。
@MainActor
@Observable
final class ServerConnection: Identifiable {
    let account: EmbyAccount
    let client: EmbyClient
    private(set) var state: StatusDot.State = .idle
    private(set) var libraries: [EmbyItem] = []
    private(set) var catalog: [EmbyItem] = []
    private(set) var catalogByTMDB: [TMDBRef: EmbyItem] = [:]
    private(set) var errorMessage: String?
    private(set) var lastRefreshed: Date?

    nonisolated var id: String { Self.id(for: account) }
    nonisolated static func id(for account: EmbyAccount) -> String { "\(account.userID)@\(account.serverURL.absoluteString)" }

    var name: String { account.serverName ?? account.serverURL.host() ?? "Emby" }
    var movieCount: Int { catalog.filter { $0.kind == .movie }.count }
    var seriesCount: Int { catalog.filter { $0.kind == .series }.count }

    init(account: EmbyAccount, identity: ClientIdentity) {
        self.account = account
        client = EmbyClient(account: account, identity: identity)
    }

    /// 检查令牌、读取媒体库和片目。令牌失效时返回 false，由调用方决定是否移除账号。
    @discardableResult
    func refresh() async -> Bool {
        state = .idle
        do {
            try await client.validate()
            let views = try await client.views().filter { ["movies", "tvshows", "mixed", nil].contains($0.collectionType) }
            var all: [EmbyItem] = []
            for lib in views { all += (try? await client.catalog(in: lib.id)) ?? [] }
            var index: [TMDBRef: EmbyItem] = [:]
            index.reserveCapacity(all.count)
            for item in all {
                if let id = item.tmdbID {
                    let ref = TMDBRef(type: item.kind == .series ? .tv : .movie, id: id)
                    if index[ref] == nil { index[ref] = item }
                }
            }
            libraries = views
            catalog = all
            catalogByTMDB = index
            state = .online
            errorMessage = nil
            lastRefreshed = .now
            return true
        } catch EmbyError.unauthorized {
            state = .offline
            errorMessage = "登录已过期，请删除后重新添加"
            return false
        } catch {
            state = .offline
            errorMessage = error.localizedDescription
            return true
        }
    }
}

/// 资源库里的一部作品（哪台服务器、哪个条目）。
struct LibraryMatch: Hashable {
    var serverID: String
    var item: EmbyItem
}

/// 详情页提前准备好的播放会话。真正播放时复用片源信息和预热字节。
struct PreparedPlayback {
    var serverID: String
    var item: EmbyItem
    var stream: ResolvedStream
    var startAt: Double?
    var isPrewarmed: Bool
}

@MainActor
@Observable
final class AppModel {
    let identity: ClientIdentity
    /// 全 App 唯一的播放内核；窗口切换和换片不重建原生显示管线。
    let playbackEngine = try! NativePlayerEngine()
    let themeStore = ThemeStore()
    let layoutStore: LayoutStore
    let panels = PanelRegistry()
    let recommendations = RecommendationStore()
    /// 快捷键表：学习层的默认绑定 + 播放器专用绑定。以后用户自定义的绑定追加在最后。
    let bindings = Bindings.defaults.overlaid(with: PlayerCommands.extraBindings)

    private(set) var servers: [ServerConnection] = []
    private(set) var tmdb: TMDBClient?
    var tmdbConfig: TMDBConfig {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(tmdbConfig), forKey: "tmdb.config")
            rebuildTMDB()
        }
    }
    /// 最近激活的播放会话，独立窗口里的面板通过它拿到播放数据。
    var activeSession: PlaybackSession?
    /// 单播放窗口当前要加载的请求；新请求复用同一个窗口和同一个播放内核。
    var playRequest: PlayRequest?
    var playRequestRevision: UInt64 = 0
    /// 每次停止上报送达后递增；首页、资源库和详情页把它放进加载任务的 id，关掉播放器回来就是最新进度。
    private(set) var watchProgressRevision: UInt64 = 0
    @ObservationIgnored private var preparedPlayback: PreparedPlayback?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var preparationGeneration: UInt64 = 0

    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private let tmdbSecret: any SecretStore
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ELEnglish", isDirectory: true)
        layoutStore = LayoutStore(directory: support.appendingPathComponent("Layouts", isDirectory: true))

        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: "device.id") ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: "device.id")
            return id
        }()
        identity = ClientIdentity(appName: "Pixon", appVersion: Self.appVersion,
                                  deviceName: Host.current().localizedName ?? "Mac", deviceID: deviceID)

        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        if CredentialStoragePolicy.usesPrivateFiles(isDebugBuild: isDebugBuild) {
            // 本机临时签名的版本共用原有私有文件，切换构建方式时不会丢失账号和密钥。
            accountStore = AccountStore(secrets: FileSecretStore(url: support.appendingPathComponent("dev-account.json")))
            tmdbSecret = FileSecretStore(url: support.appendingPathComponent("dev-tmdb.txt"))
        } else {
            accountStore = AccountStore(secrets: KeychainSecretStore(service: "app.elenglish.mac", account: "emby.accounts"))
            tmdbSecret = KeychainSecretStore(service: "app.elenglish.mac", account: "tmdb.token")
        }

        tmdbConfig = defaults.data(forKey: "tmdb.config").flatMap { try? JSONDecoder().decode(TMDBConfig.self, from: $0) } ?? .default
        servers = accountStore.load().map { ServerConnection(account: $0, identity: identity) }
        rebuildTMDB()

        PlayerPanels.register(in: panels)
        PlaybackSession.restoreAudio(of: playbackEngine)
        #if DEBUG
        DebugTools.install()
        #endif
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [layoutStore] _ in
            MainActor.assumeIsolated { layoutStore.flush() }
        }
        NotificationCenter.default.addObserver(forName: PlaybackSession.watchProgressDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchProgressRevision &+= 1 }
        }
    }

    // MARK: 外观

    /// 按设置统一 App 的外观。SwiftUI 的 preferredColorScheme 在多窗口下不总能生效，所以在 AppKit 层也设置一次。
    func applyAppearance() {
        switch themeStore.appearance {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    // MARK: 资源库（Emby 服务器）

    var connector: EmbyConnector { EmbyConnector(identity: identity) }

    func server(_ id: String?) -> ServerConnection? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    /// 详情页后台预热：并行读取条目和播放信息，并预取片源开头字节。
    func preparePlayback(serverID: String, itemID: String) async {
        guard activeSession == nil, let client = server(serverID)?.client.forPreloading() else { return }
        prewarmTask?.cancel()
        preparedPlayback = nil
        preparationGeneration &+= 1
        let generation = preparationGeneration
        do {
            async let itemRequest = client.item(itemID)
            async let infoRequest = client.playbackInfo(itemID: itemID, profile: .native)
            let (item, info) = try await (itemRequest, infoRequest)
            try Task.checkCancellation()
            guard activeSession == nil, generation == preparationGeneration else { return }
            let stream = try client.resolveOriginalStream(itemID: itemID, info: info)
            let start = item.resumePositionSeconds
            preparedPlayback = PreparedPlayback(serverID: serverID, item: item, stream: stream,
                                                startAt: start, isPrewarmed: false)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, generation == self.preparationGeneration, self.activeSession == nil else { return }
                await PlaybackSession.prefetchSubtitles(client: client, itemID: item.id, source: stream.mediaSource)
            }
            // 不绑定详情页 View 的生命周期：用户点击播放导致页面消失时，已经开始的预热仍能完成。
            prewarmTask = Task.detached(priority: .userInitiated) {
                _ = await NativePlayerEngine.prewarm(url: stream.url, httpHeaders: client.playbackHTTPHeaders,
                                                     bitrate: stream.mediaSource.bitrate)
            }
        } catch is CancellationError {
            return
        } catch {
            // 预热失败不影响正常播放，点击后仍会走完整加载。
            if generation == preparationGeneration { preparedPlayback = nil }
        }
    }

    func takePreparedPlayback(serverID: String, itemID: String, resume _: Bool) -> PreparedPlayback? {
        guard var preparedPlayback else { return nil }
        guard preparedPlayback.serverID == serverID,
              preparedPlayback.item.id == itemID else {
            prewarmTask?.cancel()
            prewarmTask = nil
            self.preparedPlayback = nil
            return nil
        }
        preparedPlayback.isPrewarmed = NativePlayerEngine.isPrewarmed(url: preparedPlayback.stream.url)
        if !preparedPlayback.isPrewarmed { prewarmTask?.cancel() }
        prewarmTask = nil
        self.preparedPlayback = nil
        return preparedPlayback
    }

    func showPlayer(_ request: PlayRequest, using _: OpenWindowAction) {
        // 详情页预热请求可能还在网络途中；先失效，避免它回来后覆盖用户刚点开的集数。
        preparationGeneration &+= 1
        if case .emby(let serverID, let itemID, _) = request,
           preparedPlayback?.serverID == serverID, preparedPlayback?.item.id == itemID {
            // 匹配的预热由播放窗口接管。
        } else {
            prewarmTask?.cancel()
            prewarmTask = nil
            preparedPlayback = nil
        }
        playRequest = request
        playRequestRevision &+= 1
        PlayerWindowController.shared.show(model: self)
    }

    /// 启动时刷新所有服务器，并把片目和 TMDB 对上号。
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { await server.refresh() } }
        }
    }

    func addServer(_ account: EmbyAccount) async {
        let connection = ServerConnection(account: account, identity: identity)
        servers.removeAll { $0.id == connection.id }
        servers.append(connection)
        persistAccounts()
        await connection.refresh()
    }

    func removeServer(_ id: String) {
        servers.removeAll { $0.id == id }
        persistAccounts()
    }

    private func persistAccounts() {
        try? accountStore.save(servers.map(\.account))
    }

    /// 资源库里有没有这部作品（按 TMDB 编号对号）。
    func match(_ ref: TMDBRef) -> LibraryMatch? {
        for server in servers {
            if let item = server.catalogByTMDB[ref] {
                return LibraryMatch(serverID: server.id, item: item)
            }
        }
        return nil
    }

    // MARK: TMDB

    var tmdbToken: String {
        get {
            if let saved = tmdbSecret.read().flatMap({ String(data: $0, encoding: .utf8) })?
                .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
                return saved
            }
            return ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { tmdbSecret.delete() } else { try? tmdbSecret.write(Data(trimmed.utf8)) }
            rebuildTMDB()
        }
    }

    /// 是否已经填写 TMDB 密钥。
    var hasCustomTMDBToken: Bool {
        tmdbSecret.read().flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func rebuildTMDB() {
        let token = tmdbToken
        tmdb = token.isEmpty ? nil : TMDBClient(token: token, config: tmdbConfig)
        recommendations.reset()
    }
}
