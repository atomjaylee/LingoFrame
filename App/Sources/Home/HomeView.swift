import DesignSystem
import MediaServerKit
import SwiftUI
import TMDBKit

/// 首页：适合学英语的剧集和电影推荐，信息和高清海报、背景、片名 Logo 都来自 TMDB。
/// 精选作品的高清剧照铺满整个窗口，第一屏底部显示片名 Logo、评分、简介和轮播圆点，
/// 往下滚动时「继续学习」和按难度分组的海报行从剧照上滑过。
struct HomeView: View {
    let openLibraryPage: () -> Void
    let windowHeight: Double

    @Environment(AppModel.self) private var model
    @Environment(\.contentLeadingInset) private var inset
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var resume: [(serverID: String, item: EmbyItem)] = []
    @State private var heroIndex = 0
    @State private var heroHovered = false

    private var store: RecommendationStore { model.recommendations }

    private var heroes: [(entry: CatalogEntry, title: TMDBTitle)] {
        let entries = LearningCatalog.allEntries
        return Array((entries.filter(\.featured) + entries.filter { !$0.featured })
            .compactMap { e in store.titles[e.id].map { (e, $0) } }.prefix(20))
    }

    private var hero: (entry: CatalogEntry, title: TMDBTitle)? {
        heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
    }

    private func backdropURL(_ title: TMDBTitle?) -> URL? {
        model.tmdb?.imageURL(title?.highResolutionBackdropPath ?? title?.backdropPath, size: .original)
    }

    private var nextBackdropURL: URL? {
        guard heroes.count > 1 else { return nil }
        return backdropURL(heroes[(heroIndex + 1) % heroes.count].title)
    }

