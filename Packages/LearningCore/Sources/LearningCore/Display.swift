// 字幕显示：分「层」和「样式规则」两部分。
// - 层（主字幕 / 译文）各自有显示模式：显示、模糊、隐藏，或者交给某个可见性策略逐词决定。
// - 样式规则按标签匹配，比如「list.top2000 加下划线」「vocab.unknown 标黄」，用户可以自己编排主题。

public enum TokenVisibility: String, Hashable, Codable, Sendable {
    case visible
    case blurred
    case hidden
    /// 挖空：保留占位宽度，用于听写填空。
    case cloze
}

public enum LayerMode: Hashable, Codable, Sendable {
    case visible
    case blurred
    case hidden
    /// 交给注册的 VisibilityPolicy 逐词决定，比如「只遮生词」。
    case policy(id: String)
}

public struct SubtitleDisplay: Hashable, Codable, Sendable {
    public var primary: LayerMode
    public var translation: LayerMode

    public init(primary: LayerMode = .visible, translation: LayerMode = .visible) {
        self.primary = primary
        self.translation = translation
    }
}

public enum PlaybackPhase: Hashable, Sendable {
    case playing
    case paused
    /// 当前句已经播过 n 遍，可以用来做「第一遍遮住，第二遍显示」。
    case repeating(pass: Int)
}

public protocol VisibilityPolicy: Sendable {
    var id: String { get }
    var title: String { get }
    func visibility(of token: Token, in sentence: Sentence, phase: PlaybackPhase) -> TokenVisibility
}

/// 内置策略：带某个标签的词按指定方式处理，其他词正常显示。
/// 「只遮生词」=「vocab.unknown → cloze」，「遮住高频词考自己」=「list.top2000 → blurred」。
public struct TagVisibilityPolicy: VisibilityPolicy {
    public let id: String
    public let title: String
    public let tag: TokenTag
    public let treatment: TokenVisibility

    public init(id: String, title: String, tag: TokenTag, treatment: TokenVisibility) {
        self.id = id
        self.title = title
        self.tag = tag
        self.treatment = treatment
    }

    public func visibility(of token: Token, in sentence: Sentence, phase: PlaybackPhase) -> TokenVisibility {
        token.tags.contains(tag) ? treatment : .visible
    }
}

// MARK: - 样式

public struct TokenStyle: Hashable, Codable, Sendable {
    public enum Underline: String, Hashable, Codable, Sendable { case none, solid, dotted, wavy }

    /// 颜色用 "#RRGGBB" 或语义名（"accent"、"warning"），由 UI 层解析，保证深浅色模式都正确。
    public var foreground: String?
    public var background: String?
    public var underline: Underline?
    public var bold: Bool?

    public init(foreground: String? = nil, background: String? = nil, underline: Underline? = nil, bold: Bool? = nil) {
        self.foreground = foreground
        self.background = background
        self.underline = underline
        self.bold = bold
    }

    /// 后面的规则覆盖前面的规则里设置过的属性。
    public func merged(with other: TokenStyle) -> TokenStyle {
        TokenStyle(foreground: other.foreground ?? foreground, background: other.background ?? background,
                   underline: other.underline ?? underline, bold: other.bold ?? bold)
    }
}

public struct TokenStyleRule: Hashable, Codable, Sendable {
    public var tag: TokenTag
    public var style: TokenStyle

    public init(tag: TokenTag, style: TokenStyle) {
        self.tag = tag
        self.style = style
    }
}

public struct SubtitleTheme: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var fontSize: Double
    public var translationFontSize: Double
    /// 0 = 底部，1 = 顶部。
    public var verticalPosition: Double
    public var translationAbove: Bool
    public var rules: [TokenStyleRule]

    public init(id: String, name: String, fontSize: Double = 28, translationFontSize: Double = 20,
                verticalPosition: Double = 0.08, translationAbove: Bool = false, rules: [TokenStyleRule] = []) {
        self.id = id
        self.name = name
        self.fontSize = fontSize
        self.translationFontSize = translationFontSize
        self.verticalPosition = verticalPosition
        self.translationAbove = translationAbove
        self.rules = rules
    }

    public func style(for token: Token) -> TokenStyle {
        rules.filter { token.tags.contains($0.tag) }.reduce(TokenStyle()) { $0.merged(with: $1.style) }
    }

    public static let standard = SubtitleTheme(
        id: "builtin.standard", name: "标准",
        rules: [
            TokenStyleRule(tag: .top2000, style: TokenStyle(underline: .dotted)),
            TokenStyleRule(tag: .learning, style: TokenStyle(foreground: "accent")),
            TokenStyleRule(tag: .unknown, style: TokenStyle(foreground: "warning", bold: true)),
        ])
}
