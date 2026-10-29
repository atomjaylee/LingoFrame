import AppKit
import DesignSystem
import SwiftUI

public enum WorkspaceWindows {
    /// App 需要声明 WindowGroup(id: floatingPanel, for: String.self) { FloatingPanelView(panelID: $0.wrappedValue) }。
    public static let floatingPanel = "workspace.floating-panel"
}

/// 工作区：中间是主内容（视频），三边是可停靠的面板。
/// 面板按 Rex 的样式做成离窗口边缘留空的浮动大面板（surface-raised + radius-xl），面板和视频之间的空隙可以拖动调整大小。
/// 需要环境里有 PanelRegistry 和 LayoutStore。
public struct WorkspaceView<Center: View>: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(LayoutStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    private let center: Center

    public init(@ViewBuilder center: () -> Center) {
        self.center = center()
    }

    public var body: some View {
        let registered = registry.registeredIDs
        let layout = store.layout
        let inset = theme.metrics.floatingInset
        HStack(spacing: 0) {
            if !layout.visiblePanels(in: .leading, registered: registered).isEmpty {
                DockView(placement: .leading)
                    .frame(width: layout.dock(.leading).size)
                    .padding([.leading, .top, .bottom], inset)
                ResizeHandle(placement: .leading)
            }
            VStack(spacing: 0) {
                center.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !layout.visiblePanels(in: .bottom, registered: registered).isEmpty {
                    ResizeHandle(placement: .bottom)
                    DockView(placement: .bottom)
                        .frame(height: layout.dock(.bottom).size)
                        .padding([.leading, .trailing, .bottom], inset)
                }
            }
            if !layout.visiblePanels(in: .trailing, registered: registered).isEmpty {
                ResizeHandle(placement: .trailing)
                DockView(placement: .trailing)
                    .frame(width: layout.dock(.trailing).size)
                    .padding([.trailing, .top, .bottom], inset)
            }
        }
        .onAppear {
            for id in layout.floating where registered.contains(id) {
                openWindow(id: WorkspaceWindows.floatingPanel, value: id)
            }
        }
    }
}

// MARK: - 停靠区

