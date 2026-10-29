import DesignSystem
import MediaServerKit
import SwiftUI
import TMDBKit

/// 详情页：高清背景图、片名 Logo、简介、演员来自 TMDB；分季分集、播放资源和音视频字幕信息来自 Emby 资源库。
/// 两边任缺一边都能显示：资源库还没有的推荐作品只展示 TMDB 信息，大图铺满整个窗口；
/// 没有 TMDB 编号的视频退回 Emby 自己的图片和简介。版式照抄 Rex 的详情页。
struct ItemDetailView: View {
    let target: DetailTarget
    @Environment(AppModel.self) private var model
    @Environment(\.contentLeadingInset) private var inset
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var info: TMDBTitle?
    @State private var full: EmbyItem?
    @State private var seasons: [EmbyItem] = []
    @State private var seasonID: String?
    @State private var episodes: [EmbyItem] = []
    @State private var focusEpisode: EmbyItem?
    @State private var resolution: String?
    @State private var sourceID: String?
    @State private var showsStreams = true
    @State private var episodesFailed = false
    @State private var errorMessage: String?

    // MARK: 数据来源

    private var ref: TMDBRef? { target.tmdb ?? target.item?.tmdbRef }
    private var match: LibraryMatch? {
        if let item = target.item, let id = target.serverID { return LibraryMatch(serverID: id, item: item) }
        return ref.flatMap { model.match($0) }
    }
    private var serverID: String? { match?.serverID }
    private var client: EmbyClient? { model.server(serverID)?.client }
    private var emby: EmbyItem? { full ?? match?.item }
    private var tmdb: TMDBClient? { model.tmdb }
    private var entry: CatalogEntry? { ref.flatMap { model.recommendations.entry(for: $0) } }
    private var isSeries: Bool { ref?.type == .tv || emby?.kind == .series }
    private var play: PlayAction { PlayAction(openWindow: openWindow, serverID: serverID) }
    private var preheatItem: EmbyItem? {
        if let emby, emby.isPlayable { return emby }
        return isSeries ? nextEpisode : nil
    }

