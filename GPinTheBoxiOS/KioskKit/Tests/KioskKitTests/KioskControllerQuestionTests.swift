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
