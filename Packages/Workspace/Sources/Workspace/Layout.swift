import Foundation

// 布局是纯数据：每个停靠位放了哪些面板、选中哪个、是否显示、多宽多高。
// 布局里允许出现还没注册的面板 ID（比如预设里的「剧本」面板在 M2 才实现），渲染时自动跳过，
// 等面板注册以后就会自然出现，不需要迁移用户的布局文件。

public enum PanelPlacement: String, Hashable, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case leading, trailing, bottom, floating

    public static let docks: [PanelPlacement] = [.leading, .trailing, .bottom]

    public var title: String {
        switch self {
        case .leading: "左侧栏"
        case .trailing: "右侧栏"
        case .bottom: "底栏"
        case .floating: "独立窗口"
        }
    }

    public var systemImage: String {
        switch self {
        case .leading: "sidebar.left"
        case .trailing: "sidebar.right"
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .floating: "macwindow.on.rectangle"
        }
    }

    var defaultSize: Double { self == .bottom ? 220 : 300 }
    var sizeRange: ClosedRange<Double> { self == .bottom ? 120...600 : 200...700 }
}

public struct DockState: Hashable, Codable, Sendable {
    public var panels: [String]
    public var selected: String?
    public var isVisible: Bool
    public var size: Double

    public init(panels: [String] = [], selected: String? = nil, isVisible: Bool = true, size: Double) {
        self.panels = panels
        self.selected = selected ?? panels.first
        self.isVisible = isVisible
        self.size = size
    }
}

public struct WorkspaceLayout: Hashable, Codable, Sendable {
    public var docks: [PanelPlacement: DockState]
    public var floating: [String]

    public init(docks: [PanelPlacement: DockState] = [:], floating: [String] = []) {
        self.docks = docks
        self.floating = floating
    }

    public func dock(_ placement: PanelPlacement) -> DockState {
        docks[placement] ?? DockState(size: placement.defaultSize)
    }

    public func placement(of panel: String) -> PanelPlacement? {
        if floating.contains(panel) { return .floating }
        return PanelPlacement.docks.first { dock($0).panels.contains(panel) }
    }

    /// 某个停靠位实际要显示的面板（过滤掉未注册的）。
    public func visiblePanels(in placement: PanelPlacement, registered: Set<String>) -> [String] {
        let d = dock(placement)
        return d.isVisible ? d.panels.filter(registered.contains) : []
    }

    public func isShown(_ panel: String, registered: Set<String>) -> Bool {
        guard registered.contains(panel), let p = placement(of: panel) else { return false }
        return p == .floating || dock(p).isVisible
    }

    // MARK: 修改

    /// 显示面板：已经在某个位置就切到它，否则放到默认位置。
    public mutating func show(_ panel: String, defaultPlacement: PanelPlacement) {
        let p = placement(of: panel) ?? defaultPlacement
        if placement(of: panel) == nil { insert(panel, into: p) }
        if p != .floating {
            update(p) {
                $0.isVisible = true
                $0.selected = panel
            }
        }
    }

    public mutating func hide(_ panel: String) {
        floating.removeAll { $0 == panel }
        for p in PanelPlacement.docks where dock(p).panels.contains(panel) {
            update(p) {
                $0.panels.removeAll { $0 == panel }
                if $0.selected == panel { $0.selected = $0.panels.first }
            }
        }
    }

    public mutating func toggle(_ panel: String, defaultPlacement: PanelPlacement, registered: Set<String>) {
        if isShown(panel, registered: registered) { hide(panel) } else { show(panel, defaultPlacement: defaultPlacement) }
    }

    public mutating func move(_ panel: String, to placement: PanelPlacement) {
        hide(panel)
        insert(panel, into: placement)
        if placement != .floating {
            update(placement) {
                $0.isVisible = true
                $0.selected = panel
            }
        }
    }

    public mutating func select(_ panel: String) {
        guard let p = placement(of: panel), p != .floating else { return }
        update(p) { $0.selected = panel }
    }

    public mutating func setSize(_ size: Double, for placement: PanelPlacement) {
        guard placement != .floating else { return }
        update(placement) { $0.size = min(max(size, placement.sizeRange.lowerBound), placement.sizeRange.upperBound) }
    }

    public mutating func setDockVisible(_ visible: Bool, _ placement: PanelPlacement) {
        guard placement != .floating else { return }
        update(placement) { $0.isVisible = visible }
    }

    private mutating func insert(_ panel: String, into placement: PanelPlacement) {
        if placement == .floating {
            if !floating.contains(panel) { floating.append(panel) }
        } else {
            update(placement) { if !$0.panels.contains(panel) { $0.panels.append(panel) } }
        }
    }

    private mutating func update(_ placement: PanelPlacement, _ body: (inout DockState) -> Void) {
        var d = dock(placement)
        body(&d)
        docks[placement] = d
    }
}

// MARK: - 预设

public struct LayoutPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var layout: WorkspaceLayout

    public init(id: String, name: String, layout: WorkspaceLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }

    public var isBuiltin: Bool { id.hasPrefix("builtin.") }
}

/// 内置面板 ID。功能模块注册面板时使用，预设里也引用它们。
public enum PanelIDs {
    public static let mediaInfo = "media.info"
    public static let episodes = "media.episodes"
    public static let playbackDebug = "debug.playback"
    public static let transcript = "learning.transcript"
    public static let lookup = "learning.lookup"
    public static let shadowing = "learning.shadowing"
}

extension LayoutPreset {
    public static let watch = LayoutPreset(id: "builtin.watch", name: "观影", layout: WorkspaceLayout(docks: [
        .trailing: DockState(panels: [PanelIDs.episodes, PanelIDs.mediaInfo], isVisible: false, size: 320),
        .bottom: DockState(panels: [PanelIDs.playbackDebug], isVisible: false, size: 200),
    ]))

    public static let study = LayoutPreset(id: "builtin.study", name: "精听", layout: WorkspaceLayout(docks: [
        .trailing: DockState(panels: [PanelIDs.transcript, PanelIDs.lookup, PanelIDs.episodes], size: 360),
        .bottom: DockState(panels: [PanelIDs.playbackDebug], isVisible: false, size: 200),
    ]))

    public static let shadowing = LayoutPreset(id: "builtin.shadowing", name: "跟读", layout: WorkspaceLayout(docks: [
        .trailing: DockState(panels: [PanelIDs.transcript, PanelIDs.lookup], size: 340),
        .bottom: DockState(panels: [PanelIDs.shadowing], size: 200),
    ]))

    public static let debug = LayoutPreset(id: "builtin.debug", name: "调试", layout: WorkspaceLayout(docks: [
        .trailing: DockState(panels: [PanelIDs.mediaInfo, PanelIDs.episodes], size: 320),
        .bottom: DockState(panels: [PanelIDs.playbackDebug], size: 200),
    ]))

    public static let builtins: [LayoutPreset] = [.watch, .study, .shadowing, .debug]
}
