import Synchronization
import Testing
import KioskProtocol
@testable import KioskKit

struct FakeError: Error {}

struct FakeAnswerModel: AnswerModel {
    var isAvailable = true
    var tidied: [String: String] = [:]
    var prefill: [Int: String] = [:]
    var delay: Duration? = nil
    var error: (any Error & Sendable)? = nil

    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String {
        try await perform { tidied[transcript] ?? transcript }
    }
    func prefill(transcript: String, remaining: [KioskQuestion]) async throws -> [Int: String] {
        try await perform { prefill }
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
    var spoken: [String] { log.withLock { $0 } }
    func speak(_ text: String) async { log.withLock { $0.append(text) } }
    func stop() async {}
}

final class FakeListener: AnswerListener {
    private struct State { var scripts: [[ListenEvent]]; var waiting: [AsyncThrowingStream<ListenEvent, Error>.Continuation] = [] }
    private let state: Mutex<State>
    init(script: [[ListenEvent]]) { state = Mutex(State(scripts: script)) }

    func listen() -> AsyncThrowingStream<ListenEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ListenEvent, Error>.makeStream()
        let events = state.withLock { s in
            s.waiting.append(continuation)
            return s.scripts.isEmpty ? [] : s.scripts.removeFirst()
        }
        events.forEach { continuation.yield($0) }
        return stream
    }

    func stop() async {
        state.withLock { s in defer { s.waiting = [] }; return s.waiting }.forEach { $0.finish() }
    }
}

extension KioskTimings {
    static let test = KioskTimings(silence: .milliseconds(30), idle: .seconds(60), idleGrace: .seconds(60), doneReset: .seconds(60))
    func with(idle: Duration? = nil, idleGrace: Duration? = nil, doneReset: Duration? = nil) -> KioskTimings {
        KioskTimings(silence: silence, idle: idle ?? self.idle, idleGrace: idleGrace ?? self.idleGrace, doneReset: doneReset ?? self.doneReset)
    }
}

@MainActor func makeController(_ script: [[ListenEvent]], model: FakeAnswerModel = FakeAnswerModel(),
                               transport: FakeTransport = FakeTransport(results: [.success(.ok)])) -> (KioskController, FakeSpeaker) {
    let speaker = FakeSpeaker()
    let c = KioskController(speaker: speaker, listener: FakeListener(script: script),
                            tidier: AnswerTidier(model: model, timeout: .milliseconds(100)), timings: .test)
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
