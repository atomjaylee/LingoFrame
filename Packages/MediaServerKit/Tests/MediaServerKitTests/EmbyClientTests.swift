import Foundation
import Testing
@testable import MediaServerKit

private let identity = ClientIdentity(appName: "ELEnglish", appVersion: "0.1.0", deviceName: "Test Mac", deviceID: "dev-1")

private func account(host: String) -> EmbyAccount {
    EmbyAccount(serverURL: URL(string: "http://\(host):8096")!, serverID: "s1", serverName: "Home",
                userID: "u1", userName: "atom", accessToken: "secret-token")
}

@Test func searchRequestsMoviesAndSeriesWithoutEpisodes() async throws {
    let session = StubProtocol.session(host: "search-types.test") { request, _ in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "SearchTerm" }?.value == "Friends")
        #expect(query.first { $0.name == "IncludeItemTypes" }?.value == "Movie,Series")
        return .json(#"{"Items":[{"Id":"s1","Name":"Friends","Type":"Series"},{"Id":"m1","Name":"Friends Movie","Type":"Movie"}],"TotalRecordCount":2}"#)
    }
    let client = EmbyClient(account: account(host: "search-types.test"), identity: identity, session: session)
    let hits = try await client.search("Friends")
    #expect(hits.map(\.kind) == [.series, .movie])
}

@Test func apiAndSubtitleRequestsUseProductUserAgent() async throws {
    let session = StubProtocol.session(host: "user-agent.test") { request, _ in
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pixon/0.1.0 (macOS)")
        if request.url!.path.contains("/Subtitles/") { return .json("1\n00:00:00,000 --> 00:00:01,000\nHello\n") }
        return .json(#"{"Items":[],"TotalRecordCount":0}"#)
    }
    let client = EmbyClient(account: account(host: "user-agent.test"), identity: identity, session: session)
    #expect(client.playbackHTTPHeaders == ["User-Agent": "Pixon/0.1.0 (macOS)"])
    _ = try await client.resumeItems()
    _ = try await client.subtitleText(itemID: "e1", mediaSourceID: "ms1", streamIndex: 2)
}

@Test func preloadingPrefixesUserAgentWithoutChangingPlaybackIdentity() async throws {
    let session = StubProtocol.session(host: "preloading.test") { request, _ in
        let preloading = request.url!.path.contains("/pre/")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == (preloading ? "pre" : "") + "Pixon/0.1.0 (macOS)")
        let auth = request.value(forHTTPHeaderField: "X-Emby-Authorization")
        #expect(auth?.contains(#"Client="ELEnglish""#) == true)
        #expect(auth?.contains(#"DeviceId="dev-1""#) == true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "secret-token")
        if request.url!.path.contains("/Subtitles/") { return .json("1\n00:00:00,000 --> 00:00:01,000\nHello\n") }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "UserId" }?.value == "u1")
        return .json(#"{"MediaSources":[{"Id":"ms1","Container":"mp4"}],"PlaySessionId":"ps1"}"#)
    }
    let client = EmbyClient(account: account(host: "preloading.test"), identity: identity, session: session)
    let preloading = client.forPreloading()
    #expect(preloading.playbackHTTPHeaders == ["User-Agent": "Pixon/0.1.0 (macOS)"])
    #expect(preloading.forPreloading().playbackHTTPHeaders == preloading.playbackHTTPHeaders)
    _ = try await preloading.playbackInfo(itemID: "pre", profile: .native)
    _ = try await preloading.subtitleText(itemID: "pre", mediaSourceID: "ms1", streamIndex: 2)
    let info = try await client.playbackInfo(itemID: "normal", profile: .native)
    #expect(client.playbackHTTPHeaders == ["User-Agent": "Pixon/0.1.0 (macOS)"])
    #expect(try preloading.resolveOriginalStream(itemID: "i1", info: info).url
        == client.resolveOriginalStream(itemID: "i1", info: info).url)
}

