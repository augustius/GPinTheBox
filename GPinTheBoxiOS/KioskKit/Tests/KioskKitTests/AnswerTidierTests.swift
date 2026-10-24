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
