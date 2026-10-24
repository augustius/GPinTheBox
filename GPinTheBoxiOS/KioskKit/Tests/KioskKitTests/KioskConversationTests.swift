import Testing
@testable import KioskKit

@MainActor @Test func oneReplyFillsSeveralAndShowsChips() async {
    let (c, speaker) = makeController([[.final("I'm Jane Demo, cough since Monday")]],
        model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"]), seed: 1)
    c.start(); await eventually { c.flow.phase == .asking(1) }
    let reply = c.messages.first { $0.role == .patient }!
    #expect(reply.text == "I'm Jane Demo, cough since Monday" && reply.picked == [0: "Jane Demo", 3: "Cough", 4: "Since Monday"])
    #expect(speaker.spoken.first?.hasPrefix("Hey! Thanks for coming in.") == true)  // emoji not spoken
    #expect(c.messages.first?.text.hasPrefix("Hey! 👋") == true)
}
@MainActor @Test func answeringAnotherQuestionReasksTarget() async {
    let (c, _) = makeController([[.final("I've got a cough")]], model: FakeAnswerModel(extracted: [3: "Cough"]), seed: 1)
    c.start(); await eventually { c.flow.askCounts[0] == 2 }
    #expect(c.flow.phase == .asking(0) && c.flow.answers[0] == "" && c.flow.answers[3] == "Cough")
}
@MainActor @Test func cantProceedSendsNothingAndWipes() async {
    let t = FakeTransport(results: [.success(.ok)])
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false), transport: t, seed: 1,
                                timings: .test.with(cantProceedReset: .milliseconds(80)))
    c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.askCounts[1] == 1 }
    c.submitTyped("pass"); await eventually { c.flow.askCounts[1] == 2 }   // wait for each digest; a new submit supersedes an in-flight one
    c.submitTyped("pass"); await eventually { c.flow.askCounts[1] == 3 }
    c.submitTyped("pass"); await eventually { c.flow.phase == .cantProceed(1) }
    #expect(c.messages.last?.text == "Sorry, we can't proceed without your Medicare or insurance ID. Please see reception — they can help.")
    await eventually { c.flow.phase == .welcome && c.messages.isEmpty }
    #expect(await t.requests.isEmpty)
}
@MainActor @Test func quietModeNeitherSpeaksNorListens() async {
    let speaker = FakeSpeaker(); let listener = FakeListener(script: [])
    let c = KioskController(speaker: speaker, listener: listener, tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: [])); c.inputMode = .typing; c.start()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(speaker.spoken.isEmpty && listener.listens == 0 && c.messages.count == 1)
    c.speakAgain(); await eventually { speaker.spoken.count == 1 }; #expect(c.flow.askCounts[0] == 1)
}
@MainActor @Test func rephraseCountsAsAskAndPostsNewVariant() async {
    let (c, _) = makeController([], seed: 2); c.inputMode = .typing; c.start()
    let first = c.messages.last!.text; c.rephrase()
    #expect(c.flow.askCounts[0] == 2 && c.messages.last!.text != first)
}
@MainActor @Test func chipEditDuringListenIsKept() async {
    let (c, _) = makeController([[.final("Jane Demo")], []], model: FakeAnswerModel(extracted: [0: "Jane Demo"]), seed: 1)
    c.start(); await eventually { c.flow.phase == .asking(1) && c.isListening }
    c.edit(0, to: "Jane Q Demo"); #expect(c.flow.answers[0] == "Jane Q Demo")
    #expect(c.messages.first { $0.role == .patient }?.picked[0] == "Jane Q Demo" && c.isListening)
}
@MainActor @Test func resetDuringDigestDropsChips() async {
    let (c, _) = makeController([[.final("Jane Demo")]], model: FakeAnswerModel(extracted: [0: "Jane Demo"], delay: .milliseconds(150)), seed: 1)
    c.start(); await eventually { c.messages.contains { $0.role == .patient } }
    c.reset(); try? await Task.sleep(for: .milliseconds(300))
    #expect(c.flow == IntakeFlow() && c.messages.isEmpty)
}
@MainActor @Test func dictationFillsFieldWithoutSubmitting() async {
    let (c, _) = makeController([[], [.final("Jane Demo")]], seed: 1); c.start()
    await eventually { c.isListening }; c.dictate()
    await eventually { c.dictated == "Jane Demo" }
    #expect(c.flow.phase == .asking(0) && !c.messages.contains { $0.role == .patient })
}
@MainActor @Test func optionalSkipShowsNoneChip() async {
    let (c, _) = makeController([], model: FakeAnswerModel(extracted: [:]), seed: 1); c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.phase == .asking(1) }
    c.submitTyped("D1"); await eventually { c.flow.phase == .asking(2) }
    c.submitTyped("1/5/1980"); await eventually { c.flow.phase == .asking(3) }
    c.submitTyped("no"); await eventually { c.flow.phase == .asking(4) }
    #expect(c.flow.isAnsweredEmpty(3) && c.messages.last { $0.role == .patient }?.picked == [3: ""])
    #expect(c.flow.answers[2] == "1980-05-01")
}

