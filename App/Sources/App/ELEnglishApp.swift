import DesignSystem
import SwiftUI
import Workspace

@main
struct ELEnglishApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("ELEnglish", id: "main") {
            RootView()
                .appEnvironment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }

        Window("播放", id: PlayerWindow.id) {
            PlayerWindow(request: model.playRequest, requestRevision: model.playRequestRevision)
                .appEnvironment(model)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)

        WindowGroup("面板", id: WorkspaceWindows.floatingPanel, for: String.self) { $panelID in
            FloatingPanelView(panelID: panelID)
                .environment(model.activeSession)
                .appEnvironment(model)
        }
        .defaultSize(width: 360, height: 520)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .appEnvironment(model)
        }
    }
}

/// 所有窗口共用的环境：数据模型、主题、布局、面板注册中心。
struct AppEnvironment: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let theme = model.themeStore.current
        content
            .environment(model)
            .environment(model.themeStore)
            .environment(model.layoutStore)
            .environment(model.panels)
            .environment(\.theme, theme)
            .tint(theme.colors.ink.color)
            .foregroundStyle(theme.colors.ink.color)
            .preferredColorScheme(theme.colorScheme)
            .modifier(ForcedColorScheme(scheme: theme.colorScheme))
            .onChange(of: theme.id, initial: true) { model.applyAppearance() }
    }
}

/// 主题指定了深色或浅色时，直接写进环境，保证令牌按主题的外观取值，不受窗口外观同步时机的影响。
private struct ForcedColorScheme: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme { content.environment(\.colorScheme, scheme) } else { content }
    }
}

extension View {
    func appEnvironment(_ model: AppModel) -> some View {
        modifier(AppEnvironment(model: model))
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainShell()
        .rexWindowBackground()
        .toolbar(.hidden, for: .windowToolbar)
        // 从访达打开的视频文件交给播放窗口，主窗口不重复打开。
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            if url.isFileURL { model.showPlayer(.local(url), using: openWindow) }
        }
    }
}
