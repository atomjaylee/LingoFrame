import AppKit
import DesignSystem
import MediaServerKit
import PlaybackKit
import SwiftUI
import Workspace

/// 播放器的内置面板。每个面板都是独立注册的，用户可以把它放到左、右、底部或独立窗口。
enum PlayerPanels {
    @MainActor
    static func register(in registry: PanelRegistry) {
        registry.register(PanelDescriptor(id: PanelIDs.transcript, title: "字幕与学习", systemImage: "translate",
                                          defaultPlacement: .floating) { TranscriptFloatingPanel() })
        registry.register(PanelDescriptor(id: PanelIDs.episodes, title: "选集", systemImage: "list.bullet.rectangle",
                                          defaultPlacement: .trailing) { EpisodesPanel() })
        registry.register(PanelDescriptor(id: PanelIDs.mediaInfo, title: "媒体信息", systemImage: "info.circle",
                                          defaultPlacement: .trailing) { MediaInfoPanel() })
        registry.register(PanelDescriptor(id: PanelIDs.playbackDebug, title: "播放诊断", systemImage: "waveform.path.ecg",
                                          defaultPlacement: .bottom) { PlaybackDebugPanel() })
    }
}

private struct TranscriptFloatingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackSession.self) private var session: PlaybackSession?
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var positioned = false
    @State private var keyMonitor = KeyMonitor()
    @State private var panelWindow: NSWindow?

    var body: some View {
        Group {
            if let session {
                LearningPanel(session: session) {
                    dismissWindow(id: WorkspaceWindows.floatingPanel, value: PanelIDs.transcript)
                }
                .background(WindowAccessor { configure($0, session: session) })
            } else {
                NoSessionView()
            }
        }
        .onChange(of: session == nil) { _, hasEnded in
            if hasEnded { dismissWindow(id: WorkspaceWindows.floatingPanel, value: PanelIDs.transcript) }
        }
        .onDisappear { keyMonitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let panelWindow, note.object as? NSWindow === panelWindow { session?.setLearningPanelVisible(false) }
        }
    }

    private func configure(_ panel: NSWindow?, session: PlaybackSession) {
        guard let panel else { return }
        if panelWindow !== panel { panelWindow = panel }
        panel.titleVisibility = .hidden
        // 沿用 SwiftUI 隐藏标题栏的窗口样式，保留原生焦点和缩放能力。
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isOpaque = true
        panel.backgroundColor = NSColor(white: 0.075, alpha: 1)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 380, height: 660)

        guard !positioned,
              let player = PlayerWindowController.shared.window
                  ?? NSApp.windows.first(where: { $0 !== panel && $0.title == session.windowTitle }),
              player !== panel,
              let visible = player.screen?.visibleFrame else { return }
        positioned = true
        keyMonitor.start(window: panel) { chord in
            guard let command = model.bindings.command(for: chord) else { return false }
            return PlayerCommands.perform(command, session: session,
                                          window: command == PlayerCommands.closeWindow ? panel : player)
        }
        panel.setContentSize(NSSize(width: 480, height: min(720, visible.height)))
        let gap: Double = 8
        let panelY = min(player.frame.maxY - panel.frame.height, visible.maxY - panel.frame.height)
        let rightX = player.frame.maxX + gap
        let leftX = player.frame.minX - gap - panel.frame.width
        let panelX = rightX + panel.frame.width <= visible.maxX ? rightX : max(visible.minX, leftX)
        panel.setFrameOrigin(CGPoint(x: panelX, y: max(visible.minY, panelY)))
    }
}

private struct NoSessionView: View {
    var body: some View {
        ContentUnavailableView("没有正在播放的内容", systemImage: "play.slash")
    }
}

/// 面板里的一组信息：玻璃卡片 + 标题 + 若干「名称 … 值」行。
private struct InfoGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.space(2)) {
            Text(title).themedFont(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rexCard()
    }
}

private struct InfoRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.colors.inkMuted.color)
            Spacer(minLength: theme.metrics.space(3))
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .themedFont(.subhead)
    }
}

// MARK: - 分集

