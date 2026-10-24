import Testing
@testable import KioskKit

@MainActor @Test func silenceEndsAnswerAndAdvances() async {
    let (c, speaker) = makeController([[.partial("Jane"), .final("Jane Demo")]])
    c.start()
    await eventually { c.flow.phase == .asking(1) }
    #expect(c.flow.answers[0] == "Jane Demo")
    #expect(speaker.spoken.prefix(2) == ["Full name", "Medicare or insurance ID"])
}
@MainActor @Test func noSpeechKeepsListening() async throws {
    let (c, _) = makeController([])
    c.start(); await eventually { c.isListening }
    try await Task.sleep(for: .milliseconds(200))
    #expect(c.isListening && c.flow.phase == .asking(0))
}
@MainActor @Test func emptyRequiredAnswerIsAskedAgain() async {
    let (c, speaker) = makeController([[.final("")], [.final("Jane Demo")]])
    c.start(); await eventually { c.flow.phase == .asking(1) }
    #expect(speaker.spoken.prefix(2) == ["Full name", "Full name"])
}
@MainActor @Test func prefillIsReadBackAndConfirmed() async {
    let (c, speaker) = makeController([[.final("Jane Demo, my ID is DEMO001")]], model: FakeAnswerModel(prefill: [1: "DEMO001"]))
    c.start(); await eventually { c.flow.phase == .confirmingCandidate(1) }
    #expect(speaker.spoken.last == "You mentioned DEMO001. Is that right, or would you like to add anything?")
    c.confirmCandidate(); await eventually { c.flow.phase == .asking(2) }
    #expect(c.flow.answers[1] == "DEMO001")
}
@MainActor @Test func skipAndRepeatAndTyping() async {
    let typing = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)))
    typing.submitter = Submitter(transport: FakeTransport(results: []))
    #expect(typing.inputMode == .typing)
    typing.start(); typing.submitTyped("Jane Demo"); typing.submitTyped("DEMO001"); typing.submitTyped("1980-05-01")
    await eventually { typing.flow.phase == .asking(3) }
    typing.skip(); await eventually { typing.flow.phase == .asking(4) }
    let (c, speaker) = makeController([])
    c.start(); await eventually { c.isListening }; c.repeatQuestion()
    await eventually { speaker.spoken == ["Full name", "Full name"] }
}
@MainActor @Test func listenErrorFallsBackToTyping() async throws {
    let speaker = FakeSpeaker()
    let c = KioskController(speaker: speaker, listener: FakeListener(script: [], failure: FakeError()),
                            tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.inputMode == .typing }
    try await Task.sleep(for: .milliseconds(100))
    #expect(c.flow.phase == .asking(0) && c.flow.answers[0] == "" && !c.isListening)
    #expect(speaker.spoken == ["Full name"])
}
@MainActor func typingAtCandidate(_ listener: FakeListener? = nil) async -> KioskController {
    let c = KioskController(speaker: FakeSpeaker(), listener: listener,
                            tidier: AnswerTidier(model: FakeAnswerModel(prefill: [1: "DEMO001"])), timings: .test)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.inputMode = .typing
    c.start(); c.submitTyped("Jane Demo")
    await eventually { c.flow.phase == .confirmingCandidate(1) }
    return c
}
@MainActor @Test func typedAddAndReplaceCandidate() async {
    let add = await typingAtCandidate()
    add.addToCandidate(); add.submitTyped("extra")
    #expect(add.flow.answers[1] == "DEMO001 extra" && add.flow.phase == .asking(2))
    let replace = await typingAtCandidate()
    replace.replaceCandidate(); replace.submitTyped("NEW1")
    #expect(replace.flow.answers[1] == "NEW1" && replace.flow.phase == .asking(2))
}
@MainActor @Test func typingModeAddDoesNotOpenMic() async throws {
    let listener = FakeListener(script: [])
    let c = await typingAtCandidate(listener)
    c.addToCandidate(); try await Task.sleep(for: .milliseconds(100))
    c.replaceCandidate(); try await Task.sleep(for: .milliseconds(100))
    #expect(listener.listens == 0 && !c.isListening)
}
@MainActor func voiceController(_ script: [[ListenEvent]]) -> (KioskController, FakeListener) {
    let listener = FakeListener(script: script)
    let c = KioskController(speaker: FakeSpeaker(), listener: listener,
                            tidier: AnswerTidier(model: FakeAnswerModel(), timeout: .milliseconds(100)), timings: .test)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    return (c, listener)
}
@MainActor @Test func beginTypingStopsListeningWithoutSubmitting() async throws {
    let (c, _) = voiceController([[.partial("Ja")]])
    c.start(); await eventually { c.caption == "Ja" }
    c.beginTyping()
    #expect(!c.isListening && c.caption.isEmpty)
    try await Task.sleep(for: .milliseconds(150))
    #expect(c.flow.answers[0] == "" && c.flow.phase == .asking(0) && !c.isListening)
    c.submitTyped("Jane Demo")
    await eventually { c.flow.phase == .asking(1) }
    #expect(c.flow.answers[0] == "Jane Demo")
}
@MainActor @Test func typedAnswerReopensMicForNextQuestion() async {
    let (c, listener) = voiceController([[.partial("Ja")]])
    c.start(); await eventually { c.isListening }
    #expect(listener.listens == 1)
    c.beginTyping(); c.submitTyped("Jane Demo")
    await eventually { c.flow.phase == .asking(1) && c.isListening }
    #expect(listener.listens == 2 && c.inputMode == .voice)
}
@MainActor @Test func typingDuringVoiceAddMoreAppends() async {
    let listener = FakeListener(script: [[.final("Jane Demo, my ID is DEMO001")]])
    let c = KioskController(speaker: FakeSpeaker(), listener: listener,
                            tidier: AnswerTidier(model: FakeAnswerModel(prefill: [1: "DEMO001"]), timeout: .milliseconds(100)), timings: .test)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.flow.phase == .confirmingCandidate(1) }
    c.addToCandidate(); await eventually { c.isListening }
    c.beginTyping(); c.submitTyped("X")
    await eventually { c.flow.phase == .asking(2) }
    #expect(c.flow.answers[1] == "DEMO001 X")
}
