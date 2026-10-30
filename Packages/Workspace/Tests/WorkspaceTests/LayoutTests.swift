import Foundation
import Testing
@testable import Workspace

private let registered: Set<String> = [PanelIDs.mediaInfo, PanelIDs.episodes, PanelIDs.playbackDebug]

@Test func videoWindowUsesNativeResolutionAndFitsTheScreen() {
    #expect(VideoWindowSizing.contentSize(for: CGSize(width: 1_280, height: 720),
                                          backingScale: 1, maximum: CGSize(width: 1_600, height: 900))
        == CGSize(width: 1_280, height: 720))
    #expect(VideoWindowSizing.contentSize(for: CGSize(width: 1_920, height: 1_080),
                                          backingScale: 2, maximum: CGSize(width: 1_600, height: 900))
        == CGSize(width: 960, height: 540))
    #expect(VideoWindowSizing.contentSize(for: CGSize(width: 3_840, height: 2_160),
                                          backingScale: 2, maximum: CGSize(width: 1_600, height: 900))
        == CGSize(width: 1_600, height: 900))
}

@Test func showMoveHideKeepsPanelsInOnePlace() {
    var layout = WorkspaceLayout()
    layout.show(PanelIDs.mediaInfo, defaultPlacement: .trailing)
    #expect(layout.placement(of: PanelIDs.mediaInfo) == .trailing)
    #expect(layout.isShown(PanelIDs.mediaInfo, registered: registered))

    layout.move(PanelIDs.mediaInfo, to: .bottom)
    #expect(layout.placement(of: PanelIDs.mediaInfo) == .bottom)
    #expect(layout.dock(.trailing).panels.isEmpty)
    #expect(layout.dock(.bottom).selected == PanelIDs.mediaInfo)

    layout.move(PanelIDs.mediaInfo, to: .floating)
    #expect(layout.floating == [PanelIDs.mediaInfo])
    #expect(layout.dock(.bottom).panels.isEmpty)

    layout.hide(PanelIDs.mediaInfo)
    #expect(layout.placement(of: PanelIDs.mediaInfo) == nil)
}

@Test func hiddenDockAndUnregisteredPanelsAreNotShown() {
    var layout = LayoutPreset.study.layout
    // 剧本面板还没注册，不显示，但保留在布局里。
    #expect(layout.visiblePanels(in: .trailing, registered: registered) == [PanelIDs.episodes])
    #expect(layout.dock(.trailing).panels.contains(PanelIDs.transcript))

    layout.setDockVisible(false, .trailing)
    #expect(layout.visiblePanels(in: .trailing, registered: registered).isEmpty)
    #expect(!layout.isShown(PanelIDs.episodes, registered: registered))

    layout.toggle(PanelIDs.episodes, defaultPlacement: .leading, registered: registered)
    #expect(layout.dock(.trailing).isVisible)
    #expect(layout.dock(.trailing).selected == PanelIDs.episodes)
}

@Test func sizesAreClamped() {
    var layout = WorkspaceLayout()
    layout.setSize(5_000, for: .trailing)
    #expect(layout.dock(.trailing).size == 700)
    layout.setSize(10, for: .bottom)
    #expect(layout.dock(.bottom).size == 120)
}

@Test func layoutJSONIsReadable() throws {
    let data = try JSONEncoder().encode(LayoutPreset.debug.layout)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let docks = try #require(object["docks"] as? [String: Any])
    #expect(Set(docks.keys) == ["trailing", "bottom"])
}

@MainActor
@Test func storePersistsLayoutAndPresets() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LayoutStore(directory: dir)
    #expect(store.layout == LayoutStore.defaultPreset.layout)

    store.apply(.debug)
    store.layout.setSize(250, for: .bottom)
    let preset = store.saveCurrentAsPreset(named: "我的")
    store.flush()

    let reloaded = LayoutStore(directory: dir)
    #expect(reloaded.layout.dock(.bottom).size == 250)
    #expect(reloaded.userPresets.map(\.name) == ["我的"])

    reloaded.deletePreset(preset.id)
    #expect(LayoutStore(directory: dir).userPresets.isEmpty)
}
