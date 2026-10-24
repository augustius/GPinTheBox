import Testing
import Foundation
import SwiftData
@testable import Records

func fixture(url: URL? = nil) async throws -> (RecordStore, QuestionnaireSnapshot) {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: url == nil, url: url))
    try await store.seedDefaultQuestionnaireIfEmpty()
    return (store, try await store.questionnaire())
}
func submission(_ q: QuestionnaireSnapshot, id: UUID = UUID(), medicare: String = " ab 12-3/4 ", dob: String = "1980-05-01") -> IntakeSubmission {
    IntakeSubmission(submissionID: id, questionnaireID: q.id, fullName: "Synthetic Jane", medicareID: medicare, dateOfBirth: dob,
        answers: q.questions.map { Answer(questionID: $0.id, prompt: $0.prompt, value: $0.isRequired ? "Synthetic answer" : "") })
}
@Test func matchingNormalisesInsideStore() async throws {
    let (store, q) = try await fixture()
    let a = try await store.recordSubmission(submission(q))
    let b = try await store.recordSubmission(submission(q, medicare: "AB1234"))
    #expect(a.isNewPatient && !b.isNewPatient)
    #expect(a.patientID == b.patientID && a.visitID != b.visitID)
    #expect(try await store.snapshot(patientID: a.patientID).visits.count == 2)
}
@Test func differentDOBIsSeparatePatient() async throws {
    let (store, q) = try await fixture()
    let a = try await store.recordSubmission(submission(q))
    let b = try await store.recordSubmission(submission(q, dob: "1981-05-01"))
    #expect(a.patientID != b.patientID)
}
@Test func replayAndConflictAreAtomic() async throws {
    let (store, q) = try await fixture(); var s = submission(q)
    let a = try await store.recordSubmission(s)
    s.receivedAt = s.receivedAt.addingTimeInterval(60)
    let b = try await store.recordSubmission(s)
    #expect(b.isReplay && a.visitID == b.visitID)
    s.answers[0].value = "Changed"
    await #expect(throws: RecordError.self) { try await store.recordSubmission(s) }
    #expect(try await store.snapshot(patientID: a.patientID).visits.count == 1)
}
@Test func simultaneousRetriesCreateOneVisit() async throws {
    let (store, q) = try await fixture(); let s = submission(q)
    let receipts = try await withThrowingTaskGroup(of: SubmissionReceipt.self) { group in
        for _ in 0..<10 { group.addTask { try await store.recordSubmission(s) } }
        var values: [SubmissionReceipt] = []; for try await value in group { values.append(value) }; return values
    }
    #expect(Set(receipts.map(\.visitID)).count == 1)
    #expect(receipts.filter { !$0.isReplay }.count == 1)
}
@Test func oldQuestionnaireStillAccepted() async throws {
    let (store, q) = try await fixture()
    let new = try await store.publishQuestionnaire([.init(prompt: "New required question", kind: .shortText, isRequired: true)])
    #expect(try await store.questionnaire().id == new.id)
    let receipt = try await store.recordSubmission(submission(q))
    #expect(try await store.snapshot(patientID: receipt.patientID).visits[0].answers[0].prompt == q.questions[0].prompt)
    try await store.seedDefaultQuestionnaireIfEmpty()
    #expect(try await store.questionnaire().id == new.id)
}
@Test func identityCorrectionRejectsCollision() async throws {
    let (store, q) = try await fixture()
    let a = try await store.recordSubmission(submission(q))
    let b = try await store.recordSubmission(submission(q, medicare: "OTHER"))
    await #expect(throws: RecordError.self) {
        try await store.correctIdentity(patientID: b.patientID, fullName: "Changed", medicareID: "ab-1234", dateOfBirth: "1980-05-01")
    }
    #expect(try await store.snapshot(patientID: b.patientID).fullName == "Synthetic Jane")
    let old = try await store.snapshot(patientID: a.patientID).revision
    try await store.correctIdentity(patientID: a.patientID, fullName: "Corrected Jane", medicareID: "NEW", dateOfBirth: "1980-05-01")
    #expect(try await store.snapshot(patientID: a.patientID).revision != old)
    let matched = try await store.recordSubmission(submission(q, medicare: "new"))
    #expect(matched.patientID == a.patientID)
}
@Test func persistsReceiptsAndRecordsAcrossReopening() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("records.store")
    let (receipt, s): (SubmissionReceipt, IntakeSubmission) = try await {
        let (store, q) = try await fixture(url: url); let s = submission(q)
        return (try await store.recordSubmission(s), s)
    }()
    let (reopened, _) = try await fixture(url: url)
    #expect(try await reopened.snapshot(patientID: receipt.patientID).visits.count == 1)
    #expect(try await reopened.recordSubmission(s).isReplay)
}
@Test @MainActor func visitTransitionsAndSameDayFilter() throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let now = Date(), yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    let visit = Visit(arrivedAt: now, answers: [])
    #expect(visit.status == .waiting); visit.open(); #expect(visit.status == .inConsult)
    visit.finish(); visit.open(); #expect(visit.status == .done)
    container.mainContext.insert(visit); container.mainContext.insert(Visit(arrivedAt: yesterday, answers: []))
    try container.mainContext.save()
    #expect(try container.mainContext.fetchCount(FetchDescriptor<Visit>(predicate: Visit.arrivedOnSameDay(as: now, calendar: .current))) == 1)
}
@Test func rejectsInvalidDatesAndEmptyIDs() async throws {
    #expect(!IdentityValidation.validDOB("1980-02-31"))
    #expect(!IdentityValidation.validDOB("2999-01-01"))
    let (store, q) = try await fixture()
    await #expect(throws: RecordError.self) { try await store.recordSubmission(submission(q, medicare: " - / ")) }
}

