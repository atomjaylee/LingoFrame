// 「学习程序」：所有循环、精听、跟读类功能都不写死在代码里，而是描述成「每一句要执行哪些步骤」。
// 单句循环、AB 循环、逐句暂停、盲听后显示字幕、影子跟读、收藏句轮播……都只是不同的步骤组合。
// 程序可以序列化成 JSON，用户可以自己编排、保存预设、分享给别人；新增步骤类型走 .custom 扩展。

public indirect enum PlaybackStep: Hashable, Codable, Sendable {
    /// 播放当前句。rate 为 nil 时沿用程序的默认倍速。
    case play(rate: Double? = nil)
    /// 只播当前句里的某几个词（需要词级时间戳），比如反复听一个连读。
    case playTokens(from: Int, to: Int, rate: Double? = nil)
    case pause(seconds: Double)
    /// 停住，直到用户按「继续」。
    case waitForUser
    /// count 为 nil 表示一直重复，直到用户跳句或退出。
    case `repeat`(count: Int?, steps: [PlaybackStep])
    case display(SubtitleDisplay)
    /// 影子跟读：录音时长 = 句子时长 × factor。
    case record(durationFactor: Double)
    /// 扩展步骤，由 ExtensionRegistry 里注册的 StepHandler 执行。
    case custom(id: String, params: [String: String] = [:])
}

public enum AdvancePolicy: String, Hashable, Codable, Sendable {
    /// 一句的步骤执行完自动进入下一句。
    case automatic
    /// 一句的步骤执行完停住，等用户按「下一句」。
    case manual
    /// 只处理起始的这一句，执行完就结束。
    case single
}

public struct LearningProgram: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var steps: [PlaybackStep]
    public var advance: AdvancePolicy
    public var defaultRate: Double
    public var padding: Padding
    /// 程序开始前的字幕显示状态，程序结束后恢复用户原来的设置。
    public var initialDisplay: SubtitleDisplay?

    public init(id: String, name: String, steps: [PlaybackStep], advance: AdvancePolicy = .automatic,
                defaultRate: Double = 1.0, padding: Padding = .default, initialDisplay: SubtitleDisplay? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.advance = advance
        self.defaultRate = defaultRate
        self.padding = padding
        self.initialDisplay = initialDisplay
    }
}

// MARK: - 内置预设（用户可以复制后修改）

extension LearningProgram {
    public static let loopSentence = LearningProgram(
        id: "builtin.loop-sentence", name: "单句循环",
        steps: [.repeat(count: nil, steps: [.play(), .pause(seconds: 0.5)])],
        advance: .single)

    public static let pauseEachSentence = LearningProgram(
        id: "builtin.pause-each", name: "逐句暂停",
        steps: [.play()], advance: .manual)

    public static let intensiveListening = LearningProgram(
        id: "builtin.intensive", name: "精听三遍",
        steps: [
            .display(.init(primary: .hidden, translation: .hidden)),
            .play(),
            .pause(seconds: 1),
            .display(.init(primary: .blurred, translation: .hidden)),
            .play(rate: 0.75),
            .pause(seconds: 1),
            .display(.init(primary: .visible, translation: .visible)),
            .play(),
            .waitForUser,
        ])

    public static let shadowing = LearningProgram(
        id: "builtin.shadowing", name: "影子跟读",
        steps: [
            .display(.init(primary: .visible, translation: .hidden)),
            .play(),
            .record(durationFactor: 1.3),
            .play(),
        ])

    public static let builtins: [LearningProgram] = [.loopSentence, .pauseEachSentence, .intensiveListening, .shadowing]
}
