import Foundation
import Observation
import SwiftUI
import os

// MARK: - 面板注册

/// 一个面板 = ID + 标题 + 图标 + 默认位置 + 视图。
/// 面板视图通过 SwiftUI 环境拿数据（当前播放的条目、播放器等），所以注册时不需要传上下文。
public struct PanelDescriptor: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let defaultPlacement: PanelPlacement
    public let makeView: @MainActor () -> AnyView

    public init<Content: View>(id: String, title: String, systemImage: String,
                               defaultPlacement: PanelPlacement = .trailing,
                               @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.defaultPlacement = defaultPlacement
        self.makeView = { AnyView(content()) }
    }
}

@MainActor
@Observable
public final class PanelRegistry {
    public private(set) var descriptors: [PanelDescriptor] = []

    public init() {}

    /// 同一个 ID 再次注册会替换旧的面板。
    public func register(_ descriptor: PanelDescriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    public func descriptor(_ id: String) -> PanelDescriptor? {
        descriptors.first { $0.id == id }
    }

    public var registeredIDs: Set<String> { Set(descriptors.map(\.id)) }
}

// MARK: - JSON 文件

public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - 布局存储

/// 当前布局和用户预设，都以 JSON 保存在 directory 下。修改后延迟 0.4 秒写盘，拖动分隔条时不会频繁写文件。
@MainActor
@Observable
public final class LayoutStore {
    public var layout: WorkspaceLayout {
        didSet { if layout != oldValue { scheduleSave() } }
    }
    public private(set) var userPresets: [LayoutPreset]
    public var presets: [LayoutPreset] { LayoutPreset.builtins + userPresets }

    private let currentFile: JSONFile<WorkspaceLayout>
    private let presetsFile: JSONFile<[LayoutPreset]>
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.elenglish", category: "layout")

    public static let defaultPreset = LayoutPreset.watch

    public init(directory: URL) {
        currentFile = JSONFile(directory.appendingPathComponent("current.json"))
        presetsFile = JSONFile(directory.appendingPathComponent("presets.json"))
        layout = currentFile.load() ?? Self.defaultPreset.layout
        userPresets = presetsFile.load() ?? []
    }

    public func apply(_ preset: LayoutPreset) {
        layout = preset.layout
    }

    @discardableResult
    public func saveCurrentAsPreset(named name: String? = nil) -> LayoutPreset {
        let n = userPresets.count + 1
        let preset = LayoutPreset(id: "user.\(UUID().uuidString.prefix(8))", name: name ?? "自定义布局 \(n)", layout: layout)
        userPresets.append(preset)
        persistPresets()
        return preset
    }

    public func renamePreset(_ id: String, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[i].name = name
        persistPresets()
    }

    public func deletePreset(_ id: String) {
        userPresets.removeAll { $0.id == id }
        persistPresets()
    }

    /// 立即写盘（App 退出时调用）。
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        do { try currentFile.save(layout) } catch {
            log.error("布局保存失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistPresets() {
        do { try presetsFile.save(userPresets) } catch {
            log.error("布局预设保存失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
