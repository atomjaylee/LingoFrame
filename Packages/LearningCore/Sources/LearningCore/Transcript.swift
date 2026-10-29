// 数据分三层：
// 1. SubtitleTrack / SubtitleCue —— 原始字幕，来源各异（外挂、内嵌、OCR、ASR、翻译），只读。
// 2. Transcript / Sentence / Token —— 经过流水线整理后的「学习用剧本」，是所有功能的唯一数据源。
// 3. 用户数据（收藏、生词、笔记、编辑）—— 单独存储，用 SentenceAnchor 锚定，渲染时再叠加上去。

// MARK: - 原始字幕

public enum SubtitleOrigin: String, Codable, Sendable {
    case external, embedded, server, ocr, asr, translated, userEdited
}

public struct SubtitleCue: Hashable, Codable, Sendable {
    public var range: TimeRange
    public var text: String
    /// ASS 等格式的原始样式名，学习模式下忽略。
    public var style: String?

    public init(range: TimeRange, text: String, style: String? = nil) {
        self.range = range
        self.text = text
        self.style = style
    }
}

public struct SubtitleTrack: Identifiable, Codable, Sendable {
    public var id: String
    /// BCP-47 语言代码，如 "en"、"zh-Hans"。
    public var language: String
    public var origin: SubtitleOrigin
    public var cues: [SubtitleCue]

    public init(id: String, language: String, origin: SubtitleOrigin, cues: [SubtitleCue]) {
        self.id = id
        self.language = language
        self.origin = origin
        self.cues = cues
    }
}

// MARK: - 标签：所有「给单词打记号」的能力都通过标签扩展，不改模型

/// 开放式字符串标签，例如 "vocab.unknown"、"list.top2000"、"exam.cet4"、"phrase.phrasal-verb"。
/// 新功能只要新增一种标签，渲染样式、遮挡规则、统计都能按标签生效。
public struct TokenTag: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let word: TokenTag = "core.word"
    public static let unknown: TokenTag = "vocab.unknown"
    public static let learning: TokenTag = "vocab.learning"
    public static let known: TokenTag = "vocab.known"
    public static let top2000: TokenTag = "list.top2000"
}

// MARK: - 剧本

public struct Token: Hashable, Codable, Sendable {
    public var text: String
    /// 在所属句子 text 里的 UTF-16 偏移区间。用整数偏移而不是 String.Index，才能序列化和缓存。
    public var textRange: Range<Int>
    public var lemma: String?
    /// 词性（NLTag 的 rawValue），如 "Noun"、"Verb"。
    public var partOfSpeech: String?
    /// 词级时间戳，来自 ASR 强制对齐；没有就是 nil。
    public var audioRange: TimeRange?
    public var tags: Set<TokenTag>

    public init(text: String, textRange: Range<Int>, lemma: String? = nil, partOfSpeech: String? = nil,
                audioRange: TimeRange? = nil, tags: Set<TokenTag> = []) {
        self.text = text
        self.textRange = textRange
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.audioRange = audioRange
        self.tags = tags
    }

    public var isWord: Bool { tags.contains(.word) }
}

/// 跨多个 token 的片段，比如短语动词 "pick ... up"（可以不连续）、习语、用户划选的句段。
public struct Span: Hashable, Codable, Sendable {
    public var tokenIndices: [Int]
    public var tag: TokenTag
    public var payload: [String: String]

    public init(tokenIndices: [Int], tag: TokenTag, payload: [String: String] = [:]) {
        self.tokenIndices = tokenIndices
        self.tag = tag
        self.payload = payload
    }
}

public struct SentenceID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// 由开始时间和规范化文本生成，重新生成剧本时同一句话的 ID 保持不变。
    public static func derive(start: MediaTime, text: String) -> SentenceID {
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return SentenceID(rawValue: "\(start.ms)-\(String(hash, radix: 36))")
    }
}

