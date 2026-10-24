import Testing
import Foundation
@testable import KioskKit

func answeredFlow() -> IntakeFlow {
    var f = IntakeFlow(); f.start()
    f.record([0: "Jane Demo", 1: "DEMO001", 2: "1980-05-01"])
    for i in 3..<10 { f.markAnsweredEmpty(i) }
    f.advance()
    return f
}
@Test func walksQuestionsToReview() {
    let f = answeredFlow()
    #expect(f.phase == .review && f.canSend)
    let r = f.request(submissionID: UUID())
    #expect(r.answers.map(\.q) == KioskQuestions.all.map(\.text))
    #expect(r.answers.map(\.a) == ["Jane Demo", "DEMO001", "1980-05-01"] + Array(repeating: "", count: 7))
}
@Test func targetsRequiredFirstThenOptionalInOrder() {
    var f = IntakeFlow(); f.start(); #expect(f.phase == .asking(0))
    f.record([3: "Cough", 0: "Jane Demo"]); f.advance(); #expect(f.phase == .asking(1))
    f.record([1: "DEMO001", 2: "1/5/1980"]); f.advance(); #expect(f.phase == .asking(4))
    #expect(f.answers[2] == "1980-05-01" && f.answeredCount == 4)
}
@Test func recordNeverOverwritesAnswered() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane Demo"])
    #expect(f.record([0: "Jon", 3: "  "]) == [:]); #expect(f.answers[0] == "Jane Demo")
}
@Test func optionalAskedTwiceThenSkipped() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane", 1: "D1", 2: "1980-05-01"]); f.advance()
    #expect(f.phase == .asking(3)); f.noteAsked(); f.advance(); #expect(f.phase == .asking(3))
    f.noteAsked(); f.advance(); #expect(f.phase == .asking(4)); #expect(f.isAnsweredEmpty(3))
}
@Test func requiredUnansweredAfterThreeAsksCantProceed() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane"]); f.advance()
    for _ in 0..<2 { f.noteAsked(); f.advance(); #expect(f.phase == .asking(1)) }
    f.noteAsked(); f.advance(); #expect(f.phase == .cantProceed(1))
}
@Test func clearingRequiredResetsAskCount() {
    var f = IntakeFlow(); f.start(); f.noteAsked(); f.record([0: "Jane", 1: "D1"]); f.advance()
    f.edit(0, to: " "); #expect(!f.isAnswered(0) && f.askCounts[0] == 0)
    f.edit(3, to: ""); #expect(f.isAnsweredEmpty(3))
    f.advance(); #expect(f.phase == .asking(0))
}
@Test func answeredEmptySendsEmptyString() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane", 1: "D1", 2: "1980-05-01"])
    f.markAnsweredEmpty(7); f.markAnsweredEmpty(0)
    #expect(f.isAnsweredEmpty(7) && !f.isAnsweredEmpty(0))
    #expect(f.request(submissionID: UUID()).answers[7].a == "")
}
@Test func canSendNeedsValidPastDOB() {
    var f = answeredFlow()
    f.edit(2, to: "2999-01-01"); #expect(!f.canSend)
    f.edit(2, to: "May 1980"); #expect(!f.canSend)
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
@Test func typedDOBIsStoredAsISO() {
    var f = IntakeFlow(); f.start()
    f.record([0: "Jane Demo", 1: "DEMO001", 2: " 1/5/1980 "])
    for i in 3..<10 { f.markAnsweredEmpty(i) }
    f.advance()
    #expect(f.answers[2] == "1980-05-01" && f.canSend && f.phase == .review)
}
@Test func editedDOBNormalisesOrKeepsText() {
    var f = answeredFlow()
    f.edit(2, to: "1 May 1980"); #expect(f.answers[2] == "1980-05-01" && f.canSend)
    f.edit(2, to: " sometime in May "); #expect(f.answers[2] == "sometime in May" && !f.canSend)
    f.edit(0, to: "1/5/1980"); #expect(f.answers[0] == "1/5/1980")
}
