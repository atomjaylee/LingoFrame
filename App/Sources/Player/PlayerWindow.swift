import DesignSystem
import LearningCore
import MediaServerKit
import PlaybackKit
import SwiftUI
import Workspace

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()
    private(set) var window: NSWindow?
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
    @State private var menuTracking = false
    @State private var fittedVideoSize: CGSize = .zero

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
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking = true
            hideTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
            poke()
        }
        .onChange(of: session.engine.state) { _, state in
            if state == .ended { session.handleEnded() }
            poke()
        }
        .onChange(of: session.engine.presentationSize) { _, size in fitWindow(to: size) }
        .onChange(of: window) { _, _ in fitWindow(to: session.engine.presentationSize) }
    }

    /// 首帧按视频实际分辨率设置窗口；超出屏幕时等比例缩小，之后用户拖动只锁定比例。
    private func fitWindow(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0, !window.styleMask.contains(.fullScreen) else { return }
        PlayerWindowController.shared.setAspectRatio(size)
        guard size != fittedVideoSize else { return }
        fittedVideoSize = size
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let maximum = CGSize(width: max(720, visible.width - 80), height: max(332, visible.height - 80))
        let contentSize = VideoWindowSizing.contentSize(for: size,
                                                        backingScale: window.backingScaleFactor,
                                                        maximum: maximum)
        guard contentSize != .zero else { return }
        let frameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        var frame = window.frame
        guard abs(frameSize.height - frame.height) > 1 || abs(frameSize.width - frame.width) > 1 else { return }
        frame.origin.x += (frame.width - frameSize.width) / 2
        frame.origin.y += frame.height - frameSize.height
        frame.size = frameSize
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    private var stage: some View {
        ZStack {
            // 单击只唤出控制栏，双击播放/暂停；按钮、字幕单词和查词卡自己处理点击。
            Color.clear
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded {
                    poke()
                    if let command = model.bindings.command(for: Gesture(.doubleClick), on: .video) {
                        _ = PlayerCommands.perform(command, session: session, window: window)
                    }
                })
                .simultaneousGesture(TapGesture().onEnded {
                    poke()
                    if let command = model.bindings.command(for: Gesture(.click), on: .video) {
                        _ = PlayerCommands.perform(command, session: session, window: window)
                    }
                })
            BitmapSubtitleOverlay(engine: session.engine)
                .allowsHitTesting(false)
            StatusOverlay(session: session)
            if let feedback = session.seekFeedback {
                SeekFeedbackOverlay(feedback: feedback)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
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
            PlaybackSubtitleOverlay(engine: session.engine)
                .padding(.horizontal, 64)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, controlsVisible ? 118 : 40)
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
        .animation(.easeOut(duration: 0.15), value: session.seekFeedback)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                mouseInside = true
                poke()
            case .ended:
                // 鼠标移出画面：控制条淡出（正在拖进度条时保留）。
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
            guard !Task.isCancelled, !isScrubbing, !menuTracking else { return }
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

private struct SeekFeedbackOverlay: View {
    let feedback: SeekFeedback

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 7) {
                Image(systemName: symbolName)
                    .font(.system(size: 30, weight: .medium))
                Text(feedback.direction == .forward ? "前进 \(feedback.seconds) 秒" : "后退 \(feedback.seconds) 秒")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(width: 128, height: 88)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
            .position(x: geometry.size.width * (feedback.direction == .forward ? 0.72 : 0.28),
                      y: geometry.size.height * 0.48)
        }
    }

    private var symbolName: String {
        let prefix = feedback.direction == .forward ? "goforward" : "gobackward"
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(feedback.seconds)
            ? "\(prefix).\(feedback.seconds)" : prefix
    }
}

// MARK: - 状态层：加载中、出错、播放结束

private struct StatusOverlay: View {
    let session: PlaybackSession
    @Environment(\.theme) private var theme

    var body: some View {
        let engine = session.engine
        let state = engine.state
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
        } else if state == .idle || engine.isWaitingForMedia {
            DelayedLoadingOverlay(label: engine.isSeeking ? "正在跳转…" : engine.isBuffering ? "正在缓冲…" : "正在加载…")
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

/// 缓存内的瞬时跳转不闪圈；真正等待网络或解码时才显示，并在恢复后立即移除。
private struct DelayedLoadingOverlay: View {
    let label: String
    @State private var visible = false

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(label).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 15)
        .frame(height: 42)
        .background(.black.opacity(0.24), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: visible)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            visible = true
        }
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
    @State private var hovering = false

    var body: some View {
        Button { window?.performClose(nil) } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                Text("关闭").font(.system(size: 12, weight: .medium))
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 27)
            .background(.black.opacity(hovering ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.22 : 0.13), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickablePointer()
        .onHover { hovering = $0 }
        .hoverTransition(value: hovering)
        .keyboardShortcut("w", modifiers: .command)
        .help("关闭播放窗口（⌘W）")
    }
}

// MARK: - 控制面板

/// 经典双行控制器：上排进度，下排音量、居中播放和右侧设置。
private struct ControlBar: View {
    let session: PlaybackSession
    @Binding var isScrubbing: Bool
    let window: NSWindow?
    @Environment(\.openWindow) private var openWindow
    @State private var speedHovered = false

