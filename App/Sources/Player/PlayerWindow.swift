import DesignSystem
import LearningCore
import MediaServerKit
import PlaybackKit
import SwiftUI
import Workspace

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()
    private var window: NSWindow?
    private var frameAspectRatio: Double?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(1440, screen.width), height: min(900, screen.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 332)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = self
            window.center()
            self.window = window
        }
        if window?.contentViewController == nil {
            window?.contentViewController = NSHostingController(
                rootView: AnyView(PlayerWindowHost().ignoresSafeArea().appEnvironment(model))
            )
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setAspectRatio(_ size: CGSize) {
        frameAspectRatio = size.width > 0 && size.height > 0 ? size.width / size.height : nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // 原生窗口关闭不会销毁托管视图；主动结束会话并移除旧视图，重开时重新执行加载任务。
        model?.activeSession?.close()
        model?.activeSession = nil
        closing.contentViewController = nil
        frameAspectRatio = nil
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let ratio = frameAspectRatio, ratio > 0, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let current = sender.frame.size
        if abs(frameSize.width - current.width) >= abs(frameSize.height - current.height) {
            return NSSize(width: frameSize.width, height: frameSize.width / ratio)
        }
        return NSSize(width: frameSize.height * ratio, height: frameSize.height)
    }
}

private struct PlayerWindowHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PlayerWindow(request: model.playRequest, requestRevision: model.playRequestRevision)
    }
}

struct PlayerWindow: View {
    let request: PlayRequest?
    let requestRevision: UInt64
    @Environment(AppModel.self) private var model
    @State private var session: PlaybackSession?

    var body: some View {
        ZStack {
            Color.black
            if let session { PlayerScreen(session: session) }
        }
        .frame(minWidth: 720, minHeight: 332)
        .task(id: requestRevision) {
            guard !Task.isCancelled, let request else { return }
            let serverID = request.serverID
            let prepared: PreparedPlayback? = if case .emby(let serverID, let itemID, let resume) = request {
                model.takePreparedPlayback(serverID: serverID, itemID: itemID, resume: resume)
            } else {
                nil
            }
            let s: PlaybackSession
            if let session, session.serverID == serverID {
                s = session
            } else {
                session?.close()
                s = PlaybackSession(client: model.server(serverID)?.client, serverID: serverID,
                                    engine: model.playbackEngine)
            }
            session = s
            model.activeSession = s
            await s.start(request, prepared: prepared)
        }
        .onDisappear {
            guard let s = session, model.activeSession === s else { return }
            s.close()
            model.activeSession = nil
        }
    }
}

private extension PlayRequest {
    var serverID: String? {
        switch self {
        case .emby(let serverID, _, _): serverID
        case .local: nil
        }
    }
}