@Test func changedInvalidPayloadStillConflictsWithExistingReceipt() async throws {
    let (store, q) = try await fixture(); var s = submission(q)
    _ = try await store.recordSubmission(s)
    s.fullName = ""
    await #expect(throws: RecordError.submissionConflict) { try await store.recordSubmission(s) }
}
@Test func snapshotOrdersVisitsAndPreservesOriginalName() async throws {
    let (store, q) = try await fixture()
    var later = submission(q); later.receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let receipt = try await store.recordSubmission(later)
    var earlier = submission(q); earlier.receivedAt = later.receivedAt.addingTimeInterval(-60); earlier.fullName = "Different spelling"
    _ = try await store.recordSubmission(earlier)
    let snapshot = try await store.snapshot(patientID: receipt.patientID)
    #expect(snapshot.fullName == "Synthetic Jane")
    #expect(snapshot.visits.map(\.arrivedAt) == [earlier.receivedAt, later.receivedAt])
}
@Test func invalidSubmissionDoesNotLeavePartialPatientOrReceipt() async throws {
    let (store, q) = try await fixture(); var s = submission(q)
    s.answers[0].prompt = "Tampered prompt"
    await #expect(throws: RecordError.invalidQuestionnaire) { try await store.recordSubmission(s) }
    s.answers[0].prompt = q.questions[0].prompt
    let receipt = try await store.recordSubmission(s)
    #expect(receipt.isNewPatient && !receipt.isReplay)
    #expect(try await store.snapshot(patientID: receipt.patientID).visits.count == 1)
}
@Test func publishingSnapshotDoesNotMutateEarlierVersion() async throws {
    let (store, old) = try await fixture()
    var edited = old.questions
    edited.reverse(); edited[0].prompt = "Edited prompt"
    let published = try await store.publishQuestionnaire(edited)
    #expect(try await store.questionnaire(id: old.id) == old)
    #expect(try await store.questionnaire() == published)
    await #expect(throws: RecordError.unknownQuestionnaire) { try await store.questionnaire(id: UUID()) }
}
@Test func publishingAfterClockRollbackStillSelectsNewVersion() async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let context = ModelContext(container)
    context.insert(QuestionnaireVersion(questions: GPInTheBoxSchema.defaultQuestions, createdAt: Date.now.addingTimeInterval(3600)))
    try context.save()
    let store = RecordStore(modelContainer: container)
    let published = try await store.publishQuestionnaire([.init(prompt: "Newest publication", kind: .shortText, isRequired: false)])
    #expect(try await store.questionnaire().id == published.id)
}

@Test @MainActor func mainContextIdentityCorrectionUsesSameCollisionRules() throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true), context = container.mainContext
    let a = Patient(fullName: "A", medicareID: "ONE", dateOfBirth: "1980-05-01")
    let b = Patient(fullName: "B", medicareID: "TWO", dateOfBirth: "1980-05-01")
    context.insert(a); context.insert(b); try context.save()
    #expect(throws: RecordError.identityCollision) {
        try RecordMutations.correctIdentity(context: context, patientID: b.id, fullName: "Changed", medicareID: "o-n-e", dateOfBirth: a.dateOfBirth)
    }
    #expect(b.fullName == "B" && b.medicareID == "TWO")
    try RecordMutations.correctIdentity(context: context, patientID: b.id, fullName: " Corrected ", medicareID: "t-h-r-e-e", dateOfBirth: b.dateOfBirth)
    #expect(b.fullName == "Corrected" && b.medicareID == "THREE")
}
@Test func submissionPersistsBothRelationshipDirections() async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let store = RecordStore(modelContainer: container)
    try await store.seedDefaultQuestionnaireIfEmpty()
    let q = try await store.questionnaire()
    let first = try await store.recordSubmission(submission(q))
    let second = try await store.recordSubmission(submission(q))
    let context = ModelContext(container)
    let visits = try context.fetch(FetchDescriptor<Visit>())
    #expect(visits.count == 2 && visits.allSatisfy { $0.patient?.id == first.patientID })
    let snapshot = try await store.snapshot(patientID: first.patientID)
    #expect(Set(snapshot.visits.map(\.id)) == Set([first.visitID, second.visitID]))
}

@Test func historyLookupExcludesCurrentFutureAndOtherPatients() async throws {
    let (store, q) = try await fixture()
    var first = submission(q)
    first.receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
    first.answers[0].value = "Previous symptoms"
    let original = try await store.recordSubmission(first)
    #expect(try await store.history(patientID: original.patientID, beforeVisitID: original.visitID).visits.isEmpty)
    var current = submission(q, medicare: "AB1234")
    current.receivedAt = first.receivedAt.addingTimeInterval(60)
    let returning = try await store.recordSubmission(current)
    var future = submission(q)
    future.receivedAt = current.receivedAt.addingTimeInterval(60)
    _ = try await store.recordSubmission(future)
    let unrelated = try await store.recordSubmission(submission(q, medicare: "OTHER"))
    let history = try await store.history(patientID: returning.patientID, beforeVisitID: returning.visitID)
    #expect(history.visits.map(\.id) == [original.visitID])
    #expect(history.visits.first?.answers.first?.value == "Previous symptoms")
    await #expect(throws: RecordError.missingVisit) {
        try await store.history(patientID: returning.patientID, beforeVisitID: unrelated.visitID)
    }
}
