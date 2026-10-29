// 交互层：一切用户操作都是「命令」，键盘、鼠标手势、右键菜单、命令面板只是触发命令的不同方式。
// 新功能 = 注册一个命令 + （可选）一个默认绑定。用户可以把任何手势或按键改绑到任何命令上。

public struct CommandID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let togglePlay: CommandID = "playback.toggle"
    public static let continueProgram: CommandID = "program.continue"
    public static let nextSentence: CommandID = "sentence.next"
    public static let previousSentence: CommandID = "sentence.previous"
    public static let replaySentence: CommandID = "sentence.replay"
    public static let toggleLoop: CommandID = "sentence.toggle-loop"
    public static let saveSentence: CommandID = "sentence.save"
    public static let lookup: CommandID = "word.lookup"
    public static let saveWord: CommandID = "word.save"
    public static let markKnown: CommandID = "word.mark-known"
    public static let playWord: CommandID = "word.play"
    public static let toggleTranslation: CommandID = "display.toggle-translation"
    public static let cycleDisplay: CommandID = "display.cycle"
    public static let startShadowing: CommandID = "program.shadowing"
    public static let rateUp: CommandID = "playback.rate-up"
    public static let rateDown: CommandID = "playback.rate-down"
    public static let commandPalette: CommandID = "app.command-palette"
}

public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
}

/// 手势作用在哪里。同一个「单击」，点在单词上和点在视频上可以绑不同的命令。
public enum InteractionTarget: String, Hashable, Codable, Sendable, CaseIterable {
    case token, selection, sentence, translation, transcriptRow, video
}

public struct Gesture: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case click, doubleClick, secondaryClick, hover, dragSelect, forceClick
    }

    public var kind: Kind
    public var modifiers: Modifiers

    public init(_ kind: Kind, _ modifiers: Modifiers = []) {
        self.kind = kind
        self.modifiers = modifiers
    }
}

public struct KeyChord: Hashable, Codable, Sendable {
    /// 键名，如 "space"、"left"、"r"、"k"。
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct GestureBinding: Hashable, Codable, Sendable {
    public var target: InteractionTarget
    public var gesture: Gesture
    public var command: CommandID

    public init(_ target: InteractionTarget, _ gesture: Gesture, _ command: CommandID) {
        self.target = target
        self.gesture = gesture
        self.command = command
    }
}

public struct KeyBinding: Hashable, Codable, Sendable {
    public var chord: KeyChord
    public var command: CommandID

    public init(_ chord: KeyChord, _ command: CommandID) {
        self.chord = chord
        self.command = command
    }
}

/// 用户的绑定表，存成 JSON。查找时后加的绑定优先，所以用户自定义只需要追加，不用改默认表。
public struct Bindings: Hashable, Codable, Sendable {
    public var gestures: [GestureBinding]
    public var keys: [KeyBinding]

    public init(gestures: [GestureBinding] = [], keys: [KeyBinding] = []) {
        self.gestures = gestures
        self.keys = keys
    }

    public func command(for gesture: Gesture, on target: InteractionTarget) -> CommandID? {
        gestures.last { $0.target == target && $0.gesture == gesture }?.command
    }

    public func command(for chord: KeyChord) -> CommandID? {
        keys.last { $0.chord == chord }?.command
    }

    public func overlaid(with user: Bindings) -> Bindings {
        Bindings(gestures: gestures + user.gestures, keys: keys + user.keys)
    }

    public static let defaults = Bindings(
        gestures: [
            GestureBinding(.token, Gesture(.click), .lookup),
            GestureBinding(.token, Gesture(.click, .option), .saveWord),
            GestureBinding(.token, Gesture(.doubleClick), .playWord),
            GestureBinding(.selection, Gesture(.dragSelect), .lookup),
            GestureBinding(.sentence, Gesture(.doubleClick), .replaySentence),
            GestureBinding(.translation, Gesture(.click), .toggleTranslation),
            GestureBinding(.transcriptRow, Gesture(.click), .replaySentence),
            GestureBinding(.video, Gesture(.click), .togglePlay),
        ],
        keys: [
            KeyBinding(KeyChord("space"), .togglePlay),
            KeyBinding(KeyChord("return"), .continueProgram),
            KeyBinding(KeyChord("left"), .previousSentence),
            KeyBinding(KeyChord("right"), .nextSentence),
            KeyBinding(KeyChord("r"), .replaySentence),
            KeyBinding(KeyChord("l"), .toggleLoop),
            KeyBinding(KeyChord("t"), .toggleTranslation),
            KeyBinding(KeyChord("h"), .cycleDisplay),
            KeyBinding(KeyChord("s"), .startShadowing),
            KeyBinding(KeyChord("f"), .saveSentence),
            KeyBinding(KeyChord("]"), .rateUp),
            KeyBinding(KeyChord("["), .rateDown),
            KeyBinding(KeyChord("k", .command), .commandPalette),
        ])
}

/// 命令执行时拿到的上下文：点的是哪一句、哪个词、选了哪一段。
public struct CommandContext: Sendable {
    public var sentenceIndex: Int?
    public var tokenIndex: Int?
    public var selection: ClosedRange<Int>?
    public var time: MediaTime
    public var params: [String: String]

    public init(sentenceIndex: Int? = nil, tokenIndex: Int? = nil, selection: ClosedRange<Int>? = nil,
                time: MediaTime = .zero, params: [String: String] = [:]) {
        self.sentenceIndex = sentenceIndex
        self.tokenIndex = tokenIndex
        self.selection = selection
        self.time = time
        self.params = params
    }
}

@MainActor
public protocol LearningCommand: AnyObject {
    var id: CommandID { get }
    var title: String { get }
    /// 这个命令出现在哪些位置的右键菜单里。空数组表示不进右键菜单（仍然可以用快捷键和命令面板）。
    var contextMenuTargets: [InteractionTarget] { get }
    func isEnabled(in context: CommandContext) -> Bool
    func perform(in context: CommandContext) async
}

extension LearningCommand {
    public var contextMenuTargets: [InteractionTarget] { [] }
    public func isEnabled(in context: CommandContext) -> Bool { true }
}