/// 播放窗口只承载视频；字幕与学习内容在独立窗口中显示，不改变主窗口尺寸。
private struct PlayerScreen: View {
    let session: PlaybackSession
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    @State private var keyMonitor = KeyMonitor()
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>?
    /// 鼠标在画面上 / 在控制面板上。控制条跟着鼠标出现和消失（像 Infuse 一样）。
    @State private var mouseInside = false
    @State private var overControls = false
    @State private var lookup: WordLookup?

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(engine: session.engine)
            if session.engine.state == .idle
                || (session.engine.state == .loading && session.engine.presentationSize == .zero) {
                Color.black
            }
            stage
        }
        .background(Color.black)
        .environment(session)
        .environment(\.colorScheme, .dark)
        .navigationTitle(session.windowTitle)
        .toolbar(.hidden, for: .windowToolbar)
        .background(WindowAccessor { window = $0 })
        .onChange(of: window) { _, window in
            guard let window else { return }
            window.isMovableByWindowBackground = true
            // 标题栏跟播放画面一样用深色。
            window.appearance = NSAppearance(named: .darkAqua)
            keyMonitor.start(window: window) { chord in
                guard let command = model.bindings.command(for: chord) else { return false }
                poke()
                return PlayerCommands.perform(command, session: session, window: window)
            }
        }
        .onDisappear { keyMonitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window, note.object as? NSWindow === window { model.activeSession = session }
        }
        .onChange(of: session.engine.state) { _, state in
            if state == .ended { session.handleEnded() }
            poke()
        }
        .onChange(of: session.engine.presentationSize) { _, size in fitWindow(to: size) }
        .onChange(of: window) { _, _ in fitWindow(to: session.engine.presentationSize) }
    }

    /// 像 Infuse 一样让窗口比例跟视频一致：宽度不变、按视频比例调高度（放不下就整体缩小），之后拖动缩放也保持比例。
    private func fitWindow(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0, !window.styleMask.contains(.fullScreen) else { return }
        PlayerWindowController.shared.setAspectRatio(size)
        let ratio = size.height / size.width
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var frame = window.frame
        var width = frame.width
        var height = (width * ratio).rounded()
        if height > visible.height {
            height = visible.height
            width = (height / ratio).rounded()
        }
        guard abs(height - frame.height) > 1 || abs(width - frame.width) > 1 else { return }
        // 保持窗口顶边位置不动。
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: width, height: height)
        frame.origin.y = max(frame.origin.y, visible.minY)
        window.setFrame(frame, display: true)
        Task { @MainActor in
            await Task.yield()
            session.engine.refreshVideoSurface()
        }
    }

    private var stage: some View {
        ZStack {
            // 单击 / 双击只作用在画面空白处：按钮、单词、查词卡各自处理点击，不会连带触发暂停。
            Color.clear
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { window?.toggleFullScreen(nil) })
                .simultaneousGesture(TapGesture().onEnded {
                    if lookup != nil { lookup = nil; return }
                    if let command = model.bindings.command(for: Gesture(.click), on: .video) {
                        _ = PlayerCommands.perform(command, session: session, window: window)
                    }
                })
            StatusOverlay(session: session)
            if let hud = session.hud {
                Text(hud)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .rexGlass(cornerRadius: 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(false)
            SubtitleOverlay(session: session, lookup: $lookup)
                .padding(.horizontal, 64)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, controlsVisible ? 118 : 40)
            if let lookup {
                LookupCard(lookup: lookup) {
                    self.lookup = nil
                    session.engine.play()
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, controlsVisible ? 224 : 140)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            VStack(spacing: 0) {
                HStack {
                    CloseButton(window: window)
                        .onHover { overControls = $0 }
                    Spacer()
                }
                .padding(10)
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : -6)
                Spacer(minLength: 0)
                ControlBar(session: session, isScrubbing: $isScrubbing, window: window)
                    .onHover {
                        overControls = $0
                        if $0 { hideTask?.cancel() } else { scheduleHide(after: 0.7) }
                    }
                    .padding(.bottom, 10)
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 10)
            }
            .allowsHitTesting(controlsVisible)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.15), value: session.hud)
        .animation(.easeOut(duration: 0.15), value: lookup)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                mouseInside = true
                poke()
            case .ended:
                // 鼠标移出画面：控制条淡出（正在拖进度条或查词时保留）。
                mouseInside = false
                scheduleHide(after: 0.12)
            }
        }
    }

    /// 鼠标在画面上移动或按了快捷键：显示控制条，1.1 秒没动静再淡出。
    /// 鼠标停在控制面板上时不隐藏；暂停时只要鼠标还在画面上也不隐藏。字幕一直显示。
    private func poke() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide(after: 1.1)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !isScrubbing, lookup == nil else { return }
            if mouseInside {
                guard session.engine.state == .playing, !overControls else { return }
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            } else {
                controlsVisible = false
            }
        }
    }
}

// MARK: - 状态层：加载中、出错、播放结束

private struct StatusOverlay: View {
    let session: PlaybackSession
    @Environment(\.theme) private var theme

