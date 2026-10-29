import DesignSystem
import MediaServerKit
import SwiftUI

/// 资源库：照抄 Rex，标题右边是「编辑」和「添加资源库」，下面「媒体服务器」分组里每台服务器一张卡片。
/// 点卡片进入这台服务器的媒体库；编辑状态下卡片左上角出现删除按钮。
struct LibraryPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.contentLeadingInset) private var inset
    @State private var showsAddDialog = false
    @State private var isEditing = false
    @State private var pendingRemoval: ServerConnection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 32) {
                    Text("资源库").font(.system(size: 26, weight: .bold))
                    Spacer()
                    if !model.servers.isEmpty {
                        Button(isEditing ? "完成" : "编辑") { withAnimation(.easeOut(duration: 0.15)) { isEditing.toggle() } }
                    }
                    Button { showsAddDialog = true } label: { Label("添加资源库", systemImage: "externaldrive.badge.plus") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .padding(.trailing, 4)

                if model.servers.isEmpty {
                    emptyState.padding(.top, 120)
                } else {
                    HStack(spacing: 8) {
                        Text("媒体服务器")
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 13))
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 212, maximum: 212), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(model.servers) { server in
                            NavigationLink(value: Route.server(server.id)) {
                                ServerCard(server: server)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .topLeading) {
                                if isEditing {
                                    Button { pendingRemoval = server } label: {
                                        Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .red).font(.system(size: 20))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -7, y: -7)
                                    .accessibilityLabel("删除 \(server.name)")
                                }
                            }
                            .contextMenu {
                                Button("刷新") { Task { await server.refresh() } }
                                Divider()
                                Button("删除资源库", role: .destructive) { pendingRemoval = server }
                            }
                        }
                    }
                }
            }
            .padding(.leading, inset)
            .padding(.trailing, RexChrome.contentTrailing + 4)
            .padding(.top, 54)
            .padding(.bottom, 48)
        }
        #if DEBUG
        .onAppear { if UserDefaults.standard.string(forKey: "debugRoute")?.hasPrefix("library:") == true { showsAddDialog = true } }
        #endif
        .overlay {
            if showsAddDialog {
                AddServerDialog(isPresented: $showsAddDialog)
            }
        }
        .confirmationDialog("删除「\(pendingRemoval?.name ?? "")」？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除", role: .destructive) {
                if let server = pendingRemoval { model.removeServer(server.id) }
                pendingRemoval = nil
                if model.servers.isEmpty { isEditing = false }
            }
        } message: {
            Text("只会从 ELEnglish 里移除，不会影响服务器上的文件。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("还没有资源库").font(.system(size: 17, weight: .semibold)).padding(.top, 4)
            Text("添加 Emby 服务器后，推荐里的作品会自动和这里的片源对上号")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Button("添加资源库") { showsAddDialog = true }
                .buttonStyle(RexCapsuleChipStyle(isSelected: true))
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 服务器卡片：212×121，圆角 18，细描边；左上图标、右上在线状态点，下面名字、线路和片数。
private struct ServerCard: View {
    let server: ServerConnection
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                EmbyMark(size: 30)
                Spacer()
                Circle()
                    .fill(server.state == .online ? RexChrome.online.color : Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .shadow(color: server.state == .online ? RexChrome.online.color.opacity(0.7) : .clear, radius: 3)
                    .padding(.trailing, 2)
                    .accessibilityLabel(statusText)
                    .help(statusText)
            }
            Text(server.name).font(.system(size: 15, weight: .medium)).lineLimit(1).padding(.top, 12)
            Text(server.state == .offline ? (server.errorMessage ?? "无响应") : (server.account.serverURL.host() ?? "主线路"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 14) {
                Text("电影:\(server.movieCount)")
                Text("剧集:\(server.seriesCount)")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(width: 212, height: 121, alignment: .topLeading)
        .background(RexChrome.cardFill.color.opacity(isHovered ? 2 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(RexChrome.cardStroke.color, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { isHovered = $0 }
    }

    private var statusText: String {
        switch server.state {
        case .online: "在线"
        case .offline: server.errorMessage ?? "无响应"
        case .idle: "连接中"
        }
    }
}

/// 一台服务器里的媒体库。
struct ServerLibrariesView: View {
    let serverID: String
    @Environment(AppModel.self) private var model
    @Environment(\.contentLeadingInset) private var inset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let server = model.server(serverID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(RexBackButtonStyle())
                        .accessibilityLabel("返回")
                    Text(server?.name ?? "资源库").font(.system(size: 26, weight: .bold))
                }
                if let server {
                    if server.libraries.isEmpty {
                        Text(server.state == .offline ? (server.errorMessage ?? "服务器无响应") : "正在读取媒体库…")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(server.libraries) { lib in
                            NavigationLink(value: Route.library(serverID: server.id, library: lib)) {
                                LibraryTile(library: lib, client: server.client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.leading, inset)
            .padding(.trailing, RexChrome.contentTrailing)
            .padding(.top, 50)
            .padding(.bottom, 48)
        }
    }
}

private struct LibraryTile: View {
    let library: EmbyItem
    let client: EmbyClient
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.space(2)) {
            RemoteImage(url: client.imageURL(for: library, type: .primary, maxWidth: 640), maxPixelSize: 640)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if library.imageTag(.primary) == nil {
                        Image(systemName: library.collectionType == "movies" ? "film" : "tv")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(theme.colors.inkMuted.color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMd, style: .continuous))
                .scaleEffect(isHovered ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovered)
            Text(library.displayName).font(.system(size: 14, weight: .semibold))
            Text(library.collectionType == "movies" ? "电影" : library.collectionType == "tvshows" ? "剧集" : "混合")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, -4)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

#Preview("资源库 · 空状态") {
    NavigationStack {
        LibraryPage()
    }
    .environment(\.contentLeadingInset, 24)
    .appEnvironment(AppModel())
    .frame(width: 1000, height: 700)
}
