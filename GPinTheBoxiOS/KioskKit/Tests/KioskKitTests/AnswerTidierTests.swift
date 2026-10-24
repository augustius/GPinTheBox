import Testing
import KioskProtocol
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
func fallbackUsesRawTranscriptAndDisablesPrefill(model: FakeAnswerModel) async {
    let t = AnswerTidier(model: model, timeout: .milliseconds(50))
    #expect(await t.tidy(" um a cough ", for: KioskQuestions.all[3]) == "um a cough")
    #expect(await t.prefillEnabled == false)
    #expect(await t.prefill(transcript: "x", remaining: Array(KioskQuestions.all.dropFirst(4))) == [:])
}
@Test func prefillPassesThroughAndResetReenables() async {
    let t = AnswerTidier(model: FakeAnswerModel(prefill: [5: "Cough"]))
    #expect(await t.prefill(transcript: "I've had a cough", remaining: Array(KioskQuestions.all.dropFirst(4))) == [5: "Cough"])
    await t.reset(); #expect(await t.prefillEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelTidiesSyntheticJane() async throws {
    let m = FoundationModelsAnswerModel()
    #expect(try await m.tidy("um my name is Jane Demo", for: KioskQuestions.fullName).contains("Jane Demo"))
    #expect(try await m.tidy("the first of May nineteen eighty", for: KioskQuestions.dateOfBirth) == "1980-05-01")
}
@Test func callerCancellationKeepsPrefillEnabled() async {
    let t = AnswerTidier(model: FakeAnswerModel(delay: .seconds(1)))
    let task = Task { await t.tidy(" a cough ", for: KioskQuestions.all[3]) }
    try? await Task.sleep(for: .milliseconds(20))
    task.cancel()
    #expect(await task.value == "a cough")
    #expect(await t.prefillEnabled)
    await t.reset(); #expect(await t.prefillEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelDoesNotInventMissingDay() async throws {
    let result = try await FoundationModelsAnswerModel().tidy("May nineteen eighty", for: KioskQuestions.dateOfBirth)
    #expect(!KioskDate.isValidPastDOB(result), "invented a date: \(result)")
}
@Test func prefillValidatesCandidatesByKind() async {
    let t = AnswerTidier(model: FakeAnswerModel(prefill: [2: "Jane Demo", 1: "demo 001", 5: "  ", 9: "Cough"]))
    #expect(await t.prefill(transcript: "x", remaining: Array(KioskQuestions.all.dropFirst())) == [1: "DEMO001", 9: "Cough"])
}
@Test func prefillNormalisesDOBAndDropsInvalidOrUnaskedKeys() async {
    let remaining = Array(KioskQuestions.all.dropFirst())
    #expect(await AnswerTidier(model: FakeAnswerModel(prefill: [2: "1/5/1980"])).prefill(transcript: "x", remaining: remaining) == [2: "1980-05-01"])
    let t = AnswerTidier(model: FakeAnswerModel(prefill: [0: "Jane Demo", 1: " - ", 2: "2999-01-01", 7: " Penicillin ", 12: "x"]))
    #expect(await t.prefill(transcript: "x", remaining: remaining) == [7: "Penicillin"])
}
@Test func prefillDropsQuestionTextAndQuestions() async {
    let t = AnswerTidier(model: FakeAnswerModel(prefill: [4: "When did it start?", 5: "describe your symptoms", 9: "Cough?", 8: " Full name. "]))
    #expect(await t.prefill(transcript: "x", remaining: Array(KioskQuestions.all.dropFirst(4))) == [:])
}
