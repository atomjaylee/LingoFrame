// PlaybackDirector 负责执行 LearningProgram：逐句、逐步骤驱动播放器。
// 它只依赖两个很窄的接口：SegmentPlayer（会播一段区间就行）和 DirectorHost（界面和录音由宿主提供），
// 所以学习功能不依赖具体播放内核。

@MainActor
public protocol SegmentPlayer: AnyObject {
    /// 播放 range，播到结尾时暂停并返回。所在任务被取消时，要立即暂停并抛出 CancellationError。
    func play(_ range: TimeRange, rate: Double) async throws
    func pause()
}

@MainActor
public protocol DirectorHost: AnyObject {
    var player: any SegmentPlayer { get }
    var display: SubtitleDisplay { get set }
    /// 等待用户按「继续」，比如空格键。
    func waitForUser() async throws
    func record(duration: MediaTime, for sentence: Sentence) async throws
    func sentenceDidBecomeCurrent(at index: Int, pass: Int)
    func emit(_ event: LearningEvent)
}

/// 扩展步骤的执行器，对应 PlaybackStep.custom(id:params:)。
@MainActor
public protocol StepHandler: AnyObject {
    var id: String { get }
    func run(params: [String: String], sentence: Sentence, host: any DirectorHost) async throws
}

public enum DirectorError: Error, Equatable {
    case unknownCustomStep(String)
    case sentenceOutOfRange(Int)
}

@MainActor
public final class PlaybackDirector {
    public let host: any DirectorHost
    public var stepHandlers: [String: any StepHandler]
    public private(set) var currentIndex: Int?
    public private(set) var activeProgram: LearningProgram?

    private var task: Task<Void, Never>?
    private var transcript: Transcript?

    public init(host: any DirectorHost, stepHandlers: [String: any StepHandler] = [:]) {
        self.host = host
        self.stepHandlers = stepHandlers
    }

    // MARK: 交互入口（界面调用）

    /// 从第 index 句开始执行程序。正在执行的程序会被取消。
    public func start(_ program: LearningProgram, in transcript: Transcript, at index: Int) {
        task?.cancel()
        self.transcript = transcript
        activeProgram = program
        task = Task { [weak self] in
            try? await self?.run(program, in: transcript, from: index)
        }
    }

    /// 跳到某一句，并保持当前程序（比如单句循环中按「下一句」，就循环下一句）。
    public func jump(to index: Int) {
        guard let program = activeProgram, let transcript else { return }
        start(program, in: transcript, at: index)
    }

    public func stop() {
        task?.cancel()
        task = nil
        activeProgram = nil
        host.player.pause()
    }

    // MARK: 执行

    public func run(_ program: LearningProgram, in transcript: Transcript, from index: Int) async throws {
        guard transcript.sentences.indices.contains(index) else { throw DirectorError.sentenceOutOfRange(index) }
        let savedDisplay = host.display
        defer { if host.display != savedDisplay { host.display = savedDisplay } }
        if let initial = program.initialDisplay { host.display = initial }

        var i = index
        while transcript.sentences.indices.contains(i) {
            try Task.checkCancellation()
            currentIndex = i
            let sentence = transcript.sentences[i]
            host.sentenceDidBecomeCurrent(at: i, pass: 0)
            host.emit(.sentenceStarted(mediaID: transcript.mediaID, sentence: sentence.id))

            var pass = 0
            try await execute(program.steps, sentenceIndex: i, in: transcript, program: program, pass: &pass)

            switch program.advance {
            case .single: return
            case .manual: try await host.waitForUser()
            case .automatic: break
            }
            i += 1
        }
        host.emit(.programFinished(programID: program.id))
    }

    private func execute(_ steps: [PlaybackStep], sentenceIndex i: Int, in transcript: Transcript,
                         program: LearningProgram, pass: inout Int) async throws {
        let sentence = transcript.sentences[i]
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case .play(let rate):
                let r = rate ?? program.defaultRate
                try await host.player.play(transcript.effectiveRange(of: sentence).padded(program.padding), rate: r)
                pass += 1
                host.emit(.sentencePlayed(mediaID: transcript.mediaID, sentence: sentence.id, rate: r))

            case .playTokens(let from, let to, let rate):
                let range = tokenRange(sentence, from: from, to: to) ?? sentence.range
                try await host.player.play(range.shifted(by: transcript.globalOffset).padded(.init(leadMs: 40, trailMs: 80)),
                                           rate: rate ?? program.defaultRate)

            case .pause(let seconds):
                try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))

            case .waitForUser:
                try await host.waitForUser()

            case .repeat(let count, let inner):
                var n = 0
                while count.map({ n < $0 }) ?? true {
                    try Task.checkCancellation()
                    host.sentenceDidBecomeCurrent(at: i, pass: pass)
                    try await execute(inner, sentenceIndex: i, in: transcript, program: program, pass: &pass)
                    n += 1
                }

            case .display(let display):
                host.display = display

            case .record(let factor):
                let ms = Int64(Double(sentence.range.duration.ms) * factor)
                try await host.record(duration: MediaTime(ms: ms), for: sentence)

            case .custom(let id, let params):
                guard let handler = stepHandlers[id] else { throw DirectorError.unknownCustomStep(id) }
                try await handler.run(params: params, sentence: sentence, host: host)
            }
        }
    }

    private func tokenRange(_ sentence: Sentence, from: Int, to: Int) -> TimeRange? {
        guard from <= to, sentence.tokens.indices.contains(from), sentence.tokens.indices.contains(to),
              let a = sentence.tokens[from].audioRange, let b = sentence.tokens[to].audioRange else { return nil }
        return TimeRange(start: a.start, end: b.end)
    }
}
