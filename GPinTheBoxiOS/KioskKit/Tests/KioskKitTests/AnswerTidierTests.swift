import Testing
@testable import KioskKit

@Test func tidyUsesModelAndNormalisesID() async {
    let t = AnswerTidier(model: FakeAnswerModel(tidied: ["D E M O zero zero one": "demo 001"]))
    #expect(await t.tidy("D E M O zero zero one", for: KioskQuestions.identifier) == "DEMO001")
}
@Test func invalidModelDateFallsBackToTranscript() async {
    let t = AnswerTidier(model: FakeAnswerModel(tidied: ["first of may eighty": "1980-13-01"]))
    #expect(await t.tidy("first of may eighty", for: KioskQuestions.dateOfBirth) == "first of may eighty")
}
@Test(arguments: [FakeAnswerModel(isAvailable: false), FakeAnswerModel(error: FakeError()), FakeAnswerModel(delay: .seconds(1))])
func fallbackUsesRawTranscriptAndDisablesExtraction(model: FakeAnswerModel) async {
    let t = AnswerTidier(model: model, timeout: .milliseconds(50))
    #expect(await t.tidy(" um a cough ", for: KioskQuestions.all[3]) == "um a cough")
    #expect(await t.extractionEnabled == false)
    #expect(await t.extract(reply: "x", target: KioskQuestions.all[4], unanswered: Array(KioskQuestions.all.dropFirst(4))) == [:])
}
@Test func extractPassesThroughAndResetReenables() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [5: "Cough"]))
    #expect(await t.extract(reply: "I've had a cough", target: KioskQuestions.all[4], unanswered: Array(KioskQuestions.all.dropFirst(4))) == [5: "Cough"])
    await t.reset(); #expect(await t.extractionEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelTidiesSyntheticJane() async throws {
    let m = FoundationModelsAnswerModel()
    let found = try await m.extract(reply: "I'm Jane Demo, I've had a cough since Monday", target: KioskQuestions.fullName, unanswered: KioskQuestions.all)
    #expect(found[0]?.contains("Jane Demo") == true && Set(found.keys).isSubset(of: [0, 3, 4, 5]), "got \(found)")
    #expect(found.filter { $0.key != 0 }.values.allSatisfy { !$0.contains("Jane") }, "got \(found)")
    #expect(try await m.tidy("um my name is Jane Demo", for: KioskQuestions.fullName).contains("Jane Demo"))
    #expect(try await m.tidy("the first of May nineteen eighty", for: KioskQuestions.dateOfBirth) == "1980-05-01")
}
@Test func callerCancellationKeepsExtractionEnabled() async {
    let t = AnswerTidier(model: FakeAnswerModel(delay: .seconds(1)))
    let task = Task { await t.tidy(" a cough ", for: KioskQuestions.all[3]) }
    try? await Task.sleep(for: .milliseconds(20))
    task.cancel()
    #expect(await task.value == "a cough")
    #expect(await t.extractionEnabled)
    await t.reset(); #expect(await t.extractionEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelDoesNotInventMissingDay() async throws {
    let result = try await FoundationModelsAnswerModel().tidy("May nineteen eighty", for: KioskQuestions.dateOfBirth)
    #expect(!KioskDate.isValidPastDOB(result), "invented a date: \(result)")
}
@Test func extractValidatesCandidatesByKind() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [2: "Jane Demo", 1: "demo 001", 5: "  ", 9: "Cough"]))
    #expect(await t.extract(reply: "x", target: KioskQuestions.identifier, unanswered: Array(KioskQuestions.all.dropFirst())) == [1: "DEMO001", 9: "Cough"])
}
@Test func extractNormalisesDOBAndDropsInvalidOrUnaskedKeys() async {
    let remaining = Array(KioskQuestions.all.dropFirst())
    #expect(await AnswerTidier(model: FakeAnswerModel(extracted: [2: "1/5/1980"])).extract(reply: "x", target: KioskQuestions.identifier, unanswered: remaining) == [2: "1980-05-01"])
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 1: " - ", 2: "2999-01-01", 7: " Penicillin ", 12: "x"]))
    #expect(await t.extract(reply: "x", target: KioskQuestions.identifier, unanswered: remaining) == [7: "Penicillin"])
}
@Test func extractDropsQuestionTextAndQuestions() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [4: "When did it start?", 5: "describe your symptoms", 9: "Cough?", 8: " Full name. "]))
    #expect(await t.extract(reply: "x", target: KioskQuestions.all[4], unanswered: Array(KioskQuestions.all.dropFirst(4))) == [:])
}