    private func moveHero(by offset: Int) {
        let count = heroes.count
        guard count > 1 else { return }
        heroIndex = (heroIndex + offset + count) % count
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, max(0.8, geo.size.width / 1440))
            ZStack(alignment: .topLeading) {
                if model.tmdb != nil {
                    HeroBackdrop(url: backdropURL(hero?.title))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16 * scale) {
                        if model.tmdb == nil {
                            onboarding(height: max(geo.size.height * 0.7, 480))
                        } else {
                            heroSection(height: max(windowHeight * 0.72, 440), scale: scale)
                        }
                        if !resume.isEmpty { continueRow(scale: scale) }
                        ForEach(LearningCatalog.groups) { group in
                            let items = group.entries.compactMap { e in store.titles[e.id].map { (e, $0) } }
                            if !items.isEmpty { catalogRow(group, items: items) }
                        }
                    }
                    .padding(.bottom, 48)
                }
                .scrollIndicators(.never)
            }
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: hero?.title.ref)
        }
        // 剧照铺满整页时文字一律白色；还没有 TMDB 时跟随外观设置。
        .environment(\.colorScheme, model.tmdb == nil ? colorScheme : .dark)
        .overlay {
            if store.isLoading && store.titles.isEmpty { ProgressView().controlSize(.large) }
        }
        .overlay(alignment: .bottom) {
            if let message = store.errorMessage { ErrorBanner(message: message) {} }
        }
        .task(id: model.tmdb.map(ObjectIdentifier.init)) {
            if let tmdb = model.tmdb { await store.load(using: tmdb) }
        }
        .task(id: model.servers.map { "\($0.id)-\($0.state)" }) { await loadResume() }
        .task(id: nextBackdropURL) {
            guard let url = nextBackdropURL else { return }
            _ = try? await ImagePipeline.shared.image(for: url, maxPixelSize: 4096)
        }
    }

    // MARK: 第一屏

    private func heroSection(height: Double, scale: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let hero {
                heroPanel(hero.title, scale: scale)
                    .padding(.leading, inset)
            }
            carouselDots(scale: scale)
                .frame(maxWidth: .infinity)
                .padding(.leading, inset)
                .padding(.trailing, RexChrome.contentTrailing * scale)
                .padding(.top, 28 * scale)
        }
        .frame(height: height)
        .background {
            if let hero {
                NavigationLink(value: detailRoute(hero.title.ref)) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(ClickablePlainButtonStyle())
                .accessibilityLabel("查看\(hero.title.title)海报详情")
                .padding(.leading, inset)
            }
        }
        .overlay {
            if heroes.count > 1 {
                HStack {
                    Button { moveHero(by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("上一张海报")
                    .help("上一张")
                    Spacer()
                    Button { moveHero(by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("下一张海报")
                    .help("下一张")
                }
                .buttonStyle(RexBackButtonStyle())
                .padding(.leading, inset)
                .padding(.trailing, 18 * scale)
            }
        }
        .contentShape(Rectangle())
        .onHover { heroHovered = $0 }
    }

    private func heroPanel(_ title: TMDBTitle, scale: Double) -> some View {
        NavigationLink(value: detailRoute(title.ref)) {
            VStack(alignment: .leading, spacing: 0) {
                TitleLogo(title: title, tmdb: model.tmdb, height: 150 * scale, maxWidth: 260 * scale)
                Text((Array(title.genres.prefix(2)) + [title.releaseDate ?? title.year.map(String.init)]
                    .compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .padding(.top, 12 * scale)
                Text(title.overview ?? "")
                    .font(.system(size: 14 * scale, weight: .medium))
                    .lineSpacing(2 * scale)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 6 * scale)
                if let rating = title.voteAverage {
                    HStack(spacing: 4 * scale) {
                        RatingBadge(.tmdb, text: "TMDB")
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 12 * scale, weight: .semibold))
                    }
                    .padding(.top, 6 * scale)
                }
            }
            .frame(width: 300 * scale, alignment: .leading)
            .foregroundStyle(.white)
        }
        .buttonStyle(ClickablePlainButtonStyle())
        .accessibilityLabel("查看\(title.title)详情")
    }

    private func carouselDots(scale: Double) -> some View {
        HStack(spacing: 0) {
            if heroes.count > 1 {
                ForEach(heroes.indices, id: \.self) { index in
                    CarouselPageButton(title: heroes[index].title.title, isCurrent: heroIndex == index,
                                       isPaused: heroHovered || scenePhase != .active || reduceMotion, scale: scale,
                                       select: { heroIndex = index }, advance: { moveHero(by: 1) })
                        .id(heroes[index].title.ref)
                }
            }
        }
        .frame(height: 24 * scale)
    }

    /// 还没填写 TMDB 密钥时的引导。
    private func onboarding(height: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("看剧学英语").font(.system(size: 44, weight: .bold))
            Text("填写 TMDB 密钥后，首页会自动展示适合学英语的剧集和电影，配上高清海报、片名 Logo 和中文简介。")
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 12) {
                SettingsLink { PillLabel("填写 TMDB 密钥", systemImage: "key") }
                    .buttonStyle(RexPillButtonStyle())
                if model.servers.isEmpty {
                    Button(action: openLibraryPage) { PillLabel("添加资源库", systemImage: "externaldrive.badge.plus") }
                        .buttonStyle(RexPillButtonStyle(dimmed: true))
                }
            }
        }
        .padding(.leading, inset)
        .frame(height: height, alignment: .bottomLeading)
    }

    // MARK: 行

    private func rowTitle(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 20, weight: .bold))
            if let subtitle { Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color) }
        }
        .padding(.leading, inset)
    }

    private func continueRow(scale: Double) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text("继续观看")
                .font(.system(size: 15 * scale, weight: .semibold))
                .padding(.leading, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18 * scale) {
                    ForEach(resume.indices, id: \.self) { index in
                        let entry = resume[index]
                        HomeResumeCard(serverID: entry.serverID, item: entry.item, scale: scale)
                            .frame(width: 250 * scale)
                    }
                }
                .padding(.leading, inset)
                .padding(.trailing, RexChrome.contentTrailing * scale)
                .padding(.vertical, 4 * scale)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func catalogRow(_ group: CatalogGroup, items: [(CatalogEntry, TMDBTitle)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            rowTitle(group.title, subtitle: group.subtitle)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items, id: \.0.id) { entry, title in
                        NavigationLink(value: detailRoute(title.ref)) {
                            MediaCard(title: title.title,
                                      subtitle: [title.year.map(String.init), model.match(title.ref) == nil ? nil : "资源库已有"]
                                          .compactMap { $0 }.joined(separator: " · "),
                                      imageURL: model.tmdb?.imageURL(title.posterPath, size: .poster),
                                      badge: BadgeModel(entry.level, kind: .accent))
                        }
                        .buttonStyle(ClickablePlainButtonStyle())
                        .frame(width: 150)
                        .help(entry.reason)
                    }
                }
                .padding(.leading, inset)
                .padding(.trailing, RexChrome.contentTrailing)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .mediaCardStyle(PosterTileStyle())
        }
    }

    // MARK: 数据

    private func detailRoute(_ ref: TMDBRef) -> Route {
        let match = model.match(ref)
        return .detail(DetailTarget(tmdb: ref, serverID: match?.serverID, item: match?.item))
    }

    private func loadResume() async {
        var all: [(String, EmbyItem)] = []
        for server in model.servers where server.state != .offline {
            let items = (try? await server.client.resumeItems()) ?? []
            guard !Task.isCancelled else { return }
            all += items.map { (server.id, $0) }
        }
        guard !Task.isCancelled else { return }
        resume = all.sorted { ($0.1.userData?.lastPlayedDate ?? "") > ($1.1.userData?.lastPlayedDate ?? "") }
            .map { (serverID: $0.0, item: $0.1) }
    }
}