    private var backdropURL: URL? {
        tmdb?.imageURL(info?.backdropPath, size: .original)
            ?? emby.flatMap { client?.imageURL(for: $0, type: .backdrop, maxWidth: 2560) }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(height: emby == nil ? max(geo.size.height, 600) : max(geo.size.height * 0.6, 480), width: geo.size.width)
                        lower
                    }
                }
                .scrollIndicators(.never)
                .ignoresSafeArea()
                #if DEBUG
                // 调试路由末尾加 :sources 时滚到播放资源，方便截图检查。
                .onChange(of: focusEpisode?.id ?? full?.id) {
                    guard UserDefaults.standard.string(forKey: "debugRoute")?.hasSuffix(":sources") == true else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo("sources", anchor: .top)
                    }
                }
                #endif
            }
        }
        .background(RexChrome.detailBase.color.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(RexBackButtonStyle())
                .accessibilityLabel("返回")
                .padding(.leading, inset)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if let errorMessage { ErrorBanner(message: errorMessage) { self.errorMessage = nil } }
        }
        .environment(\.embyClient, client)
        .environment(\.embyServerID, serverID)
        .task(id: ref) { await loadTMDB() }
        .task(id: match?.item.id) { await loadEmby() }
        .task(id: nextEpisode?.id) { await loadFocusEpisode() }
        .task(id: preheatItem?.id) {
            guard let serverID, let item = preheatItem else { return }
            await model.preparePlayback(serverID: serverID, itemID: item.id)
        }
    }

    // MARK: 第一屏

    private func hero(height: Double, width: Double) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(url: backdropURL, fadeTo: emby == nil ? nil : RexChrome.detailBase.color)
            HeroInfoPanel(title: info, fallbackTitle: emby?.displayName ?? "",
                          meta: HeroMeta.parts(info, isSeries: isSeries, fallbackYear: emby?.productionYear,
                                               fallbackRuntime: emby?.runtimeText,
                                               seasonCount: seasons.isEmpty ? nil : seasons.count),
                          rating: info?.voteAverage ?? emby?.communityRating, level: entry?.level, note: entry?.reason,
                          overview: info?.overview ?? emby?.overview) {
                primaryButton
            } actions: {
                heroActions
            }
            .frame(width: max(width - inset - RexChrome.contentTrailing, 560))
            .padding(.leading, inset)
            .padding(.trailing, RexChrome.contentTrailing)
            .padding(.bottom, 30)
        }
        .frame(height: height)
        .clipped()
    }

    @ViewBuilder private var primaryButton: some View {
        if let emby, emby.isPlayable {
            Button { play(emby, resume: true) } label: {
                PillLabel(emby.resumePositionSeconds == nil ? "播放" : "继续播放")
            }
            .buttonStyle(RexPillButtonStyle())
        } else if isSeries, emby != nil, let next = nextEpisode {
            Button { play(next, resume: true) } label: {
                PillLabel([next.resumePositionSeconds == nil ? "播放" : "继续播放", next.episodeCode].compactMap { $0 }.joined(separator: " "))
            }
            .buttonStyle(RexPillButtonStyle())
        } else if emby != nil, episodesFailed {
            Button { Task { await loadEpisodes() } } label: { PillLabel("分集读取失败，点按重试", systemImage: "arrow.clockwise") }
                .buttonStyle(RexPillButtonStyle(dimmed: true))
        } else if emby != nil {
            Button {} label: { PillLabel("正在读取分集", systemImage: nil) }
                .buttonStyle(RexPillButtonStyle(dimmed: true))
                .disabled(true)
        } else {
            Button {} label: { PillLabel("资源库中暂无", systemImage: nil) }
                .buttonStyle(RexPillButtonStyle(dimmed: true))
                .disabled(true)
                .help("添加包含这部作品的 Emby 资源库后就能直接播放")
        }
    }

    @ViewBuilder private var heroActions: some View {
        if let emby {
            let target = emby.isPlayable ? emby : nextEpisode
            if let target {
                Button { play(target, resume: false) } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(emby.isPlayable ? "从头播放" : "这一集从头播放").accessibilityLabel("从头播放")
                Button { Task { await setPlayed(!target.isPlayed, target) } } label: {
                    Image(systemName: target.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(target.isPlayed ? "标记为未看" : "标记为已看").accessibilityLabel(target.isPlayed ? "标记为未看" : "标记为已看")
            }
            Button { Task { await loadEmby() } } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新").accessibilityLabel("刷新")
        }
    }

    /// 剧集的「下一集」：第一个没看完的分集。
    private var nextEpisode: EmbyItem? {
        episodes.first { !$0.isPlayed } ?? episodes.first
    }

    // MARK: 下方

    @ViewBuilder private var lower: some View {
        VStack(alignment: .leading, spacing: 34) {
            if emby != nil {
                if isSeries, !seasons.isEmpty { episodesSection }
                if let item = isSeries ? focusEpisode : emby, let sources = item.mediaSources, !sources.isEmpty {
                    sourcesSection(item, sources).id("sources")
                }
            } else if isSeries, let seasons = info?.seasons, !seasons.isEmpty {
                tmdbSeasons(seasons)
            }
            if let cast = info?.cast, !cast.isEmpty { castRow(cast) }
        }
        .padding(.leading, inset)
        .padding(.trailing, RexChrome.contentTrailing)
        .padding(.top, emby == nil ? 34 : 10)
        .padding(.bottom, 48)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 17, weight: .bold))
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                sectionTitle("剧集：")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(seasons) { s in
                            Button(s.displayName) { seasonID = s.id }
                                .buttonStyle(RexCapsuleChipStyle(isSelected: s.id == seasonID))
                        }
                    }
                }
                .scrollIndicators(.never)
                Text("已看 \(episodes.filter(\.isPlayed).count) / \(episodes.count)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
                    .fixedSize()
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(episodes) { ep in
                        EpisodeTile(episode: ep)
                            .onTapGesture { play(ep, resume: true) }
                            .contextMenu {
                                Button("播放") { play(ep, resume: true) }
                                Button("从头播放") { play(ep, resume: false) }
                                Divider()
                                Button(ep.isPlayed ? "标记为未看" : "标记为已看") { Task { await setPlayed(!ep.isPlayed, ep) } }
                            }
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: seasonID) { await loadEpisodes() }
    }

    private func sourcesSection(_ item: EmbyItem, _ sources: [MediaSourceInfo]) -> some View {
        let resolutions = sources.map { MediaSummary(source: $0).resolution ?? "其他" }.uniqued()
        let shownResolution = resolution.flatMap { resolutions.contains($0) ? $0 : nil } ?? resolutions.first
        let shown = sources.filter { (MediaSummary(source: $0).resolution ?? "其他") == shownResolution }
        let selected = shown.first { $0.id == sourceID } ?? shown.first
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                sectionTitle("播放资源：")
                ForEach(resolutions, id: \.self) { r in
                    Button(r) { resolution = r }.buttonStyle(RexCapsuleChipStyle(isSelected: r == shownResolution))
                }
                if isSeries {
                    Text([item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
                }
            }
            HStack(spacing: 16) {
                ForEach(shown, id: \.id) { source in
                    SourceCard(source: source, serverName: model.server(serverID)?.name ?? "Emby", isSelected: source.id == selected?.id)
                        .onTapGesture { sourceID = source.id }
                        .onTapGesture(count: 2) { play(item, resume: true) }
                }
            }
            Button { withAnimation(.easeOut(duration: 0.2)) { showsStreams.toggle() } } label: {
                Label(showsStreams ? "收起" : "展开", systemImage: showsStreams ? "chevron.up.circle" : "chevron.down.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 803)
            if showsStreams, let selected { StreamCards(source: selected).frame(maxWidth: 803) }
        }
    }

    /// 资源库里没有这部剧时，只列出 TMDB 上的分季信息。
    private func tmdbSeasons(_ seasons: [TMDBSeason]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("分季")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(seasons, id: \.number) { s in
                        MediaCard(title: s.name,
                                  subtitle: [s.year.map(String.init), s.episodeCount.map { "\($0) 集" }].compactMap { $0 }.joined(separator: " · "),
                                  imageURL: tmdb?.imageURL(s.posterPath ?? info?.posterPath, size: .posterSmall))
                            .frame(width: 150)
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .mediaCardStyle(PosterTileStyle())
        }
    }

    private func castRow(_ cast: [TMDBCast]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("演员")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(cast) { person in
                        VStack(spacing: 6) {
                            RemoteImage(url: tmdb?.imageURL(person.profilePath, size: .profile), maxPixelSize: 240)
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .overlay {
                                    if person.profilePath == nil {
                                        Image(systemName: "person.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                            Text(person.name).font(.system(size: 13, weight: .semibold))
                            if let character = person.character, !character.isEmpty {
                                Text(character).font(.system(size: 11, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
                                    .padding(.top, -4)
                            }
                        }
                        .lineLimit(1)
                        .frame(width: 96)
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 加载

    private func loadTMDB() async {
        guard let ref, let tmdb else { return }
        do {
            info = try await tmdb.details(ref)
        } catch {
            // TMDB 连不上时仍然显示资源库里的信息，只在资源库也没有时提示。
            if match == nil { errorMessage = error.localizedDescription }
        }
    }

    private func loadEmby() async {
        guard let client, let item = match?.item else { return }
        do {
            full = try await client.item(item.id)
            if (full ?? item).kind == .series {
                seasons = try await client.seasons(of: item.id)
                if seasonID == nil {
                    seasonID = seasons.first { ($0.userData?.unplayedItemCount ?? 0) > 0 }?.id ?? seasons.first?.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let client, let item = match?.item, isSeries, let seasonID else { return }
        do {
            episodes = try await client.episodes(of: item.id, season: seasonID)
            episodesFailed = false
        } catch {
            episodesFailed = episodes.isEmpty
            errorMessage = error.localizedDescription
        }
    }

    /// 剧集的播放资源要从单集上取：分集列表里没有 MediaSources，单独再请求一次。
    private func loadFocusEpisode() async {
        guard let client, isSeries, let next = nextEpisode else { focusEpisode = nil; return }
        focusEpisode = (try? await client.item(next.id)) ?? next
    }

    private func setPlayed(_ played: Bool, _ target: EmbyItem) async {
        guard let client, let item = match?.item else { return }
        do {
            try await client.setPlayed(played, itemID: target.id)
            if target.id == item.id { full = try? await client.item(item.id) } else { await loadEpisodes() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 分集：16:9 剧照（圆角 10，压一条进度）+ 集数和标题 + 时长或剩余时间。
struct EpisodeTile: View {
    @Environment(\.embyClient) private var client
    @State private var isHovered = false
    let episode: EmbyItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: client?.imageURL(for: episode, type: .primary, maxWidth: 480), maxPixelSize: 480)
                .frame(width: 240, height: 135)
                .overlay(alignment: .bottom) {
                    if let p = episode.progress, p > 0, !episode.isPlayed {
                        ProgressCapsule(value: p, height: 3).padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.isPlayed {
                        Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                            .foregroundStyle(.white, RexChrome.confirm.color).padding(6)
                    }
                }
                .overlay {
                    if isHovered {
                        Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white).shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text([episode.episodeCode, episode.name].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(episode.isPlayed ? [episode.runtimeText, "已看"].compactMap { $0 }.joined(separator: " · ")
                 : episode.remainingText ?? episode.runtimeText ?? "")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
                .padding(.top, -4)
        }
        .frame(width: 240, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// 一个播放版本：动态范围、体积、码率、来自哪台服务器，选中的描边加亮并打勾。
struct SourceCard: View {
    let source: MediaSourceInfo
    let serverName: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(StreamText.rangeTitle(source)).font(.system(size: 16, weight: .bold)).lineLimit(1)
            HStack(spacing: 10) {
                if let size = source.size { Label(StreamText.gigabytes(size), systemImage: "internaldrive.fill") }
                if let bitrate = source.bitrate { Label(StreamText.megabits(bitrate), systemImage: "waveform") }
            }
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 6) {
                EmbyMark(size: 14)
                Text(serverName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, RexChrome.confirm.color).font(.system(size: 14))
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minWidth: 190, alignment: .leading)
        .fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(isSelected ? 0.75 : 0.16), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .help("点一下查看这个版本的音视频信息，双击播放")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// 视频、音频、字幕三张信息卡。字幕卡会说明能不能逐句取词。
struct StreamCards: View {
    let source: MediaSourceInfo

    var body: some View {
        let summary = MediaSummary(source: source)
        let video = source.videoStream
        let audio = source.audioStreams.first { $0.index == source.defaultAudioStreamIndex } ?? source.audioStreams.first
        let subtitle = source.subtitleStreams.first { StreamText.isEnglish($0.language) && $0.isTextSubtitleStream == true }
            ?? source.subtitleStreams.first { StreamText.isEnglish($0.language) } ?? source.subtitleStreams.first
        HStack(alignment: .top, spacing: 10) {
            RexInfoCard("视频", systemImage: "film", rows: [
                ("标题", video?.displayTitle ?? "未知"),
                ("分辨率", video.flatMap { v in v.width.flatMap { w in v.height.map { "\(w)x\($0)" } } } ?? "未知"),
                ("色彩范围", summary.dynamicRange.title),
                ("文件大小", source.size.map(StreamText.gigabytes) ?? "未知"),
                ("码率", (video?.bitRate ?? source.bitrate).map(StreamText.megabits) ?? "未知"),
            ])
            RexInfoCard("音频", systemImage: "music.note", rows: audio.map { a in [
                ("标题", a.displayTitle ?? a.title ?? "未知"),
                ("语言", StreamText.language(a.language)),
                ("编码", a.codec?.uppercased() ?? "未知"),
                ("声道数", a.channels.map(String.init) ?? "未知"),
                ("全景声", summary.isAtmos ? "杜比全景声" : "否"),
            ] } ?? [("音频", "无")])
            RexInfoCard("字幕", systemImage: "captions.bubble", rows: subtitle.map { t in [
                ("标题", t.displayTitle ?? t.title ?? "未知"),
                ("语言", StreamText.language(t.language)),
                ("编码", t.codec?.uppercased() ?? "未知"),
                ("来源", t.isExternal == true ? "外挂" : "内封"),
                ("取词", t.isTextSubtitleStream == true ? "支持逐句取词" : "图形字幕，暂不能取词"),
            ] } ?? [("字幕", "没有字幕")])
        }
    }
}

enum StreamText {
    static func rangeTitle(_ source: MediaSourceInfo) -> String {
        let s = MediaSummary(source: source)
        switch s.dynamicRange {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .sdr: return [s.resolution, "SDR"].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    static func megabits(_ bps: Int) -> String {
        String(format: "%.2f Mbps", Double(bps) / 1_000_000)
    }

    static func isEnglish(_ code: String?) -> Bool {
        guard let code = code?.lowercased() else { return false }
        return code == "eng" || code == "en" || code.hasPrefix("en-")
    }

    /// eng → 英语；认不出来就原样显示。
    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "未知" }
        let zh = Locale(identifier: "zh_CN")
        if let name = zh.localizedString(forLanguageCode: code) { return name }
        if let name = Locale.Language(identifier: code).languageCode.flatMap({ zh.localizedString(forLanguageCode: $0.identifier) }) {
            return name
        }
        return code
    }
}

extension Array where Element: Hashable {
    /// 去重并保持原来的顺序。
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