    private var engine: NativePlayerEngine { session.engine }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                TimeText(engine: engine, showsDuration: false)
                Scrubber(engine: engine, isScrubbing: $isScrubbing)
                TimeText(engine: engine, showsDuration: true)
            }
            GeometryReader { geometry in
                let compact = geometry.size.width < 860
                ZStack {
                    HStack(spacing: 6) {
                        PlayerControlButton(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                            size: 16, label: engine.isMuted ? "取消静音" : "静音") {
                            session.toggleMute()
                        }
                        ThinSlider(value: Binding(get: { engine.isMuted ? 0 : Double(engine.volume) },
                                                  set: { engine.volume = Float($0); engine.isMuted = false }))
                            .frame(width: compact ? 70 : 120)
                            .accessibilityLabel("音量")
                        Spacer()
                    }
                    HStack(spacing: compact ? 4 : 14) {
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
                    HStack(spacing: compact ? 6 : 8) {
                        Spacer()
                        speedMenu(compact: compact)
                        if !compact { separator }
                        if !engine.audioOptions.isEmpty { audioTrackMenu }
                        if !engine.subtitleOptions.isEmpty { subtitleTrackMenu }
                        if !compact { separator }
                        icon("viewfinder", size: 17,
                             label: window?.styleMask.contains(.fullScreen) == true ? "退出全屏（回车）" : "全屏（回车）") {
                            window?.toggleFullScreen(nil)
                        }
                        PlayerControlButton(systemName: "list.bullet", size: 17, label: "打开字幕窗口") {
                            openWindow(id: WorkspaceWindows.floatingPanel, value: PanelIDs.transcript)
                        }
                    }
                }
                .frame(height: 44)
            }
            .frame(height: 44)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func icon(_ name: String, size: Double, label: String, action: @escaping () -> Void) -> some View {
        PlayerControlButton(systemName: name, size: size, label: label, action: action)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.24)).frame(width: 1, height: 18)
    }

    private func speedMenu(compact: Bool) -> some View {
        Menu { rateOptions } label: {
            HStack(spacing: 5) {
                Text(engine.rate == engine.rate.rounded() ? String(format: "%.1f×", engine.rate)
                     : String(format: "%g×", engine.rate))
                    .monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: compact ? 54 : 64, height: 34)
            .background(.white.opacity(speedHovered ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).clickablePointer().menuIndicator(.hidden).fixedSize()
        .onHover { speedHovered = $0 }
        .hoverTransition(value: speedHovered)
        .help("播放速度（[ 和 ] 调速度）")
        .accessibilityLabel("播放速度")
    }

    private var rateOptions: some View {
        ForEach(PlaybackSession.rateSteps, id: \.self) { rate in
            Button { session.setRate(rate) } label: {
                if abs(rate - engine.rate) < 0.001 { Label(String(format: "%g×", rate), systemImage: "checkmark") }
                else { Text(String(format: "%g×", rate)) }
            }
        }
    }

    private var audioOptions: some View {
        Picker("音轨", selection: Binding<Int?>(
            get: { engine.selectedAudioID },
            set: { if let id = $0 { engine.selectAudio(id) } }
        )) {
            ForEach(engine.audioOptions) { option in
                Text(option.title).tag(Optional(option.id))
            }
        }
        .pickerStyle(.inline)
    }

    private var audioTrackMenu: some View {
        Menu { audioOptions } label: {
            HoverControlIcon(systemName: "waveform", size: 16)
        }
        .menuStyle(.button).buttonStyle(.plain).clickablePointer().menuIndicator(.hidden).fixedSize()
        .help("当前音轨：" + (engine.audioOptions.first { $0.id == engine.selectedAudioID }?.title ?? "未选择"))
        .accessibilityLabel("选择音轨")
    }

    private var currentSubtitleID: Int? {
        engine.selectedSubtitleID
    }

    private var subtitleOptions: some View {
        Picker("字幕", selection: Binding<Int?>(
            get: { currentSubtitleID },
            set: { session.selectPlaybackSubtitle($0) }
        )) {
            Text("关闭").tag(nil as Int?)
            ForEach(engine.subtitleOptions) { option in
                Text(option.title).tag(Optional(option.id))
            }
        }
        .pickerStyle(.inline)
    }

    private var subtitleTrackMenu: some View {
        Menu { subtitleOptions } label: {
            HoverControlIcon(systemName: "captions.bubble.fill", size: 16)
        }
        .menuStyle(.button).buttonStyle(.plain).clickablePointer().menuIndicator(.hidden).fixedSize()
        .help("当前字幕：" + (engine.subtitleOptions.first { $0.id == currentSubtitleID }?.title ?? "关闭"))
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
    @Environment(\.isEnabled) private var isEnabled

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
        .buttonStyle(.plain).clickablePointer()
        .onHover { hovering = $0 && isEnabled }
        .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
        .hoverTransition(value: hovering)
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
            .hoverTransition(value: hovering)
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
    let engine: NativePlayerEngine
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
                    let start = min(max(range.lowerBound / duration, 0), 1)
                    let end = min(max(range.upperBound / duration, start), 1)
                    Capsule().fill(.white.opacity(0.4))
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
            "缓存 \(TimeFormat.clock($0.lowerBound)) 至 \(TimeFormat.clock($0.upperBound))"
        }.joined(separator: "，")
    }
}

private struct TimeText: View {
    let engine: NativePlayerEngine
    let showsDuration: Bool

    var body: some View {
        Text(TimeFormat.clock(showsDuration ? engine.duration : engine.currentTime))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .frame(minWidth: 44, alignment: showsDuration ? .trailing : .leading)
    }
}
