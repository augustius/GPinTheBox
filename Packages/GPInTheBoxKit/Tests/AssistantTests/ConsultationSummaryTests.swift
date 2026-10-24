import Foundation
import Testing
import Records
@testable import Assistant

@Test func consultationDraftRequiresTranscriptAndAvailableModel() async {
    await #expect(throws: AssistantError.self) {
        try await ConsultationSummarizer(model: FakeModel()).summarize(transcript: " \n ", consultationID: UUID(), date: .now)
    }
    await #expect(throws: AssistantError.unavailable("off")) {
        try await ConsultationSummarizer(model: FakeModel(status: .unavailable(reason: "off"))).summarize(transcript: "Cough is better.", consultationID: UUID(), date: .now)
    }
}
@Test func consultationDraftPreservesUnverifiedProvenanceAndDoesNotInferSpeakers() async throws {
    let base = FakeModel(), id = UUID()
    var model = FakeModel()
    model.handler = { instructions, prompt in
        #expect(instructions.contains("Do not infer who spoke"))
        #expect(instructions.contains("unverified combined conversation"))
        #expect(instructions.contains("never make a new diagnosis"))
        #expect(prompt.contains("Consultation transcript (unverified)"))
        return try await base.respond(instructions: instructions, prompt: prompt)
    }
    let result = try await ConsultationSummarizer(model: model).summarize(transcript: "Cough has improved. No fever.", consultationID: id, date: .now)
    #expect(result.citedChunks.first?.id == "T-\(id.uuidString)")
    #expect(result.citedChunks.allSatisfy { $0.source == .consultationTranscript })
    #expect(result.claims[0].quotes[0] == "Cough has improved. No fever.")
}
@Test func consultationDraftRejectsFabricatedEvidence() async {
    var model = FakeModel()
    model.handler = { _, _ in ModelAnswer(claims: [.init(text: "Patient takes aspirin", chunkIDs: ["T-invented"], quotes: ["aspirin"])]) }
    await #expect(throws: AssistantError.unsupportedEvidence) {
        try await ConsultationSummarizer(model: model).summarize(transcript: "No regular medications.", consultationID: UUID(), date: .now)
    }
}
@Test func consultationLongTranscriptIsBoundedAndRetainsOriginalQuotes() async throws {
    let counter = Counter(), base = FakeModel(), id = UUID()
    var model = FakeModel()
    model.handler = { instructions, prompt in
        await counter.increment()
        #expect(prompt.utf8.count <= 800)
        return try await base.respond(instructions: instructions, prompt: prompt)
    }
    let transcript = String(repeating: "The cough has improved. No fever. ", count: 120)
    let result = try await ConsultationSummarizer(model: model, budgetBytes: 800).summarize(transcript: transcript, consultationID: id, date: .now)
    #expect(await counter.value > 1)
    #expect(!result.claims.isEmpty)
    #expect(result.citedChunks.allSatisfy { $0.id.hasPrefix("T-\(id.uuidString)") && $0.source == .consultationTranscript })
    #expect(result.claims.allSatisfy { claim in zip(claim.sources, claim.quotes).allSatisfy { $0.text.contains($1) } })
}
@Test func consultationOverflowRetriesStopAfterThreeRetries() async {
    let counter = Counter()
    var model = FakeModel()
    model.handler = { _, _ in await counter.increment(); throw AssistantError.contextOverflow }
    await #expect(throws: AssistantError.contextOverflow) {
        try await ConsultationSummarizer(model: model).summarize(transcript: "Cough is better.", consultationID: UUID(), date: .now)
    }
    #expect(await counter.value == 4)
}
@Test func consultationCancellationAfterModelResultDoesNotReturnDraft() async {
    var model = FakeModel()
    model.handler = { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return ModelAnswer(claims: [])
    }
    let fake = model
    let task = Task { try await ConsultationSummarizer(model: fake).summarize(transcript: "Cough.", consultationID: UUID(), date: .now) }
    do { _ = try await task.value; Issue.record("Cancelled result returned") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
@Test func approvedConsultationSummariesEnterRecordWithDistinctProvenance() async throws {
    let summaryID = UUID(), date = Date(timeIntervalSince1970: 1000)
    let visit = VisitSnapshot(answers: [], consultationSummaries: [.init(id: summaryID, text: "Discussed intermittent cough. Review cough next visit.", approvedAt: date)])
    let record = PatientSnapshot(fullName: "Demo", dateOfBirth: "1980-01-01", visits: [visit])
    let chunks = RecordChunker.chunks(for: record)
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.source == .gpReviewedSummary && $0.date == date })
    #expect(chunks[0].id == "V1-C\(summaryID.uuidString)-S1")
    #expect(!chunks.contains { $0.source == .consultationTranscript })
    let answer = try await QAService(model: FakeModel()).answer("What was discussed about cough?", patient: record)
    #expect(answer.citedChunks.first?.source == .gpReviewedSummary)
}
@Test func approvedConsultationFollowUpsAreAvailableAtNextVisit() async throws {
    let summaryID = UUID()
    let first = VisitSnapshot(answers: [], consultationSummaries: [.init(id: summaryID, text: "Review cough next visit.", approvedAt: .now)])
    let second = VisitSnapshot(answers: [.init(questionID: UUID(), prompt: "Reason", value: "Cough is better.")])
    let record = PatientSnapshot(fullName: "Demo", dateOfBirth: "1980-01-01", visits: [first, second])
    let model = FakeModel(followUps: [.init(item: "Review cough", sourceSentence: "Review cough next visit.")], judgement: .init(mentioned: true, chunkIDs: ["V2-A1"]))
    let summary = try await Summarizer(model: model).summarize(record, visitID: second.id)
    #expect(summary.followUps.count == 1)
    #expect(summary.followUps[0].noteSource.source == .gpReviewedSummary)
    guard case .mentioned = summary.followUps[0].status else { Issue.record("Expected current intake mention"); return }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GPINTHEBOX_TEST_CONSULTATION_MODEL"] == "1"))
func consultationOnDeviceDraftUsesTranscriptEvidence() async throws {
    let model = FoundationModelsAssistant()
    guard model.availability() == .available else { Issue.record("On-device model unavailable for explicitly requested integration test"); return }
    let transcript = """
    Doctor: How has your cough been since the last visit?
    Patient: The cough is much better. I have no fever. I have not checked my blood pressure.
    Doctor: We will review your cough and blood pressure at the next appointment.
    """
    let draft = try await ConsultationSummarizer(model: model).summarize(transcript: transcript, consultationID: UUID(), date: .now)
    #expect(!draft.claims.isEmpty)
    #expect(draft.citedChunks.allSatisfy { $0.source == .consultationTranscript })
    #expect(draft.claims.allSatisfy { zip($0.sources, $0.quotes).allSatisfy { $0.text.contains($1) } })
}
