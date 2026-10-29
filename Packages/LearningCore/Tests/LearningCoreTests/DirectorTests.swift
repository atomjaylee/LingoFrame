import Testing
@testable import LearningCore

@MainActor
final class FakePlayer: SegmentPlayer {
    var log: [String] = []

    func play(_ range: TimeRange, rate: Double) async throws {
        try Task.checkCancellation()
        log.append("play \(range.start.ms)-\(range.end.ms) x\(rate)")
        await Task.yield()
    }

    func pause() { log.append("pause") }
}

@MainActor
final class FakeHost: DirectorHost {
    let fakePlayer = FakePlayer()
    var player: any SegmentPlayer { fakePlayer }
    var display = SubtitleDisplay() {
        didSet { fakePlayer.log.append("display \(display.primary)/\(display.translation)") }
    }
    var events: [LearningEvent] = []

    func waitForUser() async throws { fakePlayer.log.append("wait") }

    func record(duration: MediaTime, for sentence: Sentence) async throws {
        fakePlayer.log.append("record \(duration.ms)")
    }

    func sentenceDidBecomeCurrent(at index: Int, pass: Int) {}
    func emit(_ event: LearningEvent) { events.append(event) }
}

@MainActor
final class SpeakWordStep: StepHandler {
    let id = "test.speak"
    var spoken: [String] = []

    func run(params: [String: String], sentence: Sentence, host: any DirectorHost) async throws {
        spoken.append(params["word"] ?? sentence.text)
    }
}

private let transcript = Transcript(mediaID: "m1", language: "en", sentences: [
    Sentence(range: TimeRange(startMs: 1_000, endMs: 2_000), text: "One."),
    Sentence(range: TimeRange(startMs: 3_000, endMs: 4_000), text: "Two."),
])

@MainActor
@Test func loopsOneSentenceThreeTimes() async throws {
    let host = FakeHost()
    let program = LearningProgram(id: "t", name: "t", steps: [.repeat(count: 3, steps: [.play()])],
                                  advance: .single, padding: .none)
    try await PlaybackDirector(host: host).run(program, in: transcript, from: 1)
    #expect(host.fakePlayer.log == Array(repeating: "play 3000-4000 x1.0", count: 3))
}

@MainActor
@Test func shadowingAppliesPaddingRecordingAndRestoresDisplay() async throws {
    let host = FakeHost()
    try await PlaybackDirector(host: host).run(.shadowing, in: transcript, from: 0)
    #expect(host.fakePlayer.log == [
        "display visible/hidden", "play 920-2200 x1.0", "record 1300", "play 920-2200 x1.0",
        "display visible/hidden", "play 2920-4200 x1.0", "record 1300", "play 2920-4200 x1.0",
        "display visible/visible",
    ])
    #expect(host.events.last == .programFinished(programID: "builtin.shadowing"))
}

@MainActor
@Test func customStepsRunThroughRegisteredHandlers() async throws {
    let host = FakeHost()
    let speak = SpeakWordStep()
    let program = LearningProgram(id: "t", name: "t",
                                  steps: [.custom(id: "test.speak", params: ["word": "two"]), .play(rate: 0.5)],
                                  advance: .single, padding: .none)
    try await PlaybackDirector(host: host, stepHandlers: [speak.id: speak]).run(program, in: transcript, from: 1)
    #expect(speak.spoken == ["two"])
    #expect(host.fakePlayer.log == ["play 3000-4000 x0.5"])

    await #expect(throws: DirectorError.unknownCustomStep("missing")) {
        let bad = LearningProgram(id: "b", name: "b", steps: [.custom(id: "missing")], advance: .single)
        try await PlaybackDirector(host: host).run(bad, in: transcript, from: 0)
    }
}

@MainActor
@Test func jumpCancelsInfiniteLoopAndContinuesOnNewSentence() async throws {
    let host = FakeHost()
    let director = PlaybackDirector(host: host)
    director.start(.loopSentence, in: transcript, at: 0)
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(host.fakePlayer.log.contains("play 920-2200 x1.0"))

    director.jump(to: 1)
    try await Task.sleep(for: .milliseconds(100))
    director.stop()
    #expect(host.fakePlayer.log.contains("play 2920-4200 x1.0"))
    #expect(host.fakePlayer.log.last == "pause")
    #expect(director.currentIndex == 1)
}
