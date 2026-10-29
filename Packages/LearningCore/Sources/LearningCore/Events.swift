// 学习事件：所有学习行为都发一条事件，并落库存成流水。
// 统计（今天听了多少句）、复习（查过三次的词自动进生词本）、推荐（这集生词太多）都从流水里算，
// 以后加新的分析功能不需要回头改埋点。

public enum LearningEvent: Hashable, Codable, Sendable {
    case sentenceStarted(mediaID: String, sentence: SentenceID)
    case sentencePlayed(mediaID: String, sentence: SentenceID, rate: Double)
    case lookedUp(mediaID: String, sentence: SentenceID, lemma: String)
    case wordSaved(lemma: String, anchor: SentenceAnchor)
    case sentenceSaved(anchor: SentenceAnchor)
    case recorded(mediaID: String, sentence: SentenceID, score: Double?)
    case programFinished(programID: String)
    case custom(name: String, payload: [String: String])
}

@MainActor
public final class EventBus {
    private var continuations: [Int: AsyncStream<LearningEvent>.Continuation] = [:]
    private var nextID = 0

    public init() {}

    public func publish(_ event: LearningEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    public func subscribe() -> AsyncStream<LearningEvent> {
        let id = nextID
        nextID += 1
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }
}