struct EpisodesPanel: View {
    var onClose: (() -> Void)? = nil
    @Environment(PlaybackSession.self) private var session: PlaybackSession?
    @Environment(\.theme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选集").font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                Button {
                    if let onClose { onClose() }
                    else { dismissWindow(id: WorkspaceWindows.floatingPanel, value: PanelIDs.episodes) }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickablePointer()
                .accessibilityLabel("关闭选集")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            if let session {
                if session.siblings.isEmpty {
                    ContentUnavailableView("不是剧集", systemImage: "film")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(session.siblings) { ep in row(ep, session: session).id(ep.id) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .onAppear { proxy.scrollTo(session.item?.id, anchor: .center) }
                    }
                }
            } else {
                NoSessionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ ep: EmbyItem, session: PlaybackSession) -> some View {
        let isCurrent = ep.id == session.item?.id
        return Button {
            if !isCurrent { Task { await session.play(itemID: ep.id, resume: true) } }
            onClose?()
        } label: {
            HStack(spacing: 10) {
                EpisodeArtwork(episode: ep, client: session.client, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.episodeCode ?? "").themedFont(.caption).foregroundStyle(theme.colors.inkMuted.color)
                    Text(ep.displayName).themedFont(.subhead, weight: isCurrent ? .semibold : .regular).lineLimit(1)
                }
                Spacer()
                if let p = ep.progress, p > 0, !ep.isPlayed {
                    Text("\(Int(p * 100))%").themedFont(.caption).foregroundStyle(theme.colors.inkMuted.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isCurrent ? theme.colors.surfaceSelected.color : .clear,
                        in: RoundedRectangle(cornerRadius: theme.metrics.radiusMd, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(ClickablePlainButtonStyle())
        .help(ep.displayName)
    }
}

// MARK: - 媒体信息

private struct MediaInfoPanel: View {
    @Environment(PlaybackSession.self) private var session: PlaybackSession?
    @Environment(\.theme) private var theme

    var body: some View {
        if let session {
            ScrollView {
                VStack(spacing: theme.metrics.space(3)) {
                    InfoGroup(title: "播放") {
                        InfoRow("方式", session.stream?.method.title ?? (session.localURL != nil ? "本地文件" : "—"))
                        if let source = session.stream?.mediaSource {
                            InfoRow("容器", source.container?.uppercased() ?? "—")
                            if let bitrate = source.bitrate { InfoRow("码率", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
                            if let size = source.size { InfoRow("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        }
                        if let decoded = session.engine.videoDescription { InfoRow("解码输出", decoded) }
                    }
                    if let source = session.stream?.mediaSource {
                        if let video = source.videoStream {
                            InfoGroup(title: "视频") {
                                InfoRow("编码", [video.codec?.uppercased(), video.profile].compactMap { $0 }.joined(separator: " "))
                                if let w = video.width, let h = video.height { InfoRow("分辨率", "\(w) × \(h)") }
                                InfoRow("动态范围", MediaSummary(source: source).dynamicRange.title)
                                if let depth = video.bitDepth { InfoRow("位深", "\(depth) bit") }
                                if let fps = video.averageFrameRate { InfoRow("帧率", String(format: "%.3g fps", fps)) }
                            }
                        }
                        InfoGroup(title: "音频") { streamList(source.audioStreams, defaultIndex: source.defaultAudioStreamIndex) }
                        InfoGroup(title: "字幕") { streamList(source.subtitleStreams, defaultIndex: source.defaultSubtitleStreamIndex) }
                    }
                }
                .padding(theme.metrics.space(3))
            }
        } else {
            NoSessionView()
        }
    }

    @ViewBuilder
    private func streamList(_ streams: [MediaStream], defaultIndex: Int?) -> some View {
        if streams.isEmpty { Text("无").themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color) }
        ForEach(Array(streams.enumerated()), id: \.offset) { _, s in
            HStack {
                Text(s.displayTitle ?? s.title ?? s.codec ?? "未知").themedFont(.subhead).lineLimit(2)
                Spacer()
                if s.isExternal == true { Badge(BadgeModel("外挂")) }
                if s.index == defaultIndex { Badge(BadgeModel("默认")) }
            }
        }
    }
}

// MARK: - 播放诊断

/// 每秒刷新一次；面板不显示时 TimelineView 不运行，没有额外开销。
private struct PlaybackDebugPanel: View {
    @Environment(PlaybackSession.self) private var session: PlaybackSession?
    @Environment(\.theme) private var theme

    var body: some View {
        if let session {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let d = session.engine.diagnostics()
                let engine = session.engine
                ScrollView {
                    InfoGroup(title: "播放状态") {
                        InfoRow("状态", "\(engine.state)")
                        InfoRow("播放方式", session.stream?.method.title ?? (session.localURL != nil ? "本地文件" : "—"))
                        // 只显示主机和路径，地址里的访问令牌不显示。
                        InfoRow("来源", session.stream.map { "\($0.url.host() ?? "")\($0.url.path)" } ?? session.localURL?.lastPathComponent ?? "—")
                        InfoRow("画面", engine.presentationSize == .zero ? "—"
                            : "\(Int(engine.presentationSize.width)) × \(Int(engine.presentationSize.height))")
                        InfoRow("指示码率", d.indicatedBitrate.map { String(format: "%.2f Mbps", $0 / 1e6) } ?? "—")
                        InfoRow("实测吞吐", d.observedBitrate.map { String(format: "%.2f Mbps", $0 / 1e6) } ?? "—")
                        InfoRow("丢帧", d.droppedFrames.map(String.init) ?? "—")
                        InfoRow("点击到首帧", d.startupMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                        InfoRow("起播阶段", d.startupStage ?? "—")
                        InfoRow("类型", d.playbackType ?? "—")
                        if let error = d.lastError { InfoRow("最近错误", error) }
                    }
                    .padding(theme.metrics.space(3))
                }
            }
        } else {
            NoSessionView()
        }
    }
}