// MARK: - Voice turn-taking (kept from v1)

@MainActor func voiceController(_ script: [[ListenEvent]], model: FakeAnswerModel = FakeAnswerModel(),
                                speaker: FakeSpeaker = FakeSpeaker()) -> (KioskController, FakeListener) {
    let listener = FakeListener(script: script)
    let c = KioskController(speaker: speaker, listener: listener,
                            tidier: AnswerTidier(model: model, timeout: .milliseconds(200)), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    return (c, listener)
}
@MainActor @Test func noSpeechKeepsListening() async throws {
    let (c, _) = makeController([])
    c.start(); await eventually { c.isListening }
    try await Task.sleep(for: .milliseconds(200))
    #expect(c.isListening && c.flow.phase == .asking(0))
}
@MainActor @Test func listenErrorFallsBackToTyping() async throws {
    let speaker = FakeSpeaker()
    let c = KioskController(speaker: speaker, listener: FakeListener(script: [], failure: FakeError()),
                            tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.inputMode == .typing }
    try await Task.sleep(for: .milliseconds(100))
    #expect(c.flow.phase == .asking(0) && c.flow.answers[0] == "" && !c.isListening)
    #expect(speaker.spoken == [CasualLines.spoken(c.messages[0].text)] && c.flow.askCounts[0] == 1)
}
@MainActor @Test func beginTypingStopsListeningWithoutSubmitting() async throws {
    let (c, _) = voiceController([[.partial("Ja")]])
    c.start(); await eventually { c.caption == "Ja" }
    c.beginTyping()
    #expect(!c.isListening && c.caption.isEmpty)
    try await Task.sleep(for: .milliseconds(150))
    #expect(c.flow.answers[0] == "" && c.flow.phase == .asking(0) && !c.isListening && c.messages.count == 1)
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
@MainActor @Test func typingWhileQuestionIsSpokenKeepsMicClosed() async throws {
    let (c, listener) = voiceController([], speaker: FakeSpeaker(delay: .milliseconds(100)))
    c.start(); c.beginTyping()
    try await Task.sleep(for: .milliseconds(250))
    #expect(listener.listens == 0 && !c.isListening && c.inputMode == .voice)
    c.endTyping(); await eventually { c.isListening }
    #expect(listener.listens == 1)
    c.beginTyping(); c.submitTyped("Jane Demo")
    await eventually { c.flow.phase == .asking(1) && c.isListening }
    #expect(listener.listens == 2 && c.flow.answers[0] == "Jane Demo")
}

// MARK: - Replacements for the v1 read-back tests

@MainActor @Test func blankVoiceReplyIsReaskedAndNotLogged() async {
    let (c, _) = makeController([[.final("")], []])
    c.start(); await eventually { c.flow.askCounts[0] == 2 && c.isListening }
    #expect(c.flow.phase == .asking(0) && c.messages.count == 2 && !c.messages.contains { $0.role == .patient })
}
@MainActor @Test func blankTypedReplyIsIgnored() async throws {
    let (c, _) = makeController([]); c.inputMode = .typing; c.start()
    c.submitTyped("   "); try await Task.sleep(for: .milliseconds(50))
    #expect(c.messages.count == 1 && c.flow.askCounts[0] == 1 && c.flow.phase == .asking(0))
}
@MainActor @Test func laterRepliesOnlyFillUnansweredQuestions() async {
    let (c, _) = makeController([], model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Cough"])); c.inputMode = .typing; c.start()
    c.submitTyped("Jane Demo, I've got a cough"); await eventually { c.flow.phase == .asking(1) }
    c.submitTyped("demo 001"); await eventually { c.flow.phase == .asking(2) }
    #expect(c.messages.last { $0.role == .patient }?.picked == [1: "DEMO001"])
    #expect(c.flow.answers[0] == "Jane Demo" && c.flow.answers[3] == "Cough")
}
@MainActor @Test func dobChipHoldsISOAndEditNormalises() async {
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false)); c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.phase == .asking(1) }
    c.submitTyped("D1"); await eventually { c.flow.phase == .asking(2) }
    c.submitTyped("1/5/1980"); await eventually { c.flow.phase == .asking(3) }
    let dobReply = c.messages.last { $0.role == .patient }!
    #expect(dobReply.text == "1/5/1980" && AnswerFormatting.readableDOB(dobReply.picked[2]!) == "1 May 1980")
    c.edit(2, to: "2 June 1981")
    #expect(c.flow.answers[2] == "1981-06-02" && c.messages.first { $0.id == dobReply.id }?.picked[2] == "1981-06-02")
    #expect(c.flow.phase == .asking(3) && c.flow.askCounts[3] == 1)
}
@MainActor @Test func clearingRequiredChipAsksForItAgain() async {
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false)); c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.phase == .asking(1) }
    let count = c.messages.count
    c.edit(0, to: " ")
    #expect(c.flow.phase == .asking(0) && c.flow.askCounts[0] == 1 && c.messages.count == count + 1)
    #expect(c.messages.last?.role == .kiosk && c.messages.allSatisfy { $0.picked[0] == nil })
}
@MainActor @Test func editOfUnansweredQuestionIsIgnored() async {
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false)); c.inputMode = .typing; c.start()
    c.submitTyped("pass"); await eventually { c.flow.askCounts[0] == 2 }
    c.edit(0, to: ""); c.edit(0, to: "Jane")
    #expect(c.flow.askCounts[0] == 2 && c.flow.answers[0] == "" && c.flow.phase == .asking(0))
}
@MainActor @Test func clearingRequiredOnReviewStaysOnReview() async {
    let c = await controllerAtReview(FakeTransport(results: []))
    let count = c.messages.count
    c.edit(1, to: "")
    #expect(c.flow.phase == .review && !c.flow.canSend && c.messages.count == count)
    c.edit(1, to: "DEMO002"); #expect(c.flow.canSend && c.flow.answers[1] == "DEMO002")
}
@MainActor @Test func endTypingDuringDigestKeepsReply() async {
    let (c, _) = voiceController([[.partial("Ja")]], model: FakeAnswerModel(delay: .milliseconds(60)))
    c.start(); await eventually { c.isListening }
    c.beginTyping(); c.submitTyped("Jane Demo"); c.endTyping()
    await eventually { c.flow.phase == .asking(1) && c.isListening }
    #expect(c.flow.answers[0] == "Jane Demo")
}
@MainActor @Test func modeToggleDuringDigestKeepsReply() async {
    let (c, listener) = voiceController([], model: FakeAnswerModel(delay: .milliseconds(60)))
    c.inputMode = .typing; c.start()
    c.submitTyped("Jane Demo"); c.inputMode = .voice
    await eventually { c.flow.phase == .asking(1) && c.isListening }
    #expect(c.flow.answers[0] == "Jane Demo" && listener.listens == 1)
}
@MainActor @Test func draftStartedDuringDigestKeepsMicClosed() async throws {
    let speaker = FakeSpeaker()
    let (c, listener) = voiceController([[.partial("Ja")]], model: FakeAnswerModel(delay: .milliseconds(60)), speaker: speaker)
    c.start(); await eventually { c.isListening }
    c.beginTyping(); c.submitTyped("Jane Demo"); c.beginTyping()
    await eventually { c.flow.phase == .asking(1) && speaker.spoken.count == 2 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(listener.listens == 1 && !c.isListening)
    c.endTyping(); await eventually { c.isListening }
}
@MainActor @Test func voiceOnSpeaksLatestLineWithoutCounting() async throws {
    let (c, speaker) = makeController([]); c.inputMode = .typing; c.start()
    c.beginTyping(); c.inputMode = .voice
    await eventually { speaker.spoken.count == 1 }
    try await Task.sleep(for: .milliseconds(80))
    #expect(!c.isListening && c.flow.askCounts[0] == 1 && speaker.spoken == [CasualLines.spoken(c.messages[0].text)])
    c.inputMode = .typing; c.endTyping(); c.inputMode = .voice
    await eventually { c.isListening && speaker.spoken.count == 2 }
    #expect(c.flow.askCounts[0] == 1 && c.messages.count == 1)
}
@MainActor @Test func quietModeStopsListeningAndRepliesNeverOpenMic() async {
    let listener = FakeListener(script: [])
    let c = KioskController(speaker: FakeSpeaker(), listener: listener, tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.isListening }
    c.inputMode = .typing
    #expect(!c.isListening); await eventually { !listener.isOpen }
    c.submitTyped("Jane Demo"); await eventually { c.flow.phase == .asking(1) }
    c.edit(0, to: "Jane Q Demo"); try? await Task.sleep(for: .milliseconds(80))
    #expect(listener.listens == 1 && !c.isListening)
}
@MainActor @Test func resetMidSessionLeavesNextSessionClean() async throws {
    let listener = FakeListener(script: [[.partial("Jane")]])
    let speaker = FakeSpeaker(delay: .milliseconds(80))
    let c = KioskController(speaker: speaker, listener: listener, tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: []))
    c.start(); await eventually { c.caption == "Jane" }
    c.reset(); listener.deliver(.final("Jane Demo"))       // mic open: late speech must not land
    try await Task.sleep(for: .milliseconds(150))
    c.start(); try await Task.sleep(for: .milliseconds(20))
    c.reset()                                              // line being spoken
    try await Task.sleep(for: .milliseconds(150))
    c.start(); await eventually { c.isListening }
    #expect(c.messages.count == 1 && c.messages.allSatisfy { $0.role == .kiosk && $0.picked.isEmpty })
    #expect(c.flow.answers.allSatisfy(\.isEmpty) && c.flow.askCounts[0] == 1 && c.caption.isEmpty && c.dictated.isEmpty)
}
@MainActor @Test func noListenerMeansQuietMode() async {
    let c = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)))
    c.submitter = Submitter(transport: FakeTransport(results: []))
    #expect(!c.speechAvailable && c.inputMode == .typing)
    c.start(); c.dictate(); #expect(!c.isListening && c.dictated.isEmpty)
    c.reset(); #expect(c.inputMode == .typing)
}
@MainActor @Test func cantProceedIsNotIdle() async throws {
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false), seed: 1,
                                timings: .test.with(idle: .milliseconds(40), idleGrace: .milliseconds(40)))
    c.inputMode = .typing; c.start()
    for n in 1...3 { c.submitTyped("pass"); await eventually { c.flow.askCounts[0] == n + 1 || c.flow.phase == .cantProceed(0) } }
    await eventually { c.flow.phase == .cantProceed(0) }
    try await Task.sleep(for: .milliseconds(150))
    #expect(!c.isAskingStillThere && c.flow.phase == .cantProceed(0))
}
@MainActor @Test func isDigestingSpansTheDigestOnly() async {
    let (c, _) = makeController([], model: FakeAnswerModel(delay: .milliseconds(150))); c.inputMode = .typing; c.start()
    #expect(!c.isDigesting)
    c.submitTyped("Jane Demo"); #expect(c.isDigesting)
    await eventually { c.flow.phase == .asking(1) }
    #expect(!c.isDigesting && c.messages.last?.role == .kiosk)
    c.submitTyped("DEMO001"); #expect(c.isDigesting)
    c.reset(); #expect(!c.isDigesting)
    try? await Task.sleep(for: .milliseconds(250)); #expect(!c.isDigesting && c.messages.isEmpty)
}
@MainActor @Test func rephraseStopsAtAskLimit() async {
    let (c, _) = makeController([], model: FakeAnswerModel(extracted: [0: "Jane Demo", 1: "DEMO001", 2: "1980-05-01"])); c.inputMode = .typing
    #expect(!c.canRephrase)
    c.start(); c.rephrase(); c.rephrase(); #expect(c.flow.askCounts[0] == 3 && !c.canRephrase)
    let count = c.messages.count; c.rephrase()
    #expect(c.flow.askCounts[0] == 3 && c.messages.count == count)
    c.submitTyped("Jane Demo, DEMO001, 1 May 1980"); #expect(!c.canRephrase)   // digesting
    await eventually { c.flow.phase == .asking(3) }
    #expect(c.canRephrase); c.rephrase(); #expect(c.flow.askCounts[3] == 2 && !c.canRephrase)
    let optionalCount = c.messages.count; c.rephrase()
    #expect(c.flow.askCounts[3] == 2 && c.messages.count == optionalCount)
}
@MainActor @Test func passToIDEndsInCantProceedEvenWhenModelExtractsIt() async {
    let t = FakeTransport(results: [.success(.ok)])
    let (c, _) = makeController([], model: FakeAnswerModel(byReply: ["Jane": [0: "Jane"], "Pass": [1: "PASS"]]), transport: t, seed: 1)
    c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.phase == .asking(1) }
    for n in 1...3 { c.submitTyped("Pass"); await eventually { c.flow.askCounts[1] == n + 1 || c.flow.phase == .cantProceed(1) } }
    #expect(c.flow.phase == .cantProceed(1) && c.flow.answers[1] == "")
    #expect(await t.requests.isEmpty)
}
