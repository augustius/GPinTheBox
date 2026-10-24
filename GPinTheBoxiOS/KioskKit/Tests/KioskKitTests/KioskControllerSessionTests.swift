import Testing
@testable import KioskKit

@MainActor func controllerAtReview(_ transport: FakeTransport, timings: KioskTimings = .test, listener: FakeListener? = nil) async -> KioskController {
    let c = KioskController(speaker: FakeSpeaker(), listener: listener, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)), timings: timings)
    c.submitter = Submitter(transport: transport, backoff: [.milliseconds(1)], deadline: .milliseconds(200))
    c.inputMode = .typing
    c.start(); for text in ["Jane Demo", "DEMO001", "1980-05-01"] { c.submitTyped(text) }
    for _ in 3..<10 { await eventually { c.flow.currentIndex != nil }; c.skip() }
    await eventually { c.flow.phase == .review }
    return c
}
@MainActor @Test func acceptedSendShowsDoneThenWipes() async {
    let t = FakeTransport(results: [.success(.ok)])
    let c = await controllerAtReview(t, timings: .test.with(doneReset: .milliseconds(50)))
    c.send(); await eventually { c.flow.phase == .done }
    await eventually { c.flow == IntakeFlow() && c.transcript.isEmpty }
}
@MainActor @Test func retriedSendKeepsSubmissionID() async {
    let t = FakeTransport(results: Array(repeating: .failure(FakeError()), count: 500))
    let c = await controllerAtReview(t)
    c.send(); await eventually { c.flow.phase == .sendFailed("Couldn't reach the clinic — ask reception") }
    #expect(c.flow.answers[0] == "Jane Demo")
    c.send(); await eventually { if case .sendFailed = c.flow.phase { true } else { false } }
    #expect(Set(await t.requests.map(\.submissionID)).count == 1)
}
@MainActor @Test func rejectedSendReturnsToReview() async {
    let c = await controllerAtReview(FakeTransport(results: [.success(.error(message: "Enter a valid date of birth."))]))
    c.send(); await eventually { c.lastError == "Enter a valid date of birth." }
    #expect(c.flow.phase == .review && c.flow.answers[2] == "1980-05-01")
}
@MainActor @Test func idlePromptThenReset() async {
    let c = await controllerAtReview(FakeTransport(results: []), timings: .test.with(idle: .milliseconds(50), idleGrace: .milliseconds(50)))
    await eventually { c.isAskingStillThere }
    c.stillHere(); #expect(!c.isAskingStillThere && c.flow.phase == .review)
    await eventually { c.flow.phase == .welcome && c.flow.answers.allSatisfy(\.isEmpty) }
}
@MainActor @Test func idleResetWipesAfterSendFailure() async {
    let c = await controllerAtReview(FakeTransport(results: Array(repeating: .failure(FakeError()), count: 500)),
                                     timings: .test.with(idle: .milliseconds(400), idleGrace: .milliseconds(50)))
    c.send(); await eventually { if case .sendFailed = c.flow.phase { true } else { false } }
    await eventually { c.flow.phase == .welcome && c.flow.answers.allSatisfy(\.isEmpty) }
}
@MainActor @Test func resetDuringTidyDiscardsLateResult() async throws {
    let (c, _) = makeController([[.final("Jane Demo")]], model: FakeAnswerModel(delay: .milliseconds(80)))
    c.start(); await eventually { c.transcript == "Jane Demo" }
    c.reset(); try await Task.sleep(for: .milliseconds(200))
    #expect(c.flow == IntakeFlow() && c.transcript.isEmpty)
}
@MainActor @Test func respeakReplacesAnswerOnlyInVoiceMode() async throws {
    let listener = FakeListener(script: [[.final("John Smith")]])
    let c = await controllerAtReview(FakeTransport(results: []), listener: listener)
    c.respeak(0); try await Task.sleep(for: .milliseconds(100))
    #expect(listener.listens == 0 && c.flow.answers[0] == "Jane Demo")
    c.inputMode = .voice; c.respeak(0)
    await eventually { c.flow.answers[0] == "John Smith" }
    #expect(c.flow.phase == .review && !c.isListening)
}
@MainActor @Test func sendWithoutClinicShowsUnreachable() async {
    let c = await controllerAtReview(FakeTransport(results: []))
    c.submitter = nil
    c.send()
    #expect(c.flow.phase == .sendFailed("Couldn't reach the clinic — ask reception"))
    #expect(c.flow.answers[0] == "Jane Demo" && c.flow.answers[2] == "1980-05-01")
    c.send()
    #expect(c.flow.phase == .sendFailed("Couldn't reach the clinic — ask reception"))
}
@MainActor @Test func editDuringRespeakWinsOverLateSpeech() async throws {
    let listener = FakeListener(script: [])
    let c = await controllerAtReview(FakeTransport(results: []), listener: listener)
    c.inputMode = .voice; c.respeak(0); await eventually { c.isListening }
    c.edit(0, to: "Jane Typed")
    try await Task.sleep(for: .milliseconds(20))
    listener.deliver(.final("yeah")); try await Task.sleep(for: .milliseconds(200))
    #expect(c.flow.answers[0] == "Jane Typed" && !c.isListening)
}
@MainActor @Test func cancelRespeakStopsListeningAndKeepsAnswer() async throws {
    let listener = FakeListener(script: [[.partial("Jo")]])
    let c = await controllerAtReview(FakeTransport(results: []), listener: listener)
    c.inputMode = .voice; c.respeak(0); await eventually { c.caption == "Jo" }
    c.cancelRespeak()
    #expect(!c.isListening && c.caption.isEmpty)
    await eventually { !listener.isOpen }
    listener.deliver(.final("John Smith")); try await Task.sleep(for: .milliseconds(150))
    #expect(c.flow.answers[0] == "Jane Demo" && !c.isListening && c.flow.phase == .review)
}