@Test func authorizationHeaderKeepsFieldsAfterUnicodeDeviceName() {
    let unicodeIdentity = ClientIdentity(appName: "ELEnglish", appVersion: "0.1.0",
                                         deviceName: "atom’s Mac Pro", deviceID: "dev-1")
    let header = unicodeIdentity.authorizationHeader(token: nil)
    #expect(header.contains(#"Device="atoms Mac Pro""#))
    #expect(header.contains(#"Version="0.1.0""#))
    #expect(header.unicodeScalars.allSatisfy { $0.isASCII })
}

@Test func normalizesAddresses() throws {
    #expect(try EmbyConnector.normalize(" 192.168.1.5:8096/ ").absoluteString == "http://192.168.1.5:8096")
    #expect(try EmbyConnector.normalize("https://emby.example.com/").absoluteString == "https://emby.example.com")
    #expect(throws: EmbyError.invalidAddress) { try EmbyConnector.normalize("") }
    #expect(throws: EmbyError.invalidAddress) { try EmbyConnector.normalize("ftp://x") }
}

@Test func probeFallsBackToEmbyPrefix() async throws {
    let session = StubProtocol.session(host: "probe.test") { request, _ in
        request.url!.path == "/emby/System/Info/Public"
            ? .json(#"{"ServerName":"Home","Version":"4.8.10.0","Id":"abc"}"#)
            : .json("Not found", status: 404)
    }
    let (url, info) = try await EmbyConnector(identity: identity, session: session).probe("probe.test")
    #expect(url.absoluteString == "http://probe.test/emby")
    #expect(info.serverName == "Home")
    #expect(info.version == "4.8.10.0")
}

@Test func probeRejectsNonEmbyServers() async {
    let session = StubProtocol.session(host: "nginx.test") { _, _ in .json("<html></html>", status: 200) }
    await #expect(throws: EmbyError.notAnEmbyServer) {
        try await EmbyConnector(identity: identity, session: session).probe("nginx.test")
    }
}

@Test func loginSendsCredentialsAndHeaders() async throws {
    let session = StubProtocol.session(host: "login.test") { request, body in
        guard request.url!.path == "/Users/AuthenticateByName", request.httpMethod == "POST",
              let auth = request.value(forHTTPHeaderField: "X-Emby-Authorization"),
              auth.contains(#"DeviceId="dev-1""#), auth.contains(#"Version="0.1.0""#), !auth.contains("Token="),
              let json = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }),
              json == ["Username": "atom", "Pw": "pw"]
        else { return .json("bad request", status: 400) }
        return .json(#"{"User":{"Id":"u1","Name":"atom"},"AccessToken":"tok","ServerId":"s1"}"#)
    }
    let account = try await EmbyConnector(identity: identity, session: session)
        .login(serverURL: URL(string: "http://login.test")!, info: ServerInfo(serverName: "Home"), username: "atom", password: "pw")
    #expect(account.userID == "u1")
    #expect(account.accessToken == "tok")
    #expect(account.serverName == "Home")
}

@Test func wrongPasswordIsUnauthorized() async {
    let session = StubProtocol.session(host: "deny.test") { _, _ in .json("", status: 401) }
    await #expect(throws: EmbyError.unauthorized) {
        try await EmbyConnector(identity: identity, session: session)
            .login(serverURL: URL(string: "http://deny.test")!, info: ServerInfo(), username: "a", password: "b")
    }
}