/// 当前页圆点兼作倒计时：进度按逐帧时间计算，避免定时器累加带来的跳动；计时更新只刷新这一枚按钮。
private struct CarouselPageButton: View {
    let title: String
    let isCurrent: Bool
    let isPaused: Bool
    let scale: Double
    let select: @MainActor () -> Void
    let advance: @MainActor () -> Void

    private static let duration: TimeInterval = 7

    /// 暂停前已经走过的秒数。
    @State private var elapsed: TimeInterval = 0
    /// 本段计时的起点，暂停时为 nil。
    @State private var runStart: Date?
    /// 重新计时时递增，用来重启切换任务。
    @State private var cycle = 0

    private var isRunning: Bool { isCurrent && !isPaused }

    private func progress(at date: Date) -> Double {
        let running = runStart.map { date.timeIntervalSince($0) } ?? 0
        return min(max((elapsed + running) / Self.duration, 0), 1)
    }

    private func restart() {
        elapsed = 0
        runStart = isRunning ? .now : nil
        cycle += 1
    }

    var body: some View {
        Button {
            if isCurrent { restart() }
            select()
        } label: {
            Group {
                if isCurrent {
                    TimelineView(.animation(minimumInterval: nil, paused: !isRunning)) { context in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay { CarouselProgressFill(progress: progress(at: context.date)).fill(.white) }
                            .clipShape(Capsule())
                            .frame(width: 28 * scale, height: 6 * scale)
                    }
                } else {
                    Circle().fill(.white.opacity(0.35))
                        .frame(width: 6 * scale, height: 6 * scale)
                }
            }
            .frame(width: (isCurrent ? 36 : 16) * scale, height: 24 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(ClickablePlainButtonStyle())
        .accessibilityLabel("切换至\(title)")
        .accessibilityValue(isCurrent ? (isPaused ? "当前显示，轮播已暂停" : "当前显示，\(Int(ceil((1 - progress(at: .now)) * Self.duration)))秒后切换") : "")
        .onAppear { if isRunning, runStart == nil { runStart = .now } }
        .onChange(of: isCurrent) { restart() }
        .onChange(of: isPaused) {
            guard isCurrent else { return }
            if isPaused {
                if let runStart { elapsed += Date.now.timeIntervalSince(runStart) }
                runStart = nil
            } else {
                runStart = .now
            }
        }
        .task(id: "\(isRunning)-\(cycle)") {
            guard isRunning else { return }
            try? await Task.sleep(for: .seconds(max(Self.duration - elapsed, 0)))
            guard !Task.isCancelled else { return }
            advance()
        }
    }
}

/// 进度条的白色部分。用路径而不是改 frame 宽度来画：frame 会按整像素取整，
/// 28pt 的条走 7 秒每 0.125 秒才挪一个像素，看起来一跳一跳；路径带抗锯齿，可以按亚像素平滑移动。
private struct CarouselProgressFill: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        let width = rect.width * progress
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    cornerRadius: min(rect.height, width) / 2)
    }
}

