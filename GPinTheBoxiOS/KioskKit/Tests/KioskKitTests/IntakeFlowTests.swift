import Testing
import Foundation
import KioskProtocol
@testable import KioskKit

func answeredFlow() -> IntakeFlow {
    var f = IntakeFlow(); f.start()
    f.answer("Jane Demo"); f.answer("DEMO001"); f.answer("1980-05-01")
    for _ in 3..<10 { f.skip() }
    return f
}
@Test func walksQuestionsToReview() {
    let f = answeredFlow()
    #expect(f.phase == .review && f.canSend)
    let r = f.request(submissionID: UUID())
    #expect(r.answers.map(\.q) == KioskQuestions.all.map(\.text))
    #expect(r.answers.map(\.a) == ["Jane Demo", "DEMO001", "1980-05-01"] + Array(repeating: "", count: 7))
}
@Test func requiredAnswerCannotBeEmpty() {
    var f = IntakeFlow(); f.start()
    #expect(!f.answer("  ") && !f.skip() && f.phase == .asking(0))
}
@Test func candidatesOnlyForLaterUnansweredQuestions() {
    var f = IntakeFlow(); f.start(); f.answer("Jane Demo")
    f.addCandidates([0: "Other", 1: "DEMO001", 4: "  ", 5: "Cough and fever"])
    #expect(f.candidates == [1: "DEMO001", 5: "Cough and fever"])
}
@Test func candidateConfirmAppendAndReplace() {
    var f = IntakeFlow(); f.start(); f.addCandidates([1: "DEMO001", 2: "1980-05-01", 3: "Cough"])
    f.answer("Jane Demo"); #expect(f.phase == .confirmingCandidate(1))
    f.confirmCandidate(); #expect(f.answers[1] == "DEMO001" && f.phase == .confirmingCandidate(2))
    f.answer("1981-06-02"); #expect(f.answers[2] == "1981-06-02")
    f.appendToCandidate("since Monday"); #expect(f.answers[3] == "Cough since Monday" && f.phase == .asking(4))
    #expect(IntakeFlow.readback("Cough") == "You mentioned Cough. Is that right, or would you like to add anything?")
}
@Test func canSendNeedsValidPastDOB() {
    var f = answeredFlow()
    f.edit(2, to: "2999-01-01"); #expect(!f.canSend)
    f.edit(2, to: "1 May 1980"); #expect(!f.canSend)
    f.edit(2, to: "1980-05-01"); f.edit(0, to: " "); #expect(!f.canSend)
}
@Test func sendingTransitions() {
    var f = answeredFlow()
    f.beginSending(); #expect(f.phase == .sending)
    f.sendFailed("Couldn't reach the clinic — ask reception"); f.beginSending(); f.sendSucceeded()
    #expect(f.phase == .done)
}
@Test func formatting() {
    #expect(AnswerFormatting.readableDOB("1980-05-01") == "1 May 1980")
    #expect(AnswerFormatting.readableDOB("garbage") == nil)
    #expect(AnswerFormatting.normaliseIdentifier(" demo-00 1/ ") == "DEMO001")
}
