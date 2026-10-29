import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import Workspace

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            OpenLocalVideoButton()
        }
        CommandMenu("面板") {
            PanelsMenuContent()
                .environment(model.layoutStore)
                .environment(model.panels)
        }
        CommandGroup(after: .toolbar) {
            ThemeMenu(store: model.themeStore)
        }
    }
}

/// 打开本地视频文件，不需要 Emby，方便测试播放。
private struct OpenLocalVideoButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开本地视频…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                openWindow(id: PlayerWindow.id, value: PlayRequest.local(url))
            }
        }
        .keyboardShortcut("o")
    }
}

private struct ThemeMenu: View {
    @Bindable var store: ThemeStore

    var body: some View {
        Picker("外观", selection: $store.appearance) {
            ForEach(ThemeAppearance.allCases, id: \.self) { appearance in
                Text(appearance.title).tag(appearance)
            }
        }
    }
}