public struct Sentence: Identifiable, Hashable, Codable, Sendable {
    public var id: SentenceID
    public var range: TimeRange
    public var text: String
    public var tokens: [Token]
    public var spans: [Span]
    /// 语言代码 -> 译文，比如 ["zh-Hans": "……"]。可以同时挂多种译文（字幕自带、系统翻译、大模型翻译）。
    public var translations: [String: String]
    public var speaker: String?

    public init(id: SentenceID? = nil, range: TimeRange, text: String, tokens: [Token] = [], spans: [Span] = [],
                translations: [String: String] = [:], speaker: String? = nil) {
        self.id = id ?? .derive(start: range.start, text: text)
        self.range = range
        self.text = text
        self.tokens = tokens
        self.spans = spans
        self.translations = translations
        self.speaker = speaker
    }
}

public struct Transcript: Codable, Sendable {
    public var mediaID: String
    public var language: String
    /// 按开始时间排序。
    public var sentences: [Sentence]
    /// 整体时间偏移（用户调字幕快慢），只在查询时生效，不改原始数据。
    public var globalOffset: MediaTime

    public init(mediaID: String, language: String, sentences: [Sentence], globalOffset: MediaTime = .zero) {
        self.mediaID = mediaID
        self.language = language
        self.sentences = sentences.sorted { $0.range.start < $1.range.start }
        self.globalOffset = globalOffset
    }

    /// 从原始字幕直接生成剧本：一条字幕就是一句，后面再由断句阶段合并或拆分。
    public init(mediaID: String, track: SubtitleTrack) {
        self.init(mediaID: mediaID, language: track.language,
                  sentences: track.cues.map { Sentence(range: $0.range, text: $0.text) })
    }

    public func effectiveRange(of sentence: Sentence) -> TimeRange {
        sentence.range.shifted(by: globalOffset)
    }

    /// 当前时间所在的句子；落在两句之间时返回 nil。二分查找，每秒调用几十次也没有压力。
    public func sentenceIndex(at time: MediaTime) -> Int? {
        let t = time - globalOffset
        var lo = 0, hi = sentences.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = sentences[mid].range
            if t < r.start { hi = mid - 1 } else if t >= r.end { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    /// 当前时间之后（或正在播放）的第一句，用于「下一句」和句间空白处的定位。
    public func sentenceIndex(atOrAfter time: MediaTime) -> Int? {
        let t = time - globalOffset
        return sentences.firstIndex { $0.range.end > t }
    }

    public func index(of id: SentenceID) -> Int? {
        sentences.firstIndex { $0.id == id }
    }
}

// MARK: - 用户数据的锚点

/// 收藏、笔记、生词例句都用锚点指向句子，而不是直接存 SentenceID。
/// 字幕换了版本或重新断句后，ID 会变，但「时间 + 原文片段」仍然能把它找回来。
public struct SentenceAnchor: Hashable, Codable, Sendable {
    public var mediaID: String
    public var sentenceID: SentenceID
    public var range: TimeRange
    public var quote: String

    public init(mediaID: String, sentence: Sentence) {
        self.mediaID = mediaID
        self.sentenceID = sentence.id
        self.range = sentence.range
        self.quote = sentence.text
    }
}

extension Transcript {
    public func resolve(_ anchor: SentenceAnchor) -> Int? {
        if let i = index(of: anchor.sentenceID) { return i }
        let needle = anchor.quote.lowercased()
        return sentences.indices
            .filter { sentences[$0].range.overlaps(anchor.range) }
            .max { a, b in
                score(sentences[a], needle, anchor.range) < score(sentences[b], needle, anchor.range)
            }
    }

    private func score(_ s: Sentence, _ needle: String, _ range: TimeRange) -> Int64 {
        let textBonus: Int64 = s.text.lowercased().contains(needle) || needle.contains(s.text.lowercased()) ? 1_000_000 : 0
        return textBonus + s.range.overlapDuration(with: range).ms
    }
}