@Test func decodesItemsAndBuildsImageURLs() async throws {
    let session = StubProtocol.session(host: "items.test") { request, _ in
        guard request.value(forHTTPHeaderField: "X-Emby-Token") == "secret-token",
              request.url!.path == "/Users/u1/Items/Resume" else { return .json("", status: 404) }
        let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "Fields" }?.value ?? ""
        #expect(fields.split(separator: ",").contains("UserDataLastPlayedDate"))
        return .json("""
        {"Items":[{"Id":"e1","Name":"Pilot","Type":"Episode","SeriesId":"s9","SeriesName":"Friends",
          "IndexNumber":1,"ParentIndexNumber":1,"RunTimeTicks":13200000000,
          "ImageTags":{"Primary":"p1"},"ParentBackdropItemId":"s9","ParentBackdropImageTags":["b9"],
          "UserData":{"PlaybackPositionTicks":6600000000,"Played":false,"LastPlayedDate":"2026-11-03T06:00:00.0000000Z"},"UnknownField":123}],
         "TotalRecordCount":1}
        """)
    }
    let client = EmbyClient(account: account(host: "items.test"), identity: identity, session: session)
    let items = try await client.resumeItems()
    let e = try #require(items.first)
    #expect(e.kind == .episode)
    #expect(e.episodeCode == "S01E01")
    #expect(e.progress == 0.5)
    #expect(e.resumePositionSeconds == 660)
    #expect(e.userData?.lastPlayedDate == "2026-11-03T06:00:00.0000000Z")

    let primary = try #require(client.imageURL(for: e, type: .primary, maxWidth: 300))
    #expect(primary.path == "/Items/e1/Images/Primary")
    #expect(primary.query?.contains("tag=p1") == true)
    #expect(primary.query?.contains("api_key") == false)
    let backdrop = try #require(client.imageURL(for: e, type: .backdrop, maxWidth: 1280))
    #expect(backdrop.path == "/Items/s9/Images/Backdrop/0")
}

@Test func resolvesOriginalFilesForNativePlayer() throws {
    let client = EmbyClient(account: account(host: "play.test"), identity: identity)
    let mp4 = PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: "ms1", container: "mp4", supportsDirectPlay: true)],
                                   playSessionId: "ps1")
    let direct = try client.resolveStream(itemID: "i1", info: mp4, profile: .native)
    #expect(direct.method == .directPlay)
    #expect(direct.url.path == "/Videos/i1/stream.mp4")
    let query = Set(direct.url.query!.split(separator: "&").map(String.init))
    #expect(query.isSuperset(of: ["Static=true", "MediaSourceId=ms1", "PlaySessionId=ps1", "api_key=secret-token"]))

    let mkv = PlaybackInfoResponse(mediaSources: [MediaSourceInfo(
        id: "ms2", container: "mkv", supportsDirectPlay: true, supportsDirectStream: true,
        transcodingUrl: "/videos/i2/master.m3u8?MediaSourceId=ms2&VideoCodec=h264&TranscodeReasons=ContainerNotSupported")],
                                   playSessionId: "ps2")
    let directMKV = try client.resolveStream(itemID: "i2", info: mkv, profile: .native)
    #expect(directMKV.method == .directPlay)
    #expect(directMKV.url.path == "/Videos/i2/stream.mkv")

    let original = try client.resolveOriginalStream(itemID: "i2", info: mkv)
    #expect(original.method == .directPlay)
    #expect(original.url.path == "/Videos/i2/stream.mkv")
    #expect(original.url.query?.contains("api_key=secret-token") == true)

    let reasons = [URLQueryItem(name: "TranscodeReasons", value: "ContainerNotSupported,VideoCodecNotSupported")]
    #expect(EmbyClient.classify(transcodeQuery: reasons, source: mkv.mediaSources[0]) == .transcode)

    #expect(throws: EmbyError.noPlayableSource) {
        try client.resolveStream(itemID: "x", info: PlaybackInfoResponse(mediaSources: []), profile: .native)
    }

    let conversionDisabled = PlaybackInfoResponse(mediaSources: [MediaSourceInfo(
        id: "ms3", container: "mkv", supportsDirectPlay: true, supportsDirectStream: true,
        supportsTranscoding: false)], playSessionId: "ps3")
    let directWithoutServerConversion = try client.resolveStream(itemID: "i3", info: conversionDisabled, profile: .native)
    #expect(directWithoutServerConversion.method == .directPlay)
}

