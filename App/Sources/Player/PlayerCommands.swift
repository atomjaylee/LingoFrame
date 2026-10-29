import AppKit
import LearningCore
import SwiftUI

/// 播放器专用的命令和按键。所有按键先转成 KeyChord，再通过绑定表（Bindings）查到命令，
/// 所以以后用户改快捷键只需要改绑定表，这里的执行逻辑不用动。
enum PlayerCommands {
    static let volumeUp: CommandID = "playback.volume-up"
    static let volumeDown: CommandID = "playback.volume-down"
    static let toggleMute: CommandID = "playback.toggle-mute"
    static let seekForward: CommandID = "playback.seek-forward"
    static let seekBackward: CommandID = "playback.seek-backward"
    static let exitFullScreen: CommandID = "window.exit-fullscreen"

    static let extraBindings = Bindings(keys: [
        KeyBinding(KeyChord("up"), volumeUp),
        KeyBinding(KeyChord("down"), volumeDown),
        KeyBinding(KeyChord("m"), toggleMute),
        KeyBinding(KeyChord("right", .shift), seekForward),
        KeyBinding(KeyChord("left", .shift), seekBackward),
        KeyBinding(KeyChord("escape"), exitFullScreen),
    ])

    /// 执行命令；返回 false 表示这个命令播放器不处理（按键交还给系统）。
    /// 没有字幕时，「上一句 / 下一句 / 重播」退化为后退、前进 5 秒。
    @MainActor
    static func perform(_ command: CommandID, session: PlaybackSession, window: NSWindow?) -> Bool {
        switch command {
        case .togglePlay, .continueProgram: session.togglePlay()
        case .previousSentence: session.previousSentence()
        case .replaySentence: session.replaySentence()
        case .nextSentence: session.nextSentence()
        case seekBackward: session.seek(by: -30)
        case seekForward: session.seek(by: 30)
        case .rateUp: session.stepRate(up: true)
        case .rateDown: session.stepRate(up: false)
        case volumeUp: session.changeVolume(by: 0.1)
        case volumeDown: session.changeVolume(by: -0.1)
        case toggleMute: session.toggleMute()
        case exitFullScreen:
            guard let window, window.styleMask.contains(.fullScreen) else { return false }
            window.toggleFullScreen(nil)
        default: return false
        }
        return true
    }
}

extension KeyChord {
    init(event: NSEvent) {
        let name: String = switch event.keyCode {
        case 49: "space"
        case 36, 76: "return"
        case 53: "escape"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 51: "delete"
        case 48: "tab"
        default: event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        var modifiers: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self.init(name, modifiers)
    }
}

/// 监听某个窗口的按键。用 AppKit 的本地事件监听而不是 SwiftUI 的 keyboardShortcut，
/// 因为快捷键要能在运行时由用户修改。
@MainActor
final class KeyMonitor {
    private var token: Any?

    func start(window: NSWindow, handler: @escaping @MainActor (KeyChord) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            // 本地事件监听总是在主线程回调；NSEvent 不是 Sendable，只在这个回调里使用。
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                // 只处理本窗口的按键；正在输入文字时不拦截。
                guard let window, event.window === window, !(window.firstResponder is NSText) else { return false }
                return handler(KeyChord(event: event))
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// 拿到 SwiftUI 视图所在的 NSWindow。
struct WindowAccessor: NSViewRepresentable {
    let onChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.onChange = onChange
    }
}

final class WindowTrackingView: NSView {
    var onChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange?(window)
    }
}
