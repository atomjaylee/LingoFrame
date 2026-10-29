import DesignSystem
import LearningCore
import MediaServerKit
import PlaybackKit
import SwiftUI
import Workspace

struct PlayerWindow: View {
    static let id = "player"
    let request: PlayRequest?
    let requestRevision: UInt64
    @Environment(AppModel.self) private var model
    @State private var session: PlaybackSession?

    var body: some View {
        ZStack {
            Color.black
            if let session { PlayerScreen(session: session) }
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: requestRevision) {
            guard let request else { return }
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
                s = PlaybackSession(client: model.server(serverID)?.client, serverID: serverID,
                                    engine: model.playbackEngine)
            }
            session = s
            model.activeSession = s
            await s.start(request, prepared: prepared)
        }
        .onDisappear {
            guard let s = session else { return }
            Task {
                await s.close()
                if model.activeSession === s { model.activeSession = nil }
            }
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

/// 播放窗口，照设计稿「精听播放」：左边视频舞台（标题、双语字幕、浮动控制条），右边浮动的学习面板（剧本 / 分集 / 信息）。
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
    @AppStorage("player.panelShown") private var panelShown = true

    var body: some View {
        GeometryReader { geo in
            let panelWidth: Double = panelShown && geo.size.width > 760 ? 350 : 0
            ZStack(alignment: .topLeading) {
                // 画面始终铺满整个窗口（窗口比例跟着视频走，没有黑边）；面板、字幕、控制条都浮在画面上。
                Color.black
                PlayerSurface(engine: session.engine)
                stage
                    .frame(width: geo.size.width - panelWidth, height: geo.size.height)
                if panelWidth > 0 {
                    LearningPanel(session: session, hide: { withAnimation(.easeOut(duration: 0.2)) { panelShown = false } })
                        .frame(width: 340)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
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
        window.contentAspectRatio = size
        let ratio = size.height / size.width
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var content = window.contentRect(forFrameRect: window.frame)
        var width = content.width
        var height = (width * ratio).rounded()
        if height > visible.height {
            height = visible.height
            width = (height / ratio).rounded()
        }
        guard abs(height - content.height) > 1 || abs(width - content.width) > 1 else { return }
        // 保持窗口顶边位置不动。
        content.origin.y += content.height - height
        content.size = CGSize(width: width, height: height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.y = max(frame.origin.y, visible.minY)
        window.setFrame(frame, display: true, animate: true)
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
                ControlBar(session: session, isScrubbing: $isScrubbing, panelShown: $panelShown, window: window)
                    .onHover { overControls = $0; if $0 { poke() } }
                    .padding(.bottom, 16)
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 14)
                    .scaleEffect(controlsVisible ? 1 : 0.985, anchor: .bottom)
            }
            .allowsHitTesting(controlsVisible)
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: controlsVisible ? 0.18 : 0.32), value: controlsVisible)
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
                scheduleHide(after: 0.25)
            }
        }
    }

    /// 鼠标在画面上移动或按了快捷键：显示控制条，2.5 秒没动静再淡出。
    /// 鼠标停在控制面板上时不隐藏；暂停时只要鼠标还在画面上也不隐藏。字幕一直显示。
    private func poke() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide(after: 2.5)
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

/// 底部居中的深色面板（参考 Infuse），只管视频播放：上一行左边音量、中间上一集 / 后退 10 秒 / 播放 / 前进 10 秒 / 下一集、
/// 右边设置 / 全屏 / 字幕栏开关；下一行已播时间、进度条、剩余时间。逐句、循环等学习控制都在右侧字幕栏里。
private struct ControlBar: View {
    let session: PlaybackSession
    @Binding var isScrubbing: Bool
    @Binding var panelShown: Bool
    let window: NSWindow?

    private var engine: MPVPlayerEngine { session.engine }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 8) {
                    Button { session.toggleMute() } label: {
                        Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 15)).frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.isMuted ? "取消静音" : "静音")
                    ThinSlider(value: Binding(get: { engine.isMuted ? 0 : Double(engine.volume) },
                                              set: { engine.volume = Float($0); engine.isMuted = false }))
                        .frame(width: 118)
                        .accessibilityLabel("音量")
                    Spacer()
                }
                HStack(spacing: 22) {
                    icon("backward.end.fill", size: 17, label: "上一集") {
                        if let prev = session.previousItem { Task { await session.play(itemID: prev.id, resume: true) } }
                    }
                    .disabled(session.previousItem == nil)
                    .opacity(session.previousItem == nil ? 0.35 : 1)
                    icon("gobackward.10", size: 20, label: "后退 10 秒（⇧←）") { session.seek(by: -10) }
                    icon(engine.state == .playing ? "pause.fill" : "play.fill", size: 24,
                         label: engine.state == .playing ? "暂停（空格）" : "播放（空格）") { session.togglePlay() }
                    icon("goforward.10", size: 20, label: "前进 10 秒（⇧→）") { session.seek(by: 10) }
                    icon("forward.end.fill", size: 17, label: "下一集") {
                        if let next = session.nextItem { Task { await session.play(itemID: next.id, resume: true) } }
                    }
                    .disabled(session.nextItem == nil)
                    .opacity(session.nextItem == nil ? 0.35 : 1)
                }
                HStack(spacing: 18) {
                    Spacer()
                    settingsMenu
                    icon(window?.styleMask.contains(.fullScreen) == true ? "arrow.down.right.and.arrow.up.left"
                         : "arrow.up.left.and.arrow.down.right", size: 16, label: "全屏（双击画面）") { window?.toggleFullScreen(nil) }
                    Button { withAnimation(.easeOut(duration: 0.2)) { panelShown.toggle() } } label: {
                        Image(systemName: "list.bullet").font(.system(size: 17, weight: .medium))
                            .foregroundStyle(panelShown ? Color(red: 1, green: 0.68, blue: 0.03) : .white)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(panelShown ? "收起字幕栏" : "显示字幕栏")
                }
            }
            HStack(spacing: 14) {
                TimeText(engine: engine, remaining: false)
                Scrubber(engine: engine, isScrubbing: $isScrubbing)
                TimeText(engine: engine, remaining: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(width: 620)
        .background(Color(white: 0.11).opacity(0.84), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func icon(_ name: String, size: Double, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .medium))
                .frame(width: max(28, size + 6), height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
            if engine.audioOptions.count > 1 {
                Menu("音轨") {
                    ForEach(engine.audioOptions) { option in
                        Button {
                            engine.selectAudio(option.id)
                        } label: {
                            if option.id == engine.selectedAudioID { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 17))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度和音轨（[ 和 ] 调速度）")
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

    var body: some View {
        GeometryReader { geo in
            let duration = max(engine.duration, 1)
            let value = min(max((isScrubbing ? dragValue : engine.currentTime) / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(4, geo.size.width * value), height: 4)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: geo.size.width * value - 8)
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
        .accessibilityValue("\(TimeFormat.clock(engine.currentTime)) / \(TimeFormat.clock(engine.duration))")
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
