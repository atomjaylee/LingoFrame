import Foundation

/// 登录成功后保存的账号信息。accessToken 是敏感信息，只能存进 CredentialStore。
public struct EmbyAccount: Hashable, Codable, Sendable {
    public var serverURL: URL
    public var serverID: String?
    public var serverName: String?
    public var userID: String
    public var userName: String
    public var accessToken: String

    public init(serverURL: URL, serverID: String?, serverName: String?, userID: String, userName: String,
                accessToken: String) {
        self.serverURL = serverURL
        self.serverID = serverID
        self.serverName = serverName
        self.userID = userID
        self.userName = userName
        self.accessToken = accessToken
    }
}

/// 连接和登录：探测服务器地址、用户名密码登录。
public struct EmbyConnector: Sendable {
    let identity: ClientIdentity
    let session: URLSession

    public init(identity: ClientIdentity, session: URLSession = .shared) {
        self.identity = identity
        self.session = session
    }

    /// 把用户输入的地址规范化：补 http://、去掉末尾斜杠。
    public static func normalize(_ address: String) throws -> URL {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw EmbyError.invalidAddress }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { throw EmbyError.invalidAddress }
        return url
    }

    /// 探测服务器。有些部署需要 /emby 前缀，两种都试。返回实际可用的根地址。
    public func probe(_ address: String) async throws -> (url: URL, info: ServerInfo) {
        let base = try Self.normalize(address)
        var candidates = [base]
        if !base.path.lowercased().hasSuffix("/emby") { candidates.append(base.appendingPathComponent("emby")) }
        var lastError: Error = EmbyError.notAnEmbyServer
        for candidate in candidates {
            do {
                let info: ServerInfo = try await Transport(baseURL: candidate, identity: identity, token: nil, session: session)
                    .get("System/Info/Public")
                guard info.id != nil || info.serverName != nil else { continue }
                return (candidate, info)
            } catch let error as EmbyError {
                if case .network = error { throw error }
                lastError = error
            }
        }
        if case .decoding = lastError as? EmbyError { throw EmbyError.notAnEmbyServer }
        if case .http = lastError as? EmbyError { throw EmbyError.notAnEmbyServer }
        throw lastError
    }

    public func login(serverURL: URL, info: ServerInfo, username: String, password: String) async throws -> EmbyAccount {
        struct Body: Encodable { let username: String; let pw: String }
        struct Response: Decodable {
            struct User: Decodable { let id: String; let name: String? }
            let user: User
            let accessToken: String
            let serverId: String?
        }
        let response: Response = try await Transport(baseURL: serverURL, identity: identity, token: nil, session: session)
            .post("Users/AuthenticateByName", body: Body(username: username, pw: password))
        return EmbyAccount(serverURL: serverURL, serverID: response.serverId ?? info.id, serverName: info.serverName,
                           userID: response.user.id, userName: response.user.name ?? username,
                           accessToken: response.accessToken)
    }
}

/// 登录后的 Emby 客户端。值类型、无状态，可以在任意线程使用。
public struct EmbyClient: Sendable {
    public let account: EmbyAccount
    let transport: Transport

    public init(account: EmbyAccount, identity: ClientIdentity, session: URLSession = .shared) {
        self.account = account
        transport = Transport(baseURL: account.serverURL, identity: identity, token: account.accessToken, session: session)
    }

    /// 播放和预热使用同一身份，不携带接口认证头到媒体重定向地址。
    public var playbackHTTPHeaders: [String: String] { ["User-Agent": transport.identity.userAgent] }

    private var user: String { "Users/\(account.userID)" }
    static let listFields = "PrimaryImageAspectRatio,ProductionYear,Overview,PremiereDate,RunTimeTicks,Genres,OfficialRating,CommunityRating,ProviderIds"

    // MARK: 用户与媒体库

    /// 验证令牌是否仍然有效。
    public func validate() async throws {
        let _: EmbyItemLike = try await transport.get(user)
    }