@Test func videoURLsCarryPlaybackIdentity() throws {
    let client = EmbyClient(account: account(host: "play.test"), identity: identity)
    let source = MediaSourceInfo(id: "ms1", container: "mp4", supportsDirectPlay: true)
    let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps1")
    let streams = [
        try client.resolveOriginalStream(itemID: "i1", info: info),
        try client.resolveStream(itemID: "i1", info: info, profile: .native),
    ]
    for stream in streams {
        let query = try #require(URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems)
        for (name, value) in ["UserId": "u1", "DeviceId": "dev-1", "PlaySessionId": "ps1",
                              "MediaSourceId": "ms1", "api_key": "secret-token", "Static": "true"] {
            #expect(query.filter { $0.name == name }.map(\.value) == [value])
        }
    }

    let withoutSession = try client.resolveOriginalStream(itemID: "i1", info: PlaybackInfoResponse(mediaSources: [source]))
    let query = try #require(URLComponents(url: withoutSession.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "UserId" }?.value == "u1")
    #expect(query.first { $0.name == "DeviceId" }?.value == "dev-1")
    #expect(!query.contains { $0.name == "PlaySessionId" })
}

@Test func reportsUsePascalCase() async throws {
    let session = StubProtocol.session(host: "report.test") { request, body in
        guard request.url!.path == "/Sessions/Playing/Progress",
              let json = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              json["ItemId"] as? String == "i1", json["PositionTicks"] as? Int == 125_000_000,
              json["PlayMethod"] as? String == "DirectPlay", json["IsPaused"] as? Bool == true
        else { return .json("bad", status: 400) }
        return Response(status: 204, body: Data())
    }
    let client = EmbyClient(account: account(host: "report.test"), identity: identity, session: session)
    try await client.reportPlaybackProgress(PlaybackReport(
        itemId: "i1", mediaSourceId: "ms1", playSessionId: "ps1", positionSeconds: 12.5, isPaused: true,
        playMethod: .directPlay, eventName: "pause"))
}

private typealias Response = StubProtocol.Response

@Test func summarizesDolbyVisionAndAtmos() throws {
    let data = Data("""
    {"Id":"ms","Container":"mkv","DefaultAudioStreamIndex":1,"MediaStreams":[
      {"Type":"Video","Index":0,"Codec":"hevc","Width":3840,"Height":2160,"VideoRange":"HDR 10",
       "ExtendedVideoType":"DolbyVision","ExtendedVideoSubType":"DoviProfile81"},
      {"Type":"Audio","Index":1,"Codec":"truehd","Channels":8,"Profile":"Dolby TrueHD + Dolby Atmos"},
      {"Type":"Subtitle","Index":2,"Codec":"subrip","Language":"eng","IsTextSubtitleStream":true}]}
    """.utf8)
    let source = try EmbyCoding.decoder.decode(MediaSourceInfo.self, from: data)
    let s = MediaSummary(source: source)
    #expect(s.resolution == "4K")
    #expect(s.dynamicRange == .dolbyVision(profile: "8.1"))
    #expect(s.isAtmos)
    #expect(s.audio == "TrueHD 7.1")
    #expect(source.subtitleStreams.count == 1)

    var jellyfin = MediaStream(type: "Video", width: 1920, height: 1080)
    jellyfin.dvProfile = 5
    #expect(MediaSummary.dynamicRange(jellyfin) == .dolbyVision(profile: "5"))
    #expect(MediaSummary.dynamicRange(MediaStream(type: "Video", colorTransfer: "smpte2084")) == .hdr10)
}

@Test func accountStoreKeepsSeveralServersPrivately() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/accounts.json")
    let store = AccountStore(secrets: FileSecretStore(url: url))
    #expect(store.load().isEmpty)
    try store.save([account(host: "a"), account(host: "b")])
    #expect(store.load().map { $0.serverURL.host() } == ["a", "b"])
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)

    // 旧版只存一个账号，升级后仍然能读出来。
    try JSONEncoder().encode(account(host: "legacy")).write(to: url)
    #expect(store.load().map { $0.serverURL.host() } == ["legacy"])

    try store.save([])
    #expect(store.load().isEmpty)
}

@Test func readsTmdbProviderID() throws {
    let data = Data(#"{"Id":"s1","Name":"The Office","ProviderIds":{"Tmdb":"2316","Imdb":"tt0386676"}}"#.utf8)
    let item = try EmbyCoding.decoder.decode(EmbyItem.self, from: data)
    #expect(item.tmdbID == 2316)
}
