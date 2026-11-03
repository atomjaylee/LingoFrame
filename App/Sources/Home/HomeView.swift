import DesignSystem
import MediaServerKit
import SwiftUI
import TMDBKit

/// 首页：适合学英语的剧集和电影推荐，信息和高清海报、背景、片名 Logo 都来自 TMDB。
/// 精选作品的高清剧照铺满整个窗口，第一屏底部显示片名 Logo、评分、简介和轮播圆点，
/// 往下滚动时「继续学习」和按难度分组的海报行从剧照上滑过。
struct HomeView: View {
    let openLibraryPage: () -> Void

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
        LearningCatalog.allEntries.filter(\.featured).compactMap { e in store.titles[e.id].map { (e, $0) } }
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.tmdb != nil {
                    HeroBackdrop(url: backdropURL(hero?.title))
                        .id(hero?.title.ref)
                        .transition(.opacity)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if model.tmdb == nil {
                            onboarding(height: max(geo.size.height * 0.7, 480))
                        } else {
                            heroSection(height: max(geo.size.height * 0.62, 500), width: geo.size.width)
                        }
                        if !resume.isEmpty { continueRow }
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
        .task(id: hero?.title.ref) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                guard heroes.count > 1, !heroHovered, scenePhase == .active, !reduceMotion else { continue }
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
    }

    // MARK: 第一屏

    private func heroSection(height: Double, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let hero {
                heroPanel(hero.entry, hero.title)
                    .frame(width: max(width - inset - RexChrome.contentTrailing, 560))
            }
        }
        .padding(.leading, inset)
        .padding(.trailing, RexChrome.contentTrailing)
        .padding(.bottom, 8)
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { heroHovered = $0 }
    }

    private func heroPanel(_ entry: CatalogEntry, _ title: TMDBTitle) -> some View {
        HeroInfoPanel(title: title, meta: HeroMeta.parts(title, isSeries: title.ref.type == .tv),
                             rating: title.voteAverage, level: entry.level, note: entry.reason, overview: title.overview) {
            EmptyView()
        } actions: {
            if heroes.count > 1 {
                HStack(spacing: 2) {
                    ForEach(heroes.indices, id: \.self) { index in
                        Button { heroIndex = index } label: {
                            Circle()
                                .fill(.white.opacity(heroIndex == index ? 1 : 0.35))
                                .frame(width: 6, height: 6)
                                .frame(width: 20, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ClickablePlainButtonStyle())
                        .accessibilityLabel("切换至\(heroes[index].title.title)")
                        .accessibilityValue(heroIndex == index ? "当前显示" : "")
                    }
                }
            }
            NavigationLink(value: detailRoute(title.ref)) { Image(systemName: "info.circle") }
                .help("详情").accessibilityLabel("详情")
        }
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

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            rowTitle("继续学习")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(resume, id: \.item.id) { entry in
                        ItemCard(item: entry.item, landscape: true)
                            .frame(width: 260)
                            .environment(\.embyClient, model.server(entry.serverID)?.client)
                            .environment(\.embyServerID, entry.serverID)
                    }
                }
                .padding(.leading, inset)
                .padding(.trailing, RexChrome.contentTrailing)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .mediaCardStyle(LandscapeTileStyle())
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
        resume = all.map { (serverID: $0.0, item: $0.1) }
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
        HomeView(openLibraryPage: {})
    }
    .appEnvironment(AppModel())
    .frame(width: 1200, height: 760)
}
