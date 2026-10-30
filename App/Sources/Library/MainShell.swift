import DesignSystem
import MediaServerKit
import PlaybackKit
import SwiftUI
import TMDBKit

extension EnvironmentValues {
    /// 当前页面所属的 Emby 服务器（资源库页、详情页、播放时用）。
    @Entry var embyClient: EmbyClient?
    @Entry var embyServerID: String?
    /// 内容区左侧要让出的宽度（浮动侧边栏占的位置）。背景和大图仍然铺满整个窗口。
    @Entry var contentLeadingInset: Double = 24
}

/// 详情页的目标：可以只有 TMDB（推荐里资源库还没有的作品），也可以只有 Emby（没有 TMDB 编号的视频），通常两者都有。
struct DetailTarget: Hashable {
    var tmdb: TMDBRef?
    var serverID: String?
    var item: EmbyItem?
}

enum Route: Hashable {
    case detail(DetailTarget)
    case library(serverID: String, library: EmbyItem)
    case server(String)
}

enum ShellSection: Hashable {
    case home
    case library
    case search
    case comingSoon(String)
}

/// 主窗口：内容铺满整个窗口，左侧浮着一块 Rex 风格的半透明侧边栏，离窗口边缘 10 点。
struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var section: ShellSection = .home
    @State private var path = NavigationPath()
    @AppStorage("sidebar.collapsed") private var collapsed = false

    private var inset: Double {
        collapsed ? 128 : RexChrome.contentLeading
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationStack(path: $path) {
                content
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
            .environment(\.contentLeadingInset, inset)

            if collapsed {
                Button { withAnimation(.easeOut(duration: 0.2)) { collapsed = false } } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(RexIconButtonStyle(diameter: 32))
                .accessibilityLabel("展开侧边栏")
                .padding(.leading, 84)
                .padding(.top, 10)
            } else {
                Sidebar(section: $section, collapse: { withAnimation(.easeOut(duration: 0.2)) { collapsed = true } })
                    .frame(width: RexChrome.sidebarWidth)
                    .padding(RexChrome.sidebarInset)
                    .ignoresSafeArea(edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onChange(of: section) { path = NavigationPath() }
        .task { await model.refreshAll() }
        // 调试路由不等资源库刷新完：服务器慢的时候也能马上打开要检查的页面。
        .task { await openDebugRoute() }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .home: HomeView(openLibraryPage: { section = .library })
        case .library: LibraryPage()
        case .search: SearchView()
        case .comingSoon(let title): ComingSoonView(title: title)
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .detail(let target):
            ItemDetailView(target: target)
        case .server(let serverID):
            ServerLibrariesView(serverID: serverID)
        case .library(let serverID, let library):
            LibraryGridView(library: library)
                .environment(\.embyClient, model.server(serverID)?.client)
                .environment(\.embyServerID, serverID)
        }
    }

    /// 开发版：启动参数 -debugRoute 直接打开某个页面，方便在没有界面操作的环境里截图检查。
    /// 例如 -debugRoute detail:<条目ID>、tmdb:tv:2316、library、library:add、library:emby、settings、series[:序号]、movie[:序号]、play:<条目ID>。
    private func openDebugRoute() async {
        #if DEBUG
        guard let route = UserDefaults.standard.string(forKey: "debugRoute") else { return }
        let parts = route.split(separator: ":").map(String.init)
        let server = model.servers.first
        switch parts.first {
        case "library":
            section = .library
        case "settings":
            try? await Task.sleep(for: .seconds(1))
            openSettings()
        case "detail":
            if let server, parts.count > 1, let item = try? await server.client.item(parts[1]) {
                path.append(Route.detail(DetailTarget(tmdb: item.tmdbRef, serverID: server.id, item: item)))
            }
        case "series", "movie":
            // 等资源库片目读完，打开第 N 部（默认第一部）有 TMDB 编号的剧集或电影。
            let kind: EmbyItem.Kind = parts[0] == "series" ? .series : .movie
            for _ in 0..<60 where server?.catalog.isEmpty ?? true { try? await Task.sleep(for: .seconds(1)) }
            let items = (server?.catalog ?? []).filter { $0.kind == kind && $0.tmdbRef != nil }
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if let server, items.indices.contains(index) {
                let item = items[index]
                path.append(Route.detail(DetailTarget(tmdb: item.tmdbRef, serverID: server.id, item: item)))
            }
        case "playtest", "resumetest":
            if let server {
                await PlaybackProbe.run(server: server, limit: parts.count > 1 ? Int(parts[1]) ?? 8 : 8, resumeOnly: parts[0] == "resumetest")
            }
        case "playtitle":
            // 打开播放窗口播放片名包含指定文字的第一部作品（剧集取第一集）。
            for _ in 0..<60 where server?.catalog.isEmpty ?? true { try? await Task.sleep(for: .seconds(1)) }
            if let server, parts.count > 1, let match = server.catalog.first(where: { $0.cardTitle.contains(parts[1]) }) {
                var id = match.id
                if match.kind == .series, let first = try? await server.client.episodes(of: match.id, season: nil).first { id = first.id }
                model.showPlayer(.emby(serverID: server.id, itemID: id, resume: false), using: openWindow)
            }
        case "soaktest":
            // 连续播放一段时间，检查长时间播放是否卡顿或中断：soaktest:片名:秒数
            for _ in 0..<60 where server?.catalog.isEmpty ?? true { try? await Task.sleep(for: .seconds(1)) }
            if let server, parts.count > 1, let match = server.catalog.first(where: { $0.cardTitle.contains(parts[1]) }) {
                var id = match.id
                if match.kind == .series, let first = try? await server.client.episodes(of: match.id, season: nil).first { id = first.id }
                let session = PlaybackSession(client: server.client, serverID: server.id, engine: try! NativePlayerEngine())
                await session.play(itemID: id, resume: false)
                let seconds = parts.count > 2 ? Int(parts[2]) ?? 120 : 120
                var last = ""
                for tick in 0..<(seconds * 2) {
                    let state = "\(session.engine.state)"
                    if state != last { NSLog("耐久 %.1fs 状态 %@ 位置 %.1f", Double(tick) / 2, state, session.engine.currentTime); last = state }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                NSLog("耐久 结束 位置 %.1f 解码 %@ 字幕 %@ 错误 %@", session.engine.currentTime,
                      session.engine.diagnostics().playbackType ?? "-", session.engine.nativeSubtitleDescription ?? "-",
                      session.errorMessage ?? "-")
                session.close()
            }
            NSLog("playtest done")
        case "titletest":
            if let server, parts.count > 1 { await PlaybackProbe.run(server: server, limit: 1, title: parts[1]) }
        case "switchtest":
            for _ in 0..<60 where !model.servers.contains(where: { $0.catalog.contains { $0.kind == .series } }) {
                try? await Task.sleep(for: .seconds(1))
            }
            let target = model.servers.first { $0.catalog.contains { $0.kind == .series } } ?? server
            if let target { await PlaybackProbe.runSwitchTest(server: target) }
        case "tmdb":
            if parts.count > 2, let type = TMDBMediaType(rawValue: parts[1]), let id = Int(parts[2]) {
                let ref = TMDBRef(type: type, id: id)
                let match = model.match(ref)
                path.append(Route.detail(DetailTarget(tmdb: ref, serverID: match?.serverID, item: match?.item)))
            }
        case "play":
            if let server, parts.count > 1 {
                model.showPlayer(.emby(serverID: server.id, itemID: parts[1], resume: true), using: openWindow)
            }
        default:
            break
        }
        #endif
    }
}

// MARK: - 侧边栏

/// 照抄 Rex：搜索 / 发现 / 学习三组，每行 40 高、15 号半粗字，选中行浅白底；设置固定在最底下。
private struct Sidebar: View {
    @Binding var section: ShellSection
    let collapse: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer().frame(width: 72)
                Button(action: collapse) { Image(systemName: "sidebar.left").font(.system(size: 15)) }
                    .buttonStyle(.plain)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .accessibilityLabel("收起侧边栏")
                Spacer()
            }
            .frame(height: 32)
            .padding(.bottom, 10)

            row("搜索", icon: "magnifyingglass", isSelected: section == .search) { section = .search }
                .keyboardShortcut("k", modifiers: .command)
            divider

            groupLabel("发现")
            row("首页", icon: "house", isSelected: section == .home) { section = .home }
            row("资源库", icon: "externaldrive", isSelected: section == .library,
                trailing: model.servers.isEmpty ? nil : "\(model.servers.count)") { section = .library }
            divider

            groupLabel("学习")
            row("在学", icon: "play.rectangle", isSelected: section == .comingSoon("在学")) { section = .comingSoon("在学") }
            row("生词本", icon: "book.closed", isSelected: section == .comingSoon("生词本")) { section = .comingSoon("生词本") }
            row("收藏的句子", icon: "text.quote", isSelected: section == .comingSoon("收藏的句子")) { section = .comingSoon("收藏的句子") }
            row("学习日历", icon: "calendar", isSelected: section == .comingSoon("学习日历")) { section = .comingSoon("学习日历") }

            Spacer(minLength: 16)
            SettingsLink { rowLabel("设置", icon: "gearshape", isSelected: false, trailing: nil) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .rexSidebarPanel()
    }

    private var divider: some View {
        Rectangle().fill(RexChrome.separator.color).frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
    }

    private func row(_ title: String, icon: String, isSelected: Bool, trailing: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, icon: icon, isSelected: isSelected, trailing: trailing) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, icon: String, isSelected: Bool, trailing: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 22)
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(isSelected ? RexChrome.rowSelected.color : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - 通用小组件

struct ComingSoonView: View {
    let title: String
    @Environment(\.contentLeadingInset) private var inset

    var body: some View {
        ContentUnavailableView(title, systemImage: "sparkles", description: Text("学习功能正在开发中，接入字幕剧本后开放。"))
            .padding(.leading, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: theme.metrics.space(3)) {
            StatusDot(.offline)
            Text(message).themedFont(.subhead).lineLimit(2)
            Spacer()
            Button("关闭", action: dismiss).buttonStyle(RexTextButtonStyle())
        }
        .padding(.leading, theme.metrics.space(4))
        .padding(.vertical, theme.metrics.space(2))
        .background(theme.colors.popoverFill.color, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.colors.glassStroke.color, lineWidth: 1))
        .padding(theme.metrics.space(6))
        .frame(maxWidth: 640)
    }
}

/// 打开播放窗口。
@MainActor
struct PlayAction {
    let openWindow: OpenWindowAction
    let model: AppModel
    let serverID: String?

    func callAsFunction(_ item: EmbyItem, resume: Bool = true) {
        guard let serverID else { return }
        model.showPlayer(.emby(serverID: serverID, itemID: item.id, resume: resume), using: openWindow)
    }
}

extension EmbyItem {
    var tmdbRef: TMDBRef? {
        guard let id = tmdbID, kind == .movie || kind == .series else { return nil }
        return TMDBRef(type: kind == .series ? .tv : .movie, id: id)
    }

    var cardTitle: String {
        kind == .episode ? (seriesName ?? displayName) : displayName
    }

    var cardSubtitle: String? {
        switch kind {
        case .episode: [episodeCode, name].compactMap { $0 }.joined(separator: " · ")
        case .series:
            [productionYear.map(String.init), (userData?.unplayedItemCount).flatMap { $0 > 0 ? "\($0) 集未看" : nil }]
                .compactMap { $0 }.joined(separator: " · ")
        default: productionYear.map(String.init)
        }
    }

    var runtimeText: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        let minutes = Int(Ticks.seconds(ticks) / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
    }

    var remainingMinutes: Int? {
        guard let total = runTimeTicks, total > 0, let pos = userData?.playbackPositionTicks, pos > 0 else { return nil }
        return max(1, Int(Ticks.seconds(total - pos) / 60))
    }

    /// 剩余时长，比如「剩余 9 分钟」。
    var remainingText: String? { remainingMinutes.map { "剩余 \($0) 分钟" } }

    var kindLabel: String {
        switch kind {
        case .movie: "电影"
        case .series, .season, .episode: "剧集"
        default: "视频"
        }
    }
}

enum TimeFormat {
    /// 秒数 → "1:02:03" 或 "2:03"。
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 资源库里的一张卡片：单集和「继续观看」直接播，剧集和电影进详情。所属服务器从环境里取。
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.embyClient) private var client
    @Environment(\.embyServerID) private var serverID
    @Environment(\.openWindow) private var openWindow
    let item: EmbyItem
    var landscape = false

    private var play: PlayAction { PlayAction(openWindow: openWindow, model: model, serverID: serverID) }

    var body: some View {
        Group {
            if landscape || item.kind == .episode {
                Button { play(item) } label: { card }
            } else {
                NavigationLink(value: Route.detail(DetailTarget(tmdb: item.tmdbRef, serverID: serverID, item: item))) { card }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.isPlayable {
                Button("播放") { play(item) }
                Button("从头播放") { play(item, resume: false) }
            }
        }
    }

    private var card: some View {
        MediaCard(title: item.cardTitle,
                  code: item.kind == .episode ? item.episodeCode : nil,
                  subtitle: landscape ? [item.remainingText, item.kind == .movie ? "电影" : nil].compactMap { $0 }.joined(separator: " · ")
                      : (item.kind == .episode ? item.name : item.productionYear.map(String.init)),
                  imageURL: client?.imageURL(for: item, type: landscape ? .thumb : .primary, maxWidth: landscape ? 640 : 360),
                  progress: item.progress, isPlayed: item.isPlayed)
    }
}
