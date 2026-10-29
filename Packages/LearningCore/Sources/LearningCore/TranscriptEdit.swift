import Foundation

// 用户对剧本的修改（调时间轴、拆句、并句、改错字）不直接覆盖剧本，而是存成一串编辑操作，
// 由流水线的最后一个阶段重放。这样重新识别、重新翻译之后，用户的修改不会丢。

public enum TranscriptEdit: Hashable, Codable, Sendable {
    case globalOffset(ms: Int64)
    case shift(SentenceID, ms: Int64)
    case setRange(SentenceID, TimeRange)
    case setText(SentenceID, String)
    case setTranslation(SentenceID, language: String, String)
    /// 在第 tokenIndex 个 token 之前拆开，右半句从这个 token 开始。
    case split(SentenceID, tokenIndex: Int)
    /// 把这一句和它的下一句合并。
    case mergeWithNext(SentenceID)
    case delete(SentenceID)
}

public struct UserEditsStage: TranscriptStage {
    public let id = "core.user-edits"
    public let order = StageOrder.userEdits
    public var edits: [TranscriptEdit]

    public init(edits: [TranscriptEdit]) { self.edits = edits }

    public func run(_ transcript: Transcript, context: PipelineContext) async throws -> Transcript {
        edits.reduce(transcript) { $0.applying($1) }
    }
}

extension Transcript {
    /// 找不到目标句子的编辑会被忽略（比如字幕换了版本），不会报错。
    public func applying(_ edit: TranscriptEdit) -> Transcript {
        var t = self
        switch edit {
        case .globalOffset(let ms):
            t.globalOffset = MediaTime(ms: ms)

        case .shift(let id, let ms):
            guard let i = t.index(of: id) else { return t }
            t.sentences[i].range = t.sentences[i].range.shifted(by: MediaTime(ms: ms))

        case .setRange(let id, let range):
            guard let i = t.index(of: id) else { return t }
            t.sentences[i].range = range

        case .setText(let id, let text):
            guard let i = t.index(of: id) else { return t }
            t.sentences[i].text = text
            t.sentences[i].tokens = []
            t.sentences[i].spans = []

        case .setTranslation(let id, let language, let text):
            guard let i = t.index(of: id) else { return t }
            t.sentences[i].translations[language] = text

        case .split(let id, let k):
            guard let i = t.index(of: id) else { return t }
            let s = t.sentences[i]
            guard k > 0, k < s.tokens.count else { return t }
            let cut = s.tokens[k].textRange.lowerBound
            let utf16 = Array(s.text.utf16)
            let leftText = String(decoding: utf16[..<cut], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            let rightText = String(decoding: utf16[cut...], as: UTF16.self)
            // 有词级时间戳就按词切，没有就按字符比例估算。
            let splitTime = s.tokens[k].audioRange?.start
                ?? s.range.start + MediaTime(ms: s.range.duration.ms * Int64(cut) / Int64(max(utf16.count, 1)))
            var left = Sentence(id: SentenceID(rawValue: s.id.rawValue + ".a"),
                                range: TimeRange(start: s.range.start, end: splitTime), text: leftText,
                                tokens: Array(s.tokens[..<k]), speaker: s.speaker)
            left.translations = s.translations
            let right = Sentence(id: SentenceID(rawValue: s.id.rawValue + ".b"),
                                 range: TimeRange(start: splitTime, end: s.range.end), text: rightText,
                                 tokens: s.tokens[k...].map { tok in
                                     var tok = tok
                                     tok.textRange = (tok.textRange.lowerBound - cut)..<(tok.textRange.upperBound - cut)
                                     return tok
                                 },
                                 speaker: s.speaker)
            t.sentences.replaceSubrange(i...i, with: [left, right])

        case .mergeWithNext(let id):
            guard let i = t.index(of: id), i + 1 < t.sentences.count else { return t }
            let a = t.sentences[i], b = t.sentences[i + 1]
            let joiner = " "
            let offset = a.text.utf16.count + joiner.utf16.count
            var merged = Sentence(id: a.id, range: TimeRange(start: a.range.start, end: b.range.end),
                                  text: a.text + joiner + b.text,
                                  tokens: a.tokens + b.tokens.map { tok in
                                      var tok = tok
                                      tok.textRange = (tok.textRange.lowerBound + offset)..<(tok.textRange.upperBound + offset)
                                      return tok
                                  },
                                  speaker: a.speaker)
            for (lang, text) in a.translations {
                merged.translations[lang] = [text, b.translations[lang]].compactMap { $0 }.joined(separator: " ")
            }
            t.sentences.replaceSubrange(i...(i + 1), with: [merged])

        case .delete(let id):
            guard let i = t.index(of: id) else { return t }
            t.sentences.remove(at: i)
        }
        return t
    }
}