let q = KioskQuestions.all
@Test func digestUsesExtractionAcrossQuestions() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"]))
    let d = await t.digest(reply: "I'm Jane Demo, cough since Monday", target: q[0], unanswered: q)
    #expect(d == ReplyDigest(values: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"], skippedTarget: false))
}
@Test func extractionWithoutTargetDoesNotFillTarget() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [3: "Cough"]))
    let d = await t.digest(reply: "I've got a cough", target: q[0], unanswered: q)
    #expect(d.values == [3: "Cough"])
}
@Test func fallbackFillsTargetOnlyWhenNothingExtracted() async {
    let t = AnswerTidier(model: FakeAnswerModel(isAvailable: false))
    #expect(await t.digest(reply: " a dry cough ", target: q[3], unanswered: q).values == [3: "a dry cough"])
    #expect(await t.digest(reply: "1/5/1980", target: q[2], unanswered: q).values == [2: "1980-05-01"])
    #expect(await t.digest(reply: "around May", target: q[2], unanswered: q).values == [:])
    #expect(await t.digest(reply: "- / -", target: q[1], unanswered: q).values == [:])
}
@Test func skipWordsOnlySkipOptionalTargets() async {
    let t = AnswerTidier(model: FakeAnswerModel())
    #expect(await t.digest(reply: "Nope.", target: q[7], unanswered: q) == ReplyDigest(values: [:], skippedTarget: true))
    #expect(await t.digest(reply: "pass", target: q[1], unanswered: q) == ReplyDigest(values: [:], skippedTarget: false))
    #expect(AnswerTidier.isSkip("I'd rather not say!") && !AnswerTidier.isSkip("none, but I'm on aspirin"))
    #expect(AnswerTidier.isSkip("I\u{2019}d rather not say"))
}
@Test func skipWordToRequiredTargetIsNeverExtracted() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [1: "PASS", 5: "Pass"]))
    #expect(await t.digest(reply: "Pass", target: q[1], unanswered: q) == ReplyDigest(values: [:], skippedTarget: false))
    #expect(AnswerTidier.isSkip("No\u{2026}") && AnswerTidier.isSkip("nope..."))
}
@Test func extractDedupesWithinReplyKeepingTargetOrLowest() async {
    let jane = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Jane Demo", 9: " jane demo. "]))
    #expect(await jane.extract(reply: "Jane Demo", target: q[0], unanswered: q) == [0: "Jane Demo"])
    #expect(await jane.extract(reply: "Jane Demo", target: q[9], unanswered: q) == [9: "jane demo."])
    let cough = AnswerTidier(model: FakeAnswerModel(extracted: [5: "cough", 3: "Cough"]))
    #expect(await cough.extract(reply: "cough", target: q[1], unanswered: q) == [3: "Cough"])
}
@Test func extractDropsValuesAlreadyRecorded() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [9: "Jane Demo", 7: "Penicillin"]))
    let rest = Array(q.dropFirst())
    #expect(await t.extract(reply: "x", target: q[9], unanswered: rest, answers: [0: "Jane Demo"]) == [7: "Penicillin"])
    let other = AnswerTidier(model: FakeAnswerModel(extracted: [9: "Jane Demo"]))
    #expect(await other.digest(reply: "Jane Demo", target: q[9], unanswered: rest, answers: [0: "Jane Demo"]).values == [:])
}
@Test func extractGatesImplausibleValuesForOtherQuestions() async {
    let bad = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Agent 47", 1: "ABC", 4: "a bad cough"]))
    #expect(await bad.extract(reply: "x", target: q[3], unanswered: q) == [:])
    let long = AnswerTidier(model: FakeAnswerModel(extracted: [0: "I have had a really bad cough"]))
    #expect(await long.extract(reply: "x", target: q[3], unanswered: q) == [:])
    let good = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 1: "demo 001", 4: "since Monday", 9: "x"]))
    #expect(await good.extract(reply: "x", target: q[3], unanswered: q) == [0: "Jane Demo", 1: "DEMO001", 4: "since Monday", 9: "x"])
    #expect(await AnswerTidier(model: FakeAnswerModel(extracted: [4: "3 days"])).extract(reply: "x", target: q[3], unanswered: q) == [4: "3 days"])
    #expect(await AnswerTidier(model: FakeAnswerModel(extracted: [4: "a while back"])).extract(reply: "x", target: q[4], unanswered: q) == [4: "a while back"])
}
@Test func fallbackIgnoresQuestionsBack() async {
    for model in [FakeAnswerModel(isAvailable: false), FakeAnswerModel()] {
        #expect(await AnswerTidier(model: model).digest(reply: "Why do you need it?", target: q[0], unanswered: q).values == [:])
        #expect(await AnswerTidier(model: model).digest(reply: "Is that for the cough?", target: q[3], unanswered: q).values == [:])
    }
}
@Test func idsNeedADigit() async {
    let off = AnswerTidier(model: FakeAnswerModel(isAvailable: false))
    #expect(await off.digest(reply: "it's at home", target: q[1], unanswered: q).values == [:])
    #expect(await off.digest(reply: "demo 001", target: q[1], unanswered: q).values == [1: "DEMO001"])
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [1: "my card"]))
    #expect(await t.digest(reply: "my card", target: q[1], unanswered: q).values == [:])
}
@Test func nonAnswersToRequiredQuestionsRecordNothing() async {
    let replies = ["nah", "No thanks.", "don't know", "I don\u{2019}t know", "Not sure...", "dunno", "I don't have one", "I don't have it", "I don't have my card"]
    for reply in replies {
        let t = AnswerTidier(model: FakeAnswerModel(extracted: [0: reply, 1: reply, 2: reply, 9: reply]))
        for target in q.prefix(3) { #expect(await t.digest(reply: reply, target: target, unanswered: q) == ReplyDigest(values: [:], skippedTarget: false), "\(reply)") }
    }
    let optional = AnswerTidier(model: FakeAnswerModel(isAvailable: false))
    #expect(await optional.digest(reply: "not sure", target: q[7], unanswered: q).values == [7: "not sure"])
}
@Test func replyMappedOnlyToAnsweredQuestionsFillsNothing() async {
    let t = AnswerTidier(model: FakeAnswerModel(byReply: ["Actually it's spelt Jon": [0: "Jon"]]))
    let answers = [0: "Jane Demo", 1: "DEMO001", 2: "1980-05-01"]
    let d = await t.digest(reply: "Actually it's spelt Jon", target: q[3], unanswered: Array(q.dropFirst(3)), answers: answers)
    #expect(d == ReplyDigest(values: [:], skippedTarget: false))
}
@Test func spellingCorrectionsFillNothingButNamesMaySpellThemselves() async {
    let t = AnswerTidier(model: FakeAnswerModel(byReply: ["Actually it's spelt Jon": [3: "Actually it's spelt Jon"], "Jon, spelled J O N": [0: "Jon"]]))
    let rest = Array(q.dropFirst(3)), answers = [0: "Jane Demo", 1: "DEMO001", 2: "1980-05-01"]
    #expect(await t.digest(reply: "Actually it's spelt Jon", target: q[3], unanswered: rest, answers: answers).values == [:])
    #expect(await t.digest(reply: "I meant Jon", target: q[1], unanswered: Array(q.dropFirst()), answers: [0: "Jane"]).values == [:])
    #expect(await t.digest(reply: "Jon, spelled J O N", target: q[0], unanswered: q).values == [0: "Jon"])
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable), arguments: [("Why do you need it?", 0), ("nah", 0), ("I don't have my card", 1), ("Pass", 1), ("Do you mean the cough?", 2)])
func realModelNonAnswersFillNothing(reply: String, target: Int) async {
    let answers = Dictionary(uniqueKeysWithValues: [(0, "Jane Demo"), (1, "DEMO001")].filter { $0.0 < target })
    let d = await AnswerTidier(model: FoundationModelsAnswerModel()).digest(reply: reply, target: q[target], unanswered: q.filter { answers[$0.id] == nil }, answers: answers)
    #expect(d.values.isEmpty, "\(d.values)")
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelCorrectionFillsNothing() async {
    let answers = [0: "Jane Demo", 1: "DEMO001", 2: "1980-05-01"]
    let d = await AnswerTidier(model: FoundationModelsAnswerModel()).digest(reply: "Actually it's spelt Jon", target: q[3], unanswered: Array(q.dropFirst(3)), answers: answers)
    #expect(d.values.isEmpty, "\(d.values)")
}
@Test func extractionTimeoutFallsBackWithoutASecondWait() async {
    let t = AnswerTidier(model: FakeAnswerModel(delay: .seconds(2)), timeout: .milliseconds(200))
    let start = ContinuousClock.now
    let d = await t.digest(reply: " a dry cough ", target: q[3], unanswered: q)
    #expect(d.values == [3: "a dry cough"])
    #expect(ContinuousClock.now - start < .milliseconds(350), "took \(ContinuousClock.now - start)")
}
struct ShortReply: Sendable, CustomTestStringConvertible {
    let reply: String, target: Int, allowed: Set<Int>, exact: Bool
    var testDescription: String { "\(reply) → q\(target)" }
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable), arguments: [
    ShortReply(reply: "Jane Demo", target: 0, allowed: [0], exact: true), ShortReply(reply: "DEMO001", target: 1, allowed: [1], exact: false),
    ShortReply(reply: "1 May 1980", target: 2, allowed: [2], exact: false),
    ShortReply(reply: "I've had a cough since Monday", target: 0, allowed: [3, 4, 5], exact: false),
])
func realModelMapsShortRepliesToTheQuestionAsked(_ c: ShortReply) async throws {
    let answers = Dictionary(uniqueKeysWithValues: [(0, "Jane Demo"), (1, "DEMO001")].filter { $0.0 < c.target })
    let unanswered = q.filter { answers[$0.id] == nil }
    let raw = try await FoundationModelsAnswerModel().extract(reply: c.reply, target: q[c.target], unanswered: unanswered)
    let d = await AnswerTidier(model: FoundationModelsAnswerModel()).digest(reply: c.reply, target: q[c.target], unanswered: unanswered, answers: answers)
    let keys = Set(d.values.keys)
    #expect(c.exact ? keys == c.allowed : keys.isSubset(of: c.allowed) && !keys.isEmpty, "digest \(d.values), model \(raw)")
}
