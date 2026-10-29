import Foundation
import Testing
@testable import LearningCore

func sampleTranscript() async throws -> Transcript {
    let track = SubtitleTrack(id: "en", language: "en", origin: .external, cues: [
        SubtitleCue(range: TimeRange(startMs: 1_000, endMs: 3_000), text: "I'll pick you up at eight."),
        SubtitleCue(range: TimeRange(startMs: 3_500, endMs: 5_000), text: "Don't be late!"),
        SubtitleCue(range: TimeRange(startMs: 6_000, endMs: 9_000), text: "She was running out of time."),
    ])
    return try await TokenizeStage().run(Transcript(mediaID: "m1", track: track), context: PipelineContext(mediaID: "m1"))
}

@Test func findsSentenceAtTime() async throws {
    var t = try await sampleTranscript()
    #expect(t.sentenceIndex(at: MediaTime(ms: 1_500)) == 0)
    #expect(t.sentenceIndex(at: MediaTime(ms: 3_200)) == nil)
    #expect(t.sentenceIndex(atOrAfter: MediaTime(ms: 3_200)) == 1)
    #expect(t.sentenceIndex(at: MediaTime(ms: 8_999)) == 2)

    t = t.applying(.globalOffset(ms: 500))
    #expect(t.sentenceIndex(at: MediaTime(ms: 1_200)) == nil)
    #expect(t.sentenceIndex(at: MediaTime(ms: 1_600)) == 0)
}

@Test func tokenizesWordsAndPunctuation() async throws {
    let t = try await sampleTranscript()
    let s = t.sentences[2]
    let words = s.tokens.filter(\.isWord).map(\.text)
    #expect(words == ["She", "was", "running", "out", "of", "time"])
    #expect(s.tokens.last?.isWord == false)
    let running = try #require(s.tokens.first { $0.text == "running" })
    #expect(running.lemma == "run")
    let utf16 = Array(s.text.utf16)
    #expect(String(decoding: utf16[running.textRange], as: UTF16.self) == "running")
}

@Test func splitAndMergeKeepTokensConsistent() async throws {
    let t = try await sampleTranscript()
    let s = t.sentences[0]
    let atIndex = try #require(s.tokens.firstIndex { $0.text == "at" })

    let split = t.applying(.split(s.id, tokenIndex: atIndex))
    #expect(split.sentences.count == 4)
    #expect(split.sentences[0].text == "I'll pick you up")
    #expect(split.sentences[1].text == "at eight.")
    #expect(split.sentences[0].range.end == split.sentences[1].range.start)
    for sentence in split.sentences[0...1] {
        let utf16 = Array(sentence.text.utf16)
        for token in sentence.tokens {
            #expect(String(decoding: utf16[token.textRange], as: UTF16.self) == token.text)
        }
    }

    let merged = split.applying(.mergeWithNext(split.sentences[0].id))
    #expect(merged.sentences.count == 3)
    #expect(merged.sentences[0].text == "I'll pick you up at eight.")
    #expect(merged.sentences[0].range == s.range)
    let utf16 = Array(merged.sentences[0].text.utf16)
    for token in merged.sentences[0].tokens {
        #expect(String(decoding: utf16[token.textRange], as: UTF16.self) == token.text)
    }
}

@Test func userEditsSurviveRegeneration() async throws {
    let t = try await sampleTranscript()
    let edits: [TranscriptEdit] = [.shift(t.sentences[1].id, ms: -200), .delete(SentenceID(rawValue: "missing"))]
    let pipeline = TranscriptPipeline(stages: [UserEditsStage(edits: edits), TokenizeStage()])
    let regenerated = try await pipeline.run(t, context: PipelineContext(mediaID: "m1"))
    #expect(regenerated.sentences[1].range.start == MediaTime(ms: 3_300))
    #expect(regenerated.sentences.count == 3)
}

@Test func anchorsResolveAfterIDsChange() async throws {
    let t = try await sampleTranscript()
    let anchor = SentenceAnchor(mediaID: "m1", sentence: t.sentences[2])
    let edited = t.applying(.split(t.sentences[2].id, tokenIndex: 3))
    #expect(edited.index(of: anchor.sentenceID) == nil)
    let resolved = try #require(edited.resolve(anchor))
    #expect(edited.sentences[resolved].range.overlaps(anchor.range))
}

@Test func tagsAndAlignmentStages() async throws {
    var t = try await sampleTranscript()
    let zh = SubtitleTrack(id: "zh", language: "zh-Hans", origin: .external, cues: [
        SubtitleCue(range: TimeRange(startMs: 1_100, endMs: 3_000), text: "我八点去接你。"),
    ])
    let context = PipelineContext(mediaID: "m1", auxiliaryTracks: [zh])
    t = try await TranscriptPipeline(stages: [
        WordListTagStage(id: "list.top2000", tag: .top2000, lemmas: ["pick", "late", "run"]),
        TimeOverlapAlignStage(),
    ]).run(t, context: context)

    #expect(t.sentences[0].translations["zh-Hans"] == "我八点去接你。")
    #expect(t.sentences[1].translations["zh-Hans"] == nil)
    let tagged = t.sentences.flatMap(\.tokens).filter { $0.tags.contains(.top2000) }.map(\.text)
    #expect(tagged == ["pick", "late", "running"])

    let style = SubtitleTheme.standard.style(for: t.sentences[0].tokens.first { $0.text == "pick" }!)
    #expect(style.underline == .dotted)
}

@Test func programsRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(LearningProgram.intensiveListening)
    let decoded = try JSONDecoder().decode(LearningProgram.self, from: data)
    #expect(decoded == .intensiveListening)

    let bindings = Bindings.defaults.overlaid(with: Bindings(keys: [KeyBinding(KeyChord("space"), .replaySentence)]))
    #expect(bindings.command(for: KeyChord("space")) == .replaySentence)
    #expect(bindings.command(for: Gesture(.click, .option), on: .token) == .saveWord)
}

@Test func phraseLookupQuery() async throws {
    let t = try await sampleTranscript()
    let s = t.sentences[0]
    let pick = try #require(s.tokens.firstIndex { $0.text == "pick" })
    let up = try #require(s.tokens.firstIndex { $0.text == "up" })
    let query = try #require(LookupQuery(sentence: s, tokenRange: pick...up))
    #expect(query.surface == "pick you up")
    #expect(query.isPhrase)
}
