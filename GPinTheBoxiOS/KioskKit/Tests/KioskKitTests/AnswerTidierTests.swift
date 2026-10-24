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
    #expect(await t.extract(reply: "x", unanswered: Array(KioskQuestions.all.dropFirst(4))) == [:])
}
@Test func extractPassesThroughAndResetReenables() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [5: "Cough"]))
    #expect(await t.extract(reply: "I've had a cough", unanswered: Array(KioskQuestions.all.dropFirst(4))) == [5: "Cough"])
    await t.reset(); #expect(await t.extractionEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelTidiesSyntheticJane() async throws {
    let m = FoundationModelsAnswerModel()
    let found = try await m.extract(reply: "I'm Jane Demo, I've had a cough since Monday", unanswered: KioskQuestions.all)
    #expect(found.keys.contains(0) && found.keys.contains(3), "got \(found)")
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
    #expect(await t.extract(reply: "x", unanswered: Array(KioskQuestions.all.dropFirst())) == [1: "DEMO001", 9: "Cough"])
}
@Test func extractNormalisesDOBAndDropsInvalidOrUnaskedKeys() async {
    let remaining = Array(KioskQuestions.all.dropFirst())
    #expect(await AnswerTidier(model: FakeAnswerModel(extracted: [2: "1/5/1980"])).extract(reply: "x", unanswered: remaining) == [2: "1980-05-01"])
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 1: " - ", 2: "2999-01-01", 7: " Penicillin ", 12: "x"]))
    #expect(await t.extract(reply: "x", unanswered: remaining) == [7: "Penicillin"])
}
@Test func extractDropsQuestionTextAndQuestions() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [4: "When did it start?", 5: "describe your symptoms", 9: "Cough?", 8: " Full name. "]))
    #expect(await t.extract(reply: "x", unanswered: Array(KioskQuestions.all.dropFirst(4))) == [:])
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
