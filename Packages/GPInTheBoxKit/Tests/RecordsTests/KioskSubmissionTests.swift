import Testing
import Foundation
import SwiftData
import KioskProtocol
@testable import Records

func kioskAnswers(id: String = "demo 001", dob: String = "1980-05-01", name: String = " Jane Demo ") -> [KioskAnswer] {
    KioskQuestions.all.map { q in
        switch q.kind {
        case .fullName: KioskAnswer(q: q.text, a: name)
        case .identifier: KioskAnswer(q: q.text, a: id)
        case .dateOfBirth: KioskAnswer(q: q.text, a: dob)
        case .freeText: KioskAnswer(q: q.text, a: q.id == 3 ? "Cough" : "")
        }
    }
}
@Test func kioskSubmissionAlwaysCreatesNewPatient() async throws {
    let (store, q) = try await fixture()
    let web = try await store.recordSubmission(submission(q, medicare: "DEMO001"))
    let a = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    let b = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    #expect(a.isNewPatient && b.isNewPatient && !a.isReplay)
    #expect(Set([web.patientID, a.patientID, b.patientID]).count == 3)
    #expect(a.patientName == "Jane Demo")
}
@Test func kioskAnswersMapToDeterministicQuestionIDs() async throws {
    let (store, _) = try await fixture()
    let r = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    let visit = try #require(try await store.snapshot(patientID: r.patientID).visits.first)
    #expect(visit.answers.map(\.prompt) == KioskQuestions.all.map(\.text))
    #expect(visit.answers.map(\.questionID) == (0..<10).map(KioskQuestionID.forIndex))
    #expect(KioskQuestionID.forIndex(3).uuidString == "00000000-0000-0000-0000-000000000003")
}
@Test func kioskReplayAndConflict() async throws {
    let (store, _) = try await fixture(); let id = UUID()
    let a = try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers())
    let b = try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers(), receivedAt: .now.addingTimeInterval(60))
    #expect(b.isReplay && b.visitID == a.visitID && b.patientID == a.patientID)
    await #expect(throws: RecordError.submissionConflict) {
        try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers(name: "Changed"))
    }
    #expect(try await store.snapshot(patientID: a.patientID).visits.count == 1)
}
@Test(arguments: [kioskAnswers(name: " "), kioskAnswers(id: ""), kioskAnswers(dob: "2999-01-01"), kioskAnswers(dob: "1980-02-30"),
                  Array(kioskAnswers().dropFirst(3)), []])
func kioskInvalidIdentityInsertsNothing(answers: [KioskAnswer]) async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true); let store = RecordStore(modelContainer: container)
    await #expect(throws: RecordError.invalidIdentity) { try await store.recordKioskSubmission(submissionID: UUID(), answers: answers) }
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<Patient>()) == 0)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredSubmission>()) == 0)
}
@Test func kioskIdentityFoundByTextNotPosition() async throws {
    let (store, _) = try await fixture()
    let r = try await store.recordKioskSubmission(submissionID: UUID(), answers: Array(kioskAnswers().reversed()))
    let p = try await store.snapshot(patientID: r.patientID)
    #expect(p.fullName == "Jane Demo" && p.dateOfBirth == "1980-05-01")
}