struct DockView: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(LayoutStore.self) private var store
    @Environment(\.theme) private var theme
    let placement: PanelPlacement

    var body: some View {
        let ids = store.layout.visiblePanels(in: placement, registered: registry.registeredIDs)
        let selected = store.layout.dock(placement).selected.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        VStack(spacing: theme.metrics.space(2)) {
            HStack(spacing: theme.metrics.space(1)) {
                ForEach(ids, id: \.self) { id in
                    if let d = registry.descriptor(id) {
                        Button {
                            store.layout.select(id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: d.systemImage)
                                if ids.count <= 3 || id == selected { Text(d.title).lineLimit(1) }
                            }
                        }
                        .buttonStyle(RexChipStyle(isSelected: id == selected, height: 32))
                        .help(d.title)
                        .contextMenu { PanelActions(panelID: id) }
                    }
                }
                Spacer(minLength: 0)
                if let selected {
                    Menu {
                        PanelActions(panelID: selected)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(theme.colors.ink.color)
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("面板操作")
                }
            }
            .padding(.horizontal, theme.metrics.space(3))
            .padding(.top, theme.metrics.space(3))
            Group {
                if let selected, let d = registry.descriptor(selected) {
                    d.makeView()
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(theme.colors.ink.color)
        .rexRaised()
    }
}

/// 单个面板的操作：移动到其他位置、在独立窗口打开、关闭。
struct PanelActions: View {
    @Environment(LayoutStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let panelID: String

    var body: some View {
        let current = store.layout.placement(of: panelID)
        ForEach(PanelPlacement.allCases.filter { $0 != current }, id: \.self) { p in
            Button {
                store.layout.move(panelID, to: p)
                if p == .floating { openWindow(id: WorkspaceWindows.floatingPanel, value: panelID) }
            } label: {
                Label(p == .floating ? "在独立窗口打开" : "移到\(p.title)", systemImage: p.systemImage)
            }
        }
        Divider()
        Button("关闭面板", systemImage: "xmark") { store.layout.hide(panelID) }
    }
}

// MARK: - 分隔条

/// 面板和视频之间的空隙就是拖动区域，不画线（Rex 的面板靠留白和圆角区分，而不是分隔线）。
private struct ResizeHandle: View {
    @Environment(LayoutStore.self) private var store
    @Environment(\.theme) private var theme
    let placement: PanelPlacement
    @State private var startSize: Double?

    private var isVertical: Bool { placement != .bottom }

    var body: some View {
        Color.clear
            .frame(width: isVertical ? theme.metrics.floatingInset : nil,
                   height: isVertical ? nil : theme.metrics.floatingInset)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = startSize ?? store.layout.dock(placement).size
                if startSize == nil { startSize = start }
                let delta: Double = switch placement {
                case .leading: value.translation.width
                case .trailing: -value.translation.width
                case .bottom: -value.translation.height
                case .floating: 0
                }
                store.layout.setSize(start + delta, for: placement)
            }
            .onEnded { _ in startSize = nil }
    }
}

// MARK: - 独立窗口

public struct FloatingPanelView: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(LayoutStore.self) private var store
    @Environment(\.theme) private var theme
    private let panelID: String?

    public init(panelID: String?) { self.panelID = panelID }

    public var body: some View {
        Group {
            if let panelID, let d = registry.descriptor(panelID) {
                d.makeView()
                    .navigationTitle(d.title)
            } else {
                ContentUnavailableView("面板不存在", systemImage: "questionmark.square.dashed")
            }
        }
        .frame(minWidth: 260, minHeight: 200)
        .foregroundStyle(theme.colors.ink.color)
        .background(theme.colors.surfaceRaised.color)
        .onDisappear {
            // 关掉独立窗口 = 关闭面板；如果是被移回停靠区导致的关闭，则什么也不做。
            if let panelID, store.layout.placement(of: panelID) == .floating { store.layout.hide(panelID) }
        }
    }
}

// MARK: - 面板菜单（控制条和菜单栏共用）

public struct PanelsMenuContent: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(LayoutStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        let registered = registry.registeredIDs
        Section("面板") {
            ForEach(registry.descriptors) { d in
                Toggle(isOn: Binding(
                    get: { store.layout.isShown(d.id, registered: registered) },
                    set: { _ in
                        let wasFloating = store.layout.placement(of: d.id) == .floating
                        store.layout.toggle(d.id, defaultPlacement: d.defaultPlacement, registered: registered)
                        if wasFloating { dismissWindow(id: WorkspaceWindows.floatingPanel, value: d.id) }
                        if store.layout.placement(of: d.id) == .floating {
                            openWindow(id: WorkspaceWindows.floatingPanel, value: d.id)
                        }
                    })) {
                    Label(d.title, systemImage: d.systemImage)
                }
            }
        }
        Section("停靠区") {
            ForEach(PanelPlacement.docks, id: \.self) { p in
                Toggle(isOn: Binding(get: { store.layout.dock(p).isVisible },
                                     set: { store.layout.setDockVisible($0, p) })) {
                    Label(p.title, systemImage: p.systemImage)
                }
            }
        }
        Section("布局") {
            ForEach(store.presets) { preset in
                Button(preset.name) { store.apply(preset) }
            }
            Button("将当前布局存为预设") { store.saveCurrentAsPreset() }
            if !store.userPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(store.userPresets) { preset in
                        Button(preset.name) { store.deletePreset(preset.id) }
                    }
                }
            }
        }
    }
}

/// 三个停靠区的开关按钮（Rex 圆形图标按钮）。
public struct DockToggleButtons: View {
    @Environment(PanelRegistry.self) private var registry
    @Environment(LayoutStore.self) private var store
    private let diameter: Double

    public init(diameter: Double = 36) { self.diameter = diameter }

    public var body: some View {
        ForEach(PanelPlacement.docks, id: \.self) { p in
            let hasPanels = !store.layout.dock(p).panels.filter(registry.registeredIDs.contains).isEmpty
            let isOn = store.layout.dock(p).isVisible && hasPanels
            Button {
                store.layout.setDockVisible(!store.layout.dock(p).isVisible, p)
            } label: {
                Image(systemName: p.systemImage)
            }
            .buttonStyle(RexIconButtonStyle(diameter: diameter, glass: isOn))
            .disabled(!hasPanels)
            .opacity(hasPanels ? 1 : 0.4)
            .accessibilityLabel("显示或隐藏\(p.title)")
            .help(hasPanels ? "显示/隐藏\(p.title)" : "\(p.title)没有面板")
        }
    }
}
