import Testing
@testable import KioskKit

@MainActor private func log(_ c: KioskController) -> [String] {
    c.messages.map { ($0.role == .kiosk ? "K: " : "P: ") + $0.text }
}

@MainActor @Test func voiceAnswersAreLoggedAsAChat() async {
    let (c, _) = makeController([[.final("Jane Demo")], [.final("DEMO001")]])
    c.start(); await eventually { c.flow.phase == .asking(2) }
    await eventually { c.messages.count >= 5 }
    #expect(Array(log(c).prefix(5)) == ["K: Full name", "P: Jane Demo", "K: Medicare or insurance ID", "P: DEMO001", "K: Date of birth"])
    #expect(c.messages.map(\.id) == Array(c.messages.map(\.id)).sorted() && Set(c.messages.map(\.id)).count == c.messages.count)
}
@MainActor @Test func typedSkippedAndRepeatedAreLogged() async {
    let c = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)))
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.messages.count == 1 }
    c.submitTyped(" "); await eventually { c.messages.count == 2 }
    c.submitTyped("Jane Demo"); c.submitTyped("DEMO001"); c.submitTyped("1980-05-01")
    await eventually { c.flow.phase == .asking(3) && c.messages.count == 8 }
    c.skip(); await eventually { c.messages.count == 10 }
    #expect(log(c) == ["K: Full name", "K: Full name", "P: Jane Demo", "K: Medicare or insurance ID", "P: DEMO001",
                       "K: Date of birth", "P: 1 May 1980", "K: What is the main reason for your visit today?",
                       "P: Skipped", "K: When did it start?"])
}
@MainActor @Test func readbackAndConfirmAreLogged() async {
    let (c, _) = makeController([[.final("Jane Demo, my ID is DEMO001")]], model: FakeAnswerModel(prefill: [1: "DEMO001"]))
    c.start(); await eventually { c.flow.phase == .confirmingCandidate(1) && c.messages.count == 3 }
    #expect(log(c).last == "K: You mentioned DEMO001. Is that right, or would you like to add anything?")
    c.confirmCandidate(); await eventually { c.messages.count == 5 }
    #expect(Array(log(c).suffix(2)) == ["P: DEMO001", "K: Date of birth"])
}
@MainActor @Test func resetClearsChat() async {
    let (c, _) = makeController([[.final("Jane Demo")]])
    c.start(); await eventually { c.messages.count >= 2 }
    c.reset()
    #expect(c.messages.isEmpty)
}
@MainActor @Test func lateTidyResultIsNotLogged() async throws {
    let (c, _) = makeController([[.final("Jane Demo")]], model: FakeAnswerModel(delay: .milliseconds(80)))
    c.start(); await eventually { c.transcript == "Jane Demo" }
    c.reset(); try await Task.sleep(for: .milliseconds(200))
    #expect(c.messages.isEmpty)
}
@MainActor @Test func dobReadbackIsSpokenAndLoggedReadably() async {
    let (c, speaker) = makeController([[.final("Jane Demo")], [.final("DEMO001")]], model: FakeAnswerModel(prefill: [2: "1980-05-01"]))
    c.start(); await eventually { c.flow.phase == .confirmingCandidate(2) && c.messages.count == 5 }
    let readback = "You mentioned 1 May 1980. Is that right, or would you like to add anything?"
    await eventually { speaker.spoken.last == readback }
    #expect(log(c).last == "K: " + readback)
    c.confirmCandidate(); await eventually { c.flow.phase == .asking(3) }
    #expect(c.flow.answers[2] == "1980-05-01" && log(c).contains("P: 1 May 1980"))
}
@MainActor @Test func typedDOBIsLoggedReadablyAndStoredAsISO() async {
    let c = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)))
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); c.submitTyped("Jane Demo"); c.submitTyped("DEMO001"); c.submitTyped("1/5/1980")
    await eventually { c.flow.phase == .asking(3) && c.messages.count == 7 }
    #expect(log(c)[5] == "P: 1 May 1980" && c.flow.answers[2] == "1980-05-01")
}
@MainActor @Test func resetMidSessionLeavesNextSessionClean() async throws {
    // Reset while the mic is open.
    let (listening, _) = makeController([])
    listening.start(); await eventually { listening.isListening }
    listening.reset(); listening.start()
    await eventually { listening.isListening }
    try await Task.sleep(for: .milliseconds(150))
    #expect(log(listening) == ["K: Full name"] && listening.flow.answers.allSatisfy(\.isEmpty) && listening.transcript.isEmpty)
    // Reset while the read-back is being spoken.
    let speaker = FakeSpeaker(delay: .milliseconds(100))
    let c = KioskController(speaker: speaker, listener: FakeListener(script: [[.final("Jane Demo, my ID is DEMO001")]]),
                            tidier: AnswerTidier(model: FakeAnswerModel(prefill: [1: "DEMO001"]), timeout: .milliseconds(100)), timings: .test)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { speaker.spoken.last?.hasPrefix("You mentioned") == true }
    c.reset(); c.start()
    try await Task.sleep(for: .milliseconds(250))
    #expect(log(c) == ["K: Full name"] && c.flow.phase == .asking(0))
    #expect(c.flow.answers.allSatisfy(\.isEmpty) && c.flow.candidates.isEmpty && c.transcript.isEmpty)
}