    public func views() async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("\(user)/Views")
        return page.items
    }

    public func resumeItems(limit: Int = 24) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("\(user)/Items/Resume", [
            "Limit": "\(limit)", "MediaTypes": "Video", "Fields": Self.listFields,
            "EnableUserData": "true", "ImageTypeLimit": "1", "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
        return page.items
    }

    public func nextUp(limit: Int = 24, seriesID: String? = nil) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("Shows/NextUp", [
            "UserId": account.userID, "Limit": "\(limit)", "SeriesId": seriesID, "Fields": Self.listFields,
            "EnableUserData": "true", "ImageTypeLimit": "1", "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
        return page.items
    }

    public func latest(in parentID: String, limit: Int = 24) async throws -> [EmbyItem] {
        try await transport.get("\(user)/Items/Latest", [
            "ParentId": parentID, "Limit": "\(limit)", "Fields": Self.listFields,
            "EnableUserData": "true", "ImageTypeLimit": "1", "EnableImageTypes": "Primary,Backdrop,Thumb",
        ])
    }

    public enum Sort: String, Sendable, CaseIterable {
        case name = "SortName"
        case dateAdded = "DateCreated"
        case premiereDate = "PremiereDate"
        case rating = "CommunityRating"

        public var title: String {
            switch self {
            case .name: "名称"
            case .dateAdded: "加入时间"
            case .premiereDate: "上映时间"
            case .rating: "评分"
            }
        }
    }

    public func items(in parentID: String, types: [String] = ["Movie", "Series"], sort: Sort = .name,
                      descending: Bool = false, start: Int = 0, limit: Int = 60) async throws -> ItemsPage {
        try await transport.get("\(user)/Items", [
            "ParentId": parentID, "Recursive": "true", "IncludeItemTypes": types.joined(separator: ","),
            "SortBy": sort == .name ? "SortName" : "\(sort.rawValue),SortName",
            "SortOrder": descending ? "Descending" : "Ascending",
            "StartIndex": "\(start)", "Limit": "\(limit)", "Fields": Self.listFields,
            "EnableUserData": "true", "ImageTypeLimit": "1", "EnableImageTypes": "Primary,Backdrop,Thumb",
            "EnableTotalRecordCount": "true",
        ])
    }

    /// 一个媒体库里全部电影和剧集的精简信息（只要编号和外部编号），用来把资源库和 TMDB 推荐对上号。
    public func catalog(in parentID: String) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("\(user)/Items", [
            "ParentId": parentID, "Recursive": "true", "IncludeItemTypes": "Movie,Series",
            "Fields": "ProviderIds,ProductionYear", "EnableImages": "false", "EnableUserData": "true",
            "Limit": "20000",
        ])
        return page.items
    }

    public func search(_ term: String, limit: Int = 40) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("\(user)/Items", [
            "SearchTerm": term, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode",
            "Limit": "\(limit)", "Fields": Self.listFields, "EnableUserData": "true", "ImageTypeLimit": "1",
        ])
        return page.items
    }

    public func item(_ id: String) async throws -> EmbyItem {
        try await transport.get("\(user)/Items/\(id)", ["Fields": "MediaSources,MediaStreams,Overview,Genres,ProviderIds"])
    }

    public func seasons(of seriesID: String) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("Shows/\(seriesID)/Seasons", [
            "UserId": account.userID, "Fields": "PrimaryImageAspectRatio", "EnableUserData": "true",
        ])
        return page.items
    }

    public func episodes(of seriesID: String, season seasonID: String?) async throws -> [EmbyItem] {
        let page: ItemsPage = try await transport.get("Shows/\(seriesID)/Episodes", [
            "UserId": account.userID, "SeasonId": seasonID, "Fields": "Overview,PrimaryImageAspectRatio,RunTimeTicks",
            "EnableUserData": "true", "ImageTypeLimit": "1", "EnableImageTypes": "Primary,Thumb",
        ])
        return page.items
    }

    public func setPlayed(_ played: Bool, itemID: String) async throws {
        if played {
            try await transport.postIgnoringResult("\(user)/PlayedItems/\(itemID)", body: Optional<Empty>.none)
        } else {
            try await transport.delete("\(user)/PlayedItems/\(itemID)")
        }
    }

    // MARK: 图片

    /// 图片地址。剧集单集没有横图时会回退到所属剧的背景图。图片接口不需要令牌。
    public func imageURL(for item: EmbyItem, type: ImageType, maxWidth: Int) -> URL? {
        typealias Target = (id: String, tag: String, path: String)
        func target(_ id: String?, _ tag: String?, _ path: String) -> Target? {
            guard let id, let tag else { return nil }
            return (id, tag, path)
        }
        let primary = target(item.id, item.imageTag(.primary), "Primary")
            ?? target(item.seriesId, item.seriesPrimaryImageTag, "Primary")
        let backdrop = target(item.id, item.backdropImageTags?.first, "Backdrop/0")
            ?? target(item.parentBackdropItemId, item.parentBackdropImageTags?.first, "Backdrop/0")
        let resolved: Target? = switch type {
        case .primary: primary
        case .backdrop: backdrop
        case .thumb:
            target(item.id, item.imageTag(.thumb), "Thumb")
                ?? target(item.parentThumbItemId, item.parentThumbImageTag, "Thumb")
                ?? (item.kind == .episode ? primary : nil)
                ?? backdrop
        case .logo: target(item.id, item.imageTag(.logo), "Logo")
        }
        guard let resolved else { return nil }
        return transport.url("Items/\(resolved.id)/Images/\(resolved.path)",
                             ["maxWidth": "\(maxWidth)", "tag": resolved.tag, "quality": "90"])
    }

    // MARK: 播放

    public func playbackInfo(itemID: String, startSeconds: Double? = nil, mediaSourceID: String? = nil,
                             audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
                             profile: DeviceProfile) async throws -> PlaybackInfoResponse {
        struct Body: Encodable {
            let deviceProfile: DeviceProfile
            let mediaSourceId: String?
            let audioStreamIndex: Int?
            let subtitleStreamIndex: Int?
        }
        return try await transport.post("Items/\(itemID)/PlaybackInfo", [
            "UserId": account.userID, "IsPlayback": "true", "AutoOpenLiveStream": "true",
            "StartTimeTicks": startSeconds.map { "\(Ticks.from(seconds: $0))" },
            "MaxStreamingBitrate": "\(profile.maxStreamingBitrate)",
            "MediaSourceId": mediaSourceID,
            "AudioStreamIndex": audioStreamIndex.map(String.init),
            "SubtitleStreamIndex": subtitleStreamIndex.map(String.init),
        ], body: Body(deviceProfile: profile, mediaSourceId: mediaSourceID, audioStreamIndex: audioStreamIndex,
                      subtitleStreamIndex: subtitleStreamIndex))
    }

    /// 下载一条字幕的文本。内嵌和外挂的文本字幕（SRT、ASS、VTT 等）都由服务器统一转成 SRT。
    /// 图形字幕（PGS、VobSub）没有文本，不能用这个接口。
    public func subtitleText(itemID: String, mediaSourceID: String, streamIndex: Int) async throws -> String {
        let url = transport.url("Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.srt")
        let data = try await transport.raw(method: "GET", url: url, body: nil)
        return String(decoding: data, as: UTF8.self)
    }

    /// 根据 PlaybackInfo 选出播放地址：能直接播就直接播原文件，否则用服务器给的转码地址。
    public func resolveStream(itemID: String, info: PlaybackInfoResponse, profile: DeviceProfile,
                              mediaSourceID: String? = nil) throws -> ResolvedStream {
        guard let source = info.mediaSources.first(where: { $0.id == mediaSourceID }) ?? info.mediaSources.first else {
            throw EmbyError.noPlayableSource
        }
        if source.supportsDirectPlay ?? false, profile.allowsDirectPlay(container: source.container) {
            let ext = source.container.map { ".\($0.lowercased())" } ?? ""
            let url = transport.url("Videos/\(itemID)/stream\(ext)", [
                "Static": "true", "MediaSourceId": source.id, "PlaySessionId": info.playSessionId,
                "DeviceId": transport.identity.deviceID, "api_key": account.accessToken,
            ])
            return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: info.playSessionId)
        }
        guard let path = source.transcodingUrl,
              var components = URLComponents(string: account.serverURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path))
        else {
            throw EmbyError.serverConversionUnavailable(container: source.container?.uppercased() ?? "当前格式")
        }
        var query = components.queryItems ?? []
        if !query.contains(where: { $0.name.lowercased() == "api_key" }) {
            query.append(URLQueryItem(name: "api_key", value: account.accessToken))
        }
        components.queryItems = query
        guard let url = components.url else { throw EmbyError.noPlayableSource }
        return ResolvedStream(url: url, method: Self.classify(transcodeQuery: query, source: source), mediaSource: source,
                              playSessionID: info.playSessionId)
    }

    /// 原文件直放地址。客户端自己处理容器和解码，不依赖 Emby 的转码或转封装权限。
    public func resolveOriginalStream(itemID: String, info: PlaybackInfoResponse,
                                      mediaSourceID: String? = nil) throws -> ResolvedStream {
        guard let source = info.mediaSources.first(where: { $0.id == mediaSourceID }) ?? info.mediaSources.first else {
            throw EmbyError.noPlayableSource
        }
        let ext = source.container.map { ".\($0.lowercased())" } ?? ""
        let url = transport.url("Videos/\(itemID)/stream\(ext)", [
            "Static": "true", "MediaSourceId": source.id, "api_key": account.accessToken,
        ])
        return ResolvedStream(url: url, method: .directPlay, mediaSource: source, playSessionID: info.playSessionId)
    }

    /// 根据转码原因判断服务器是「只转封装」还是「真正转码」：原因只和容器有关时，视频和音频都是原样复制。
    static func classify(transcodeQuery query: [URLQueryItem], source: MediaSourceInfo) -> PlayMethod {
        let reasons = query.first { $0.name.lowercased() == "transcodereasons" }?.value?
            .split(separator: ",").map(String.init) ?? []
        if reasons.isEmpty { return source.supportsDirectStream == true ? .directStream : .transcode }
        return reasons.allSatisfy { $0.contains("Container") } ? .directStream : .transcode
    }

    public func reportPlaybackStart(_ report: PlaybackReport) async throws {
        try await transport.postIgnoringResult("Sessions/Playing", body: report)
    }

    public func reportPlaybackProgress(_ report: PlaybackReport) async throws {
        try await transport.postIgnoringResult("Sessions/Playing/Progress", body: report)
    }

    public func reportPlaybackStopped(_ report: PlaybackReport) async throws {
        try await transport.postIgnoringResult("Sessions/Playing/Stopped", body: report)
    }

    /// 停止服务器端的转码进程，切换或关闭播放时调用，避免服务器空转。
    public func stopEncoding(playSessionID: String) async throws {
        try await transport.delete("Videos/ActiveEncodings", [
            "DeviceId": transport.identity.deviceID, "PlaySessionId": playSessionID,
        ])
    }
}

/// validate() 只关心请求是否成功，用一个最宽松的类型接住返回值。
private struct EmbyItemLike: Decodable {}
