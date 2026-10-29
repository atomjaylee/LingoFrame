import NaturalLanguage

// 剧本生成流水线：原始字幕 → 断句 → 分词 → 对齐 → 翻译 → 打标签 → 应用用户编辑。
// 每个阶段都是一个独立的 TranscriptStage，按 order 排序执行。
// 新能力（比如「标出 CET-6 词汇」「识别说话人」）只需要新增一个阶段并注册，不需要修改已有代码。

public struct PipelineContext: Sendable {
    public var mediaID: String
    /// 学习的目标语言，比如 "en"。
    public var targetLanguage: String
    /// 用户的母语，比如 "zh-Hans"，翻译阶段用它作为目标语言。
    public var nativeLanguage: String
    /// 其他字幕轨（比如中文轨），对齐和翻译阶段会用到。
    public var auxiliaryTracks: [SubtitleTrack]

    public init(mediaID: String, targetLanguage: String = "en", nativeLanguage: String = "zh-Hans",
                auxiliaryTracks: [SubtitleTrack] = []) {
        self.mediaID = mediaID
        self.targetLanguage = targetLanguage
        self.nativeLanguage = nativeLanguage
        self.auxiliaryTracks = auxiliaryTracks
    }
}

public protocol TranscriptStage: Sendable {
    var id: String { get }
    /// 建议区间见 StageOrder。
    var order: Int { get }
    func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript
}

public enum StageOrder {
    public static let segment = 100
    public static let tokenize = 200
    public static let align = 300
    public static let translate = 400
    public static let annotate = 500
    public static let userEdits = 900
}

public struct TranscriptPipeline: Sendable {
    public var stages: [any TranscriptStage]

    public init(stages: [any TranscriptStage]) {
        self.stages = stages.sorted { $0.order < $1.order }
    }

    public func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript {
        var t = transcript
        for stage in stages {
            try Task.checkCancellation()
            t = try await stage.run(t, context: context)
        }
        return t
    }
}

// MARK: - 内置阶段：分词与词形还原

public struct TokenizeStage: TranscriptStage {
    public let id = "core.tokenize"
    public let order = StageOrder.tokenize

    public init() {}

    public func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript {
        var t = transcript
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        for i in t.sentences.indices {
            t.sentences[i].tokens = Self.tokenize(t.sentences[i].text, tagger: tagger)
        }
        return t
    }

    static func tokenize(_ text: String, tagger: NLTagger) -> [Token] {
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var tokens: [Token] = []
        let options: NLTagger.Options = [.omitWhitespace, .joinContractions]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: options) { lexical, range in
            let word = String(text[range])
            let lower = range.lowerBound.utf16Offset(in: text)
            let upper = range.upperBound.utf16Offset(in: text)
            let isWord = lexical.map { $0 != .punctuation && $0 != .sentenceTerminator && $0 != .otherPunctuation
                && $0 != .openQuote && $0 != .closeQuote && $0 != .openParenthesis && $0 != .closeParenthesis
                && $0 != .dash && $0 != .whitespace } ?? word.contains { $0.isLetter }
            let lemma = isWord ? tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue : nil
            tokens.append(Token(text: word, textRange: lower..<upper,
                                lemma: lemma ?? (isWord ? word.lowercased() : nil),
                                partOfSpeech: lexical?.rawValue,
                                tags: isWord ? [.word] : []))
            return true
        }
        return tokens
    }
}

// MARK: - 内置阶段：按词表打标签

/// 通用的「词表标签」阶段：高频 2000 词、CET-4、用户熟词，都是同一个阶段配不同的词表。
public struct WordListTagStage: TranscriptStage {
    public let id: String
    public let order = StageOrder.annotate
    public let tag: TokenTag
    public let lemmas: Set<String>

    public init(id: String, tag: TokenTag, lemmas: Set<String>) {
        self.id = id
        self.tag = tag
        self.lemmas = Set(lemmas.map { $0.lowercased() })
    }

    public func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript {
        var t = transcript
        for s in t.sentences.indices {
            for k in t.sentences[s].tokens.indices where t.sentences[s].tokens[k].isWord {
                let token = t.sentences[s].tokens[k]
                if lemmas.contains(token.lemma ?? "") || lemmas.contains(token.text.lowercased()) {
                    t.sentences[s].tokens[k].tags.insert(tag)
                }
            }
        }
        return t
    }
}

// MARK: - 内置阶段：中英按时间对齐

/// 把辅助字幕轨（通常是中文）按时间重叠度挂到每个英文句子的 translations 上。
public struct TimeOverlapAlignStage: TranscriptStage {
    public let id = "core.align.time-overlap"
    public let order = StageOrder.align
    /// 重叠时长至少占英文句时长的比例。
    public var minimumOverlapRatio: Double

    public init(minimumOverlapRatio: Double = 0.3) {
        self.minimumOverlapRatio = minimumOverlapRatio
    }

    public func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript {
        var t = transcript
        for track in context.auxiliaryTracks {
            for i in t.sentences.indices {
                let range = t.sentences[i].range
                let threshold = Double(range.duration.ms) * minimumOverlapRatio
                let matched = track.cues
                    .filter { Double($0.range.overlapDuration(with: range).ms) >= threshold }
                    .map(\.text)
                if !matched.isEmpty, t.sentences[i].translations[track.language] == nil {
                    t.sentences[i].translations[track.language] = matched.joined(separator: " ")
                }
            }
        }
        return t
    }
}
