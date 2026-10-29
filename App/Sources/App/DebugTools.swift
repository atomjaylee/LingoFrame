#if DEBUG
import AppKit

/// 仅开发版：收到分布式通知时，把 App 自己的所有窗口渲染成 PNG，便于在没有录屏权限的环境里检查界面。
/// 触发方式：发送名为 app.elenglish.debug.snapshot 的分布式通知，object 为输出目录。
/// 注意：视频的 Metal 图层不会被渲染进截图，视频区域显示为黑色。
enum DebugTools {
    static let snapshotNotification = Notification.Name("app.elenglish.debug.snapshot")

    @MainActor
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: snapshotNotification, object: nil,
                                                            queue: .main) { note in
            let directory = note.object as? String ?? NSTemporaryDirectory()
            MainActor.assumeIsolated { snapshotWindows(to: directory) }
        }
    }

    @MainActor
    static func snapshotWindows(to directory: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "untitled" : window.title.replacingOccurrences(of: "/", with: "-")
            let url = URL(fileURLWithPath: directory).appendingPathComponent("window-\(i)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
