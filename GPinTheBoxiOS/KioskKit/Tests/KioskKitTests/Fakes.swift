import Synchronization
import Testing
@testable import KioskKit

struct FakeError: Error {}

struct FakeAnswerModel: AnswerModel {
    var isAvailable = true
    var tidied: [String: String] = [:]
    var extracted: [Int: String] = [:]
    var delay: Duration? = nil
    var error: (any Error & Sendable)? = nil
    /// Per-reply extractions, returned as is (the real model sees answered questions too); other replies get `extracted`, limited to unanswered questions.
    var byReply: [String: [Int: String]] = [:]

    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String {
        try await perform { tidied[transcript] ?? transcript }
    }
    func extract(reply: String, target: KioskQuestion, unanswered: [KioskQuestion]) async throws -> [Int: String] {
        let ids = Set(unanswered.map(\.id))
        return try await perform { byReply[reply] ?? extracted.filter { ids.contains($0.key) } }
    }
    private func perform<T>(_ result: () -> T) async throws -> T {
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return result()
    }
}

actor FakeTransport: KioskTransport {
    private var results: [Result<KioskResponse, any Error>]
    private(set) var requests: [KioskRequest] = []
    init(results: [Result<KioskResponse, any Error>]) { self.results = results }

    func send(_ request: KioskRequest) async throws -> KioskResponse {
        requests.append(request)
        guard !results.isEmpty else { throw FakeError() }
        return try results.removeFirst().get()
    }
}

final class FakeSpeaker: QuestionSpeaker {
    private let log = Mutex<[String]>([])
    private let delay: Duration?
    var spoken: [String] { log.withLock { $0 } }
    /// With `delay`, each `speak` takes that long, as a real spoken question does.
    init(delay: Duration? = nil) { self.delay = delay }
    func speak(_ text: String) async {
        log.withLock { $0.append(text) }
        if let delay { try? await Task.sleep(for: delay) }
    }
    func stop() async {}
}

final class FakeListener: AnswerListener {
    private struct State { var scripts: [[ListenEvent]]; var waiting: [AsyncThrowingStream<ListenEvent, Error>.Continuation] = []; var listens = 0 }
    private let state: Mutex<State>
    private let failure: (any Error & Sendable)?
    var listens: Int { state.withLock { $0.listens } }
    /// With `failure`, every `listen()` ends at once with that error.
    init(script: [[ListenEvent]], failure: (any Error & Sendable)? = nil) { state = Mutex(State(scripts: script)); self.failure = failure }

    func listen() -> AsyncThrowingStream<ListenEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ListenEvent, Error>.makeStream()
        if let failure { state.withLock { $0.listens += 1 }; continuation.finish(throwing: failure); return stream }
        let events = state.withLock { s in
            s.listens += 1; s.waiting.append(continuation)
            return s.scripts.isEmpty ? [] : s.scripts.removeFirst()
        }
        events.forEach { continuation.yield($0) }
        return stream
    }

    func stop() async {
        state.withLock { s in defer { s.waiting = [] }; return s.waiting }.forEach { $0.finish() }
    }
    /// True while a `listen()` stream is still open (not yet stopped).
    var isOpen: Bool { state.withLock { !$0.waiting.isEmpty } }
    /// Sends a late event to every open `listen()` stream, as speech heard nearby would.
    func deliver(_ event: ListenEvent) { state.withLock { $0.waiting }.forEach { $0.yield(event) } }
}

extension KioskTimings {
    static let test = KioskTimings(silence: .milliseconds(30), idle: .seconds(60), idleGrace: .seconds(60), doneReset: .seconds(60), cantProceedReset: .seconds(60))
    func with(idle: Duration? = nil, idleGrace: Duration? = nil, doneReset: Duration? = nil, cantProceedReset: Duration? = nil) -> KioskTimings {
        KioskTimings(silence: silence, idle: idle ?? self.idle, idleGrace: idleGrace ?? self.idleGrace, doneReset: doneReset ?? self.doneReset,
                     cantProceedReset: cantProceedReset ?? self.cantProceedReset)
    }
}

@MainActor func makeController(_ script: [[ListenEvent]], model: FakeAnswerModel = FakeAnswerModel(),
                               transport: FakeTransport = FakeTransport(results: [.success(.ok)]), seed: UInt64 = 1,
                               timings: KioskTimings = .test) -> (KioskController, FakeSpeaker) {
    let speaker = FakeSpeaker()
    let c = KioskController(speaker: speaker, listener: FakeListener(script: script),
                            tidier: AnswerTidier(model: model, timeout: .milliseconds(100)), timings: timings, seed: seed)
    c.submitter = Submitter(transport: transport)
    return (c, speaker)
}

@MainActor func eventually(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(2))
    while !condition() {
        guard clock.now < end else { Issue.record("Condition not met within 2 s", sourceLocation: sourceLocation); return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