    var body: some View {
        let state = session.engine.state
        if let message = session.errorMessage ?? state.failureMessage {
            card {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 32))
                Text("无法播放").themedFont(.title2)
                Text(message).themedFont(.body).foregroundStyle(theme.colors.inkMuted.color)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button { Task { await session.retry() } } label: { Text("重试").frame(minWidth: 160) }
                    .buttonStyle(RexPrimaryButtonStyle())
                    .padding(.top, theme.metrics.space(2))
                if let next = session.nextItem {
                    Button { Task { await session.play(itemID: next.id, resume: false) } } label: {
                        Label("播放下一集", systemImage: "forward.end.fill").frame(minWidth: 160)
                    }
                    .buttonStyle(RexTextButtonStyle())
                }
            }
        } else if state == .loading || state == .idle {
            ProgressView().controlSize(.large).tint(.white)
        } else if state == .ended {
            card {
                if let next = session.nextItem {
                    Text("下一集").themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color)
                    Text([next.episodeCode, next.name].compactMap { $0 }.joined(separator: "  ")).themedFont(.title2)
                    Button { Task { await session.play(itemID: next.id, resume: false) } } label: {
                        PrimaryButtonLabel("播放下一集")
                    }
                    .buttonStyle(RexPrimaryButtonStyle())
                    .padding(.top, theme.metrics.space(2))
                } else {
                    Text("播放完毕").themedFont(.title2)
                    Button { session.engine.play() } label: { PrimaryButtonLabel("重新播放", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(RexPrimaryButtonStyle())
                        .padding(.top, theme.metrics.space(2))
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: theme.metrics.space(2)) { content() }
            .foregroundStyle(theme.colors.ink.color)
            .padding(theme.metrics.space(8))
            .background(theme.colors.popoverFill.color, in: RoundedRectangle(cornerRadius: theme.metrics.radiusXl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.metrics.radiusXl, style: .continuous)
                .strokeBorder(theme.colors.glassStroke.color, lineWidth: 1))
    }
}

extension PlaybackState {
    var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}

// MARK: - 关闭按钮

/// 左上角的「✕ 关闭」，和 Infuse 一样只有这一个；片名在窗口标题栏里。
private struct CloseButton: View {
    let window: NSWindow?

    var body: some View {
        Button { window?.performClose(nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                Text("关闭").font(.system(size: 13, weight: .medium))
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 31)
            .background(Color(white: 0.12).opacity(0.78), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("w", modifiers: .command)
        .help("关闭播放窗口（⌘W）")
    }
}

// MARK: - 控制面板

/// Infuse 式底部控制层：进度在上、操作在下，浮在渐变遮罩上，不再使用厚重的悬浮卡片。
private struct ControlBar: View {
    let session: PlaybackSession
    @Binding var isScrubbing: Bool
    let window: NSWindow?
    @Environment(\.openWindow) private var openWindow

    private var engine: MPVPlayerEngine { session.engine }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                TimeText(engine: engine, remaining: false)
                Scrubber(engine: engine, isScrubbing: $isScrubbing)
                TimeText(engine: engine, remaining: true)
            }
            ZStack {
                HStack(spacing: 6) {
                    PlayerControlButton(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                        size: 16, label: engine.isMuted ? "取消静音" : "静音") {
                        session.toggleMute()
                    }
                    ThinSlider(value: Binding(get: { engine.isMuted ? 0 : Double(engine.volume) },
                                              set: { engine.volume = Float($0); engine.isMuted = false }))
                        .frame(width: 120)
                        .accessibilityLabel("音量")
                    Spacer()
                }
                HStack(spacing: 14) {
                    icon("backward.end.fill", size: 17, label: "上一集") {
                        if let prev = session.previousItem { Task { await session.play(itemID: prev.id, resume: true) } }
                    }
                    .disabled(session.previousItem == nil)
                    .opacity(session.previousItem == nil ? 0.35 : 1)
                    icon("gobackward.10", size: 20, label: "后退 10 秒（⇧←）") { session.seek(by: -10) }
                    PlayerControlButton(systemName: engine.state == .playing ? "pause.fill" : "play.fill", size: 22,
                                        label: engine.state == .playing ? "暂停（空格）" : "播放（空格）",
                                        prominent: true) { session.togglePlay() }
                    icon("goforward.10", size: 20, label: "前进 10 秒（⇧→）") { session.seek(by: 10) }
                    icon("forward.end.fill", size: 17, label: "下一集") {
                        if let next = session.nextItem { Task { await session.play(itemID: next.id, resume: true) } }
                    }
                    .disabled(session.nextItem == nil)
                    .opacity(session.nextItem == nil ? 0.35 : 1)
                }
                HStack(spacing: 10) {
                    Spacer()
                    if !engine.subtitleOptions.isEmpty { subtitleTrackMenu }
                    if engine.audioOptions.count > 1 { audioTrackMenu }
                    settingsMenu
                    icon(window?.styleMask.contains(.fullScreen) == true ? "arrow.down.right.and.arrow.up.left"
                         : "arrow.up.left.and.arrow.down.right", size: 16, label: "全屏（双击画面）") { window?.toggleFullScreen(nil) }
                    PlayerControlButton(systemName: "list.bullet", size: 17, label: "打开字幕窗口") {
                        openWindow(id: WorkspaceWindows.floatingPanel, value: PanelIDs.transcript)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .padding(.bottom, 4)
        .frame(maxWidth: 980)
    }

    private func icon(_ name: String, size: Double, label: String, action: @escaping () -> Void) -> some View {
        PlayerControlButton(systemName: name, size: size, label: label, action: action)
    }

    /// 设置：播放速度、音轨。
    private var settingsMenu: some View {
        Menu {
            Menu("速度 \(String(format: "%g×", engine.rate))") {
                ForEach(PlaybackSession.rateSteps, id: \.self) { rate in
                    Button {
                        session.setRate(rate)
                    } label: {
                        if abs(rate - engine.rate) < 0.001 { Label(String(format: "%g×", rate), systemImage: "checkmark") }
                        else { Text(String(format: "%g×", rate)) }
                    }
                }
            }
        } label: {
            HoverControlIcon(systemName: "gearshape.fill", size: 17)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度（[ 和 ] 调速度）")
    }

    private var audioTrackMenu: some View {
        Menu {
            ForEach(engine.audioOptions) { option in
                Button {
                    engine.selectAudio(option.id)
                } label: {
                    if option.id == engine.selectedAudioID { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            HoverControlIcon(systemName: "speaker.wave.2.fill", size: 16)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择音轨")
        .accessibilityLabel("选择音轨")
    }

    private var subtitleTrackMenu: some View {
        Menu {
            Button {
                session.selectPlaybackSubtitle(nil)
            } label: {
                if engine.selectedSubtitleID == nil { Label("关闭", systemImage: "checkmark") }
                else { Text("关闭") }
            }
            Divider()
            ForEach(engine.subtitleOptions) { option in
                Button {
                    session.selectPlaybackSubtitle(option.id)
                } label: {
                    if option.id == engine.selectedSubtitleID { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            HoverControlIcon(systemName: "captions.bubble.fill", size: 16)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择字幕")
        .accessibilityLabel("选择字幕")
    }

}

private struct PlayerControlButton: View {
    let systemName: String
    let size: Double
    let label: String
    var prominent = false
    var foreground: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: prominent ? 42 : 34, height: prominent ? 42 : 34)
                .background(.white.opacity(hovering ? 0.2 : prominent ? 0.1 : 0), in: Circle())
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.06 : 1)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HoverControlIcon: View {
    let systemName: String
    let size: Double
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(.white.opacity(hovering ? 0.2 : 0), in: Circle())
            .contentShape(Circle())
            .scaleEffect(hovering ? 1.06 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// 细滑块：4 点高的轨道 + 16 点白色圆点，用于音量。
private struct ThinSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let v = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(4, geo.size.width * v), height: 4)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: geo.size.width * v - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in value = min(max(g.location.x / geo.size.width, 0), 1) })
        }
        .frame(height: 18)
    }
}

/// 主字幕、副字幕两个选择菜单，控制条和信息面板共用。
struct SubtitleTrackMenus: View {
    let session: PlaybackSession

    var body: some View {
        Menu("主字幕：\(session.primarySubtitle?.title ?? "无")") {
            Button("无") { session.selectPrimarySubtitle(nil) }
            ForEach(session.subtitleOptions) { option in
                Button(option.title) { session.selectPrimarySubtitle(option) }
            }
        }
        Menu("副字幕：\(session.secondarySubtitle?.title ?? "无")") {
            Button("无") { session.selectSecondarySubtitle(nil) }
            ForEach(session.subtitleOptions) { option in
                Button(option.title) { session.selectSecondarySubtitle(option) }
            }
        }
    }
}

/// 进度条：两端圆的胶囊，悬停时加粗并显示拖动点。播放时间每 0.5 秒变一次，只让这个小视图刷新。
private struct Scrubber: View {
    let engine: MPVPlayerEngine
    @Binding var isScrubbing: Bool
    @State private var dragValue: Double = 0
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let duration = max(engine.duration, 1)
            let played = min(max((isScrubbing ? dragValue : engine.currentTime) / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                ForEach(engine.bufferedRanges, id: \.self) { range in
                    let start = min(max(range.start.seconds / duration, 0), 1)
                    let end = min(max(range.end.seconds / duration, start), 1)
                    Capsule().fill(.white.opacity(0.72))
                        .frame(width: geo.size.width * (end - start), height: 4)
                        .offset(x: geo.size.width * start)
                }
                if played > 0 {
                    Capsule().fill(theme.colors.accentAmber.color)
                        .frame(width: max(4, geo.size.width * played), height: 4)
                }
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: geo.size.width * played - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    isScrubbing = true
                    dragValue = min(max(g.location.x / geo.size.width, 0), 1) * duration
                }
                .onEnded { _ in
                    Task {
                        await engine.seek(to: dragValue)
                        isScrubbing = false
                    }
                })
        }
        .frame(height: 18)
        .disabled(engine.duration <= 0)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(TimeFormat.clock(engine.currentTime)) / \(TimeFormat.clock(engine.duration))，\(cachedRangeDescription)")
    }

    private var cachedRangeDescription: String {
        engine.bufferedRanges.isEmpty ? "暂无可快速跳转的缓存" : engine.bufferedRanges.map {
            "缓存 \(TimeFormat.clock($0.start.seconds)) 至 \(TimeFormat.clock($0.end.seconds))"
        }.joined(separator: "，")
    }
}

private struct TimeText: View {
    let engine: MPVPlayerEngine
    let remaining: Bool

    var body: some View {
        Text(remaining ? "-" + TimeFormat.clock(max(engine.duration - engine.currentTime, 0)) : TimeFormat.clock(engine.currentTime))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .frame(minWidth: 44, alignment: remaining ? .trailing : .leading)
    }
}
