// 查词：多个词典来源并行查询，先到先显示。
// 本地词典（ECDICT）几毫秒就返回，大模型的语境讲解几秒后再补进来，界面不用等最慢的那个。

public struct LookupQuery: Hashable, Sendable {
    public var surface: String
    public var lemma: String
    public var sentence: Sentence
    public var tokenRange: ClosedRange<Int>

    public init(surface: String, lemma: String, sentence: Sentence, tokenRange: ClosedRange<Int>) {
        self.surface = surface
        self.lemma = lemma
        self.sentence = sentence
        self.tokenRange = tokenRange
    }

    public var isPhrase: Bool { tokenRange.count > 1 }

    public init?(sentence: Sentence, tokenRange: ClosedRange<Int>) {
        guard sentence.tokens.indices.contains(tokenRange.lowerBound),
              sentence.tokens.indices.contains(tokenRange.upperBound) else { return nil }
        let tokens = sentence.tokens[tokenRange]
        let utf16 = Array(sentence.text.utf16)
        let surface = String(decoding: utf16[tokens.first!.textRange.lowerBound..<tokens.last!.textRange.upperBound],
                             as: UTF16.self)
        let lemma = tokens.filter(\.isWord).map { $0.lemma ?? $0.text.lowercased() }.joined(separator: " ")
        self.init(surface: surface, lemma: lemma, sentence: sentence, tokenRange: tokenRange)
    }
}

public struct LookupResult: Hashable, Sendable {
    public struct Sense: Hashable, Sendable {
        public var partOfSpeech: String?
        public var definition: String
        public var translation: String?
        public var examples: [String]

        public init(partOfSpeech: String? = nil, definition: String, translation: String? = nil, examples: [String] = []) {
            self.partOfSpeech = partOfSpeech
            self.definition = definition
            self.translation = translation
            self.examples = examples
        }
    }

    public var providerID: String
    public var headword: String
    public var phonetic: String?
    public var senses: [Sense]
    /// 结合语境的说明，比如「这里 pick up 是"接人"的意思」，一般来自大模型。
    public var contextNote: String?
    public var tags: Set<TokenTag>

    public init(providerID: String, headword: String, phonetic: String? = nil, senses: [Sense] = [],
                contextNote: String? = nil, tags: Set<TokenTag> = []) {
        self.providerID = providerID
        self.headword = headword
        self.phonetic = phonetic
        self.senses = senses
        self.contextNote = contextNote
        self.tags = tags
    }
}

public protocol LookupProvider: Sendable {
    var id: String { get }
    var title: String { get }
    /// 数字越小越靠前显示。
    var priority: Int { get }
    var supportsPhrases: Bool { get }
    func lookup(_ query: LookupQuery) async throws -> LookupResult?
}

public struct LookupService: Sendable {
    public var providers: [any LookupProvider]

    public init(providers: [any LookupProvider]) {
        self.providers = providers.sorted { $0.priority < $1.priority }
    }

    /// 按返回先后逐个产出结果；某个来源失败不影响其他来源。
    public func lookup(_ query: LookupQuery) -> AsyncStream<LookupResult> {
        let providers = self.providers.filter { !query.isPhrase || $0.supportsPhrases }
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: LookupResult?.self) { group in
                    for provider in providers {
                        group.addTask { try? await provider.lookup(query) }
                    }
                    for await result in group {
                        if let result { continuation.yield(result) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