private struct HomeResumeCard: View {
    let serverID: String
    let item: EmbyItem
    let scale: Double
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var play: PlayAction { PlayAction(openWindow: openWindow, model: model, serverID: serverID) }

    private var imageURL: URL? {
        let client = model.server(serverID)?.client
        return client?.imageURL(for: item, type: .backdrop, maxWidth: 720)
            ?? client?.imageURL(for: item, type: .thumb, maxWidth: 720)
    }

    private var episode: String? {
        guard item.kind == .episode, let number = item.indexNumber else { return nil }
        return item.parentIndexNumber.map { "第 \($0) 季 · 第 \(number) 集" } ?? "第 \(number) 集"
    }

    private var playbackTime: String {
        if let raw = item.userData?.lastPlayedDate,
           let date = (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601)) {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.localizedString(for: date, relativeTo: .now)
        }
        return item.remainingText ?? item.runtimeText ?? "继续观看"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Button { play(item) } label: {
                VStack(alignment: .leading, spacing: 7 * scale) {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { RemoteImage(url: imageURL, maxPixelSize: 720) }
                        .clipped()
                        .overlay(alignment: .bottom) {
                            if let progress = item.progress {
                                ProgressCapsule(value: progress, height: 2 * scale)
                                    .padding(.horizontal, 10 * scale)
                                    .padding(.bottom, 9 * scale)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
                    HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                        Text(item.cardTitle).font(.system(size: 15 * scale, weight: .semibold))
                        if let episode {
                            Text(episode).font(.system(size: 12 * scale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ClickablePlainButtonStyle())
            .accessibilityLabel("继续观看\(item.cardTitle)\(episode.map { "，\($0)" } ?? "")")
            HStack {
                Text(playbackTime).font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                Menu { playbackActions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13 * scale, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(item.cardTitle)播放选项")
            }
        }
        .foregroundStyle(.white)
        .contextMenu { playbackActions }
    }

    @ViewBuilder private var playbackActions: some View {
        Button("继续播放") { play(item) }
        Button("从头播放") { play(item, resume: false) }
    }
}

/// 片名 Logo：TMDB 有 Logo 就显示透明 PNG，没有就用细体大字。
struct TitleLogo: View {
    let title: TMDBTitle
    let tmdb: TMDBClient?
    var height: Double = 120
    var maxWidth: Double = 460
    @Environment(\.theme) private var theme

    var body: some View {
        if let url = tmdb?.imageURL(title.logoPath, size: .original) {
            RemoteImage(url: url, maxPixelSize: 1200, contentMode: .fit, showsPlaceholder: false)
                .frame(maxWidth: maxWidth, maxHeight: height, alignment: .bottomLeading)
                .frame(height: height, alignment: .bottomLeading)
                .shadow(color: .black.opacity(0.3), radius: 10)
                .accessibilityLabel(title.title)
        } else {
            Text(title.originalTitle ?? title.title).themedFont(.mediaTitle).lineLimit(2)
        }
    }
}

#Preview("首页 · 初始状态") {
    NavigationStack {
        HomeView(openLibraryPage: {}, windowHeight: 760)
    }
    .appEnvironment(AppModel())
    .frame(width: 1200, height: 760)
}
