// 扩展注册中心：所有可扩展的能力都在这里登记。
// 我们自己写的内置功能也走这条路，所以内置功能和以后的扩展地位完全一样；
// 将来开放 JavaScript 插件（类似 IINA 1.4），也只需要把这些注册入口桥接出去。

public struct SubtitleTrackDescriptor: Hashable, Sendable {
    public var sourceID: String
    public var trackID: String
    public var language: String
    public var title: String
    public var origin: SubtitleOrigin

    public init(sourceID: String, trackID: String, language: String, title: String, origin: SubtitleOrigin) {
        self.sourceID = sourceID
        self.trackID = trackID
        self.language = language
        self.title = title
        self.origin = origin
    }
}

/// 字幕来源：Emby 服务器、内嵌轨、本地文件、OCR、ASR、在线字幕库……
public protocol SubtitleSource: Sendable {
    var id: String { get }
    func availableTracks(mediaID: String) async throws -> [SubtitleTrackDescriptor]
    func load(_ descriptor: SubtitleTrackDescriptor) async throws -> SubtitleTrack
}

@MainActor
public protocol LearningExtension {
    var id: String { get }
    func register(in registry: ExtensionRegistry)
}

@MainActor
public final class ExtensionRegistry {
    public private(set) var subtitleSources: [String: any SubtitleSource] = [:]
    public private(set) var stages: [String: any TranscriptStage] = [:]
    public private(set) var lookupProviders: [String: any LookupProvider] = [:]
    public private(set) var visibilityPolicies: [String: any VisibilityPolicy] = [:]
    public private(set) var stepHandlers: [String: any StepHandler] = [:]
    public private(set) var commands: [CommandID: any LearningCommand] = [:]
    public private(set) var programs: [String: LearningProgram] = [:]
    public private(set) var themes: [String: SubtitleTheme] = [:]
    public private(set) var installedExtensions: [String] = []

    public init() {
        for program in LearningProgram.builtins { programs[program.id] = program }
        themes[SubtitleTheme.standard.id] = .standard
    }

    public func install(_ ext: any LearningExtension) {
        guard !installedExtensions.contains(ext.id) else { return }
        ext.register(in: self)
        installedExtensions.append(ext.id)
    }

    // 同一个 id 再次注册会覆盖旧的，方便扩展替换内置实现（比如换一个更好的分词器）。
    public func register(source: any SubtitleSource) { subtitleSources[source.id] = source }
    public func register(stage: any TranscriptStage) { stages[stage.id] = stage }
    public func register(lookup: any LookupProvider) { lookupProviders[lookup.id] = lookup }
    public func register(policy: any VisibilityPolicy) { visibilityPolicies[policy.id] = policy }
    public func register(step: any StepHandler) { stepHandlers[step.id] = step }
    public func register(command: any LearningCommand) { commands[command.id] = command }
    public func register(program: LearningProgram) { programs[program.id] = program }
    public func register(theme: SubtitleTheme) { themes[theme.id] = theme }

    public func pipeline(disabling disabled: Set<String> = []) -> TranscriptPipeline {
        TranscriptPipeline(stages: stages.values.filter { !disabled.contains($0.id) })
    }

    public func lookupService(disabling disabled: Set<String> = []) -> LookupService {
        LookupService(providers: lookupProviders.values.filter { !disabled.contains($0.id) })
    }

    public func commands(for target: InteractionTarget) -> [any LearningCommand] {
        commands.values.filter { $0.contextMenuTargets.contains(target) }.sorted { $0.title < $1.title }
    }
}
