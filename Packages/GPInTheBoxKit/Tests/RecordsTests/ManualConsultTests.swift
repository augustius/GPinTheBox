import Testing
import Foundation
import SwiftData
@testable import Records

func dbPatient(id: String = "P10338", medicare: String = "5841685927/3", dob: String = "1943-08-10") -> DatabasePatient {
    DatabasePatient(row: ["patient_id": id, "first_name": "Aurora", "last_name": "Adams", "date_of_birth": dob, "medicare_number": medicare])
}
func manualContext() throws -> ModelContext { ModelContext(try GPInTheBoxSchema.makeContainer(inMemory: true)) }
let noon = ISO8601DateFormatter().date(from: "2026-10-25T02:00:00Z")!

@Test func createsPatientAndOpenVisit() throws {
    let c = try manualContext(); let db = dbPatient(); c.insert(db)
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.status == .inConsult && v.answers.isEmpty && v.databasePatientID == "P10338" && v.arrivedAt == noon)
    let p = try #require(v.patient)
    #expect(p.fullName == "Aurora Adams" && p.medicareID == "58416859273" && p.dateOfBirth == "1943-08-10")
}
@Test func reusesMatchingIntakePatient() throws {
    let c = try manualContext(); let existing = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10")
    c.insert(existing); let db = dbPatient(); c.insert(db); try c.save(); let before = existing.revision
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.patient?.id == existing.id && existing.revision != before)
    #expect(try c.fetchCount(FetchDescriptor<Patient>()) == 1)
}
@Test func differentDOBIsSeparatePatient() throws {
    let c = try manualContext(); c.insert(Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1950-01-01"))
    let db = dbPatient(); c.insert(db)
    _ = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(try c.fetchCount(FetchDescriptor<Patient>()) == 2)
}
@Test func reopensUnfinishedVisitToday() throws {
    let c = try manualContext(); let db = dbPatient(); c.insert(db)
    let p = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10"); c.insert(p)
    let intake = Visit(arrivedAt: noon.addingTimeInterval(-3600), answers: [Answer(questionID: UUID(), prompt: "Reason", value: "Cough")])
    c.insert(intake); p.visits.append(intake); try c.save()
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.id == intake.id && v.status == .inConsult && v.databasePatientID == nil)
    #expect(try c.fetchCount(FetchDescriptor<Visit>()) == 1)
    #expect(try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon).id == intake.id)
}
@Test func onlyUnfinishedVisitsTodayAreReused() throws {
    let c = try manualContext(); let db = dbPatient(); c.insert(db)
    let p = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10"); c.insert(p)
    let yesterday = Visit(arrivedAt: noon.addingTimeInterval(-86_400), answers: []); let doneToday = Visit(arrivedAt: noon.addingTimeInterval(-600), answers: [])
    doneToday.finish(); for v in [yesterday, doneToday] { c.insert(v); p.visits.append(v) }; try c.save()
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.id != yesterday.id && v.id != doneToday.id && v.databasePatientID == "P10338")
}
@Test func blocksMissingMedicareOrBadDOB() throws {
    #expect(dbPatient().consultBlockReason == nil)
    #expect(dbPatient(medicare: " / ").consultBlockReason == "No Medicare number on this record.")
    #expect(dbPatient(dob: "10/08/1943").consultBlockReason == "Date of birth isn't a valid date (yyyy-MM-dd).")
    let c = try manualContext(); let db = dbPatient(medicare: ""); c.insert(db)
    #expect(throws: RecordError.invalidIdentity) { try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon) }
    #expect(try c.fetchCount(FetchDescriptor<Visit>()) == 0 && c.fetchCount(FetchDescriptor<Patient>()) == 0)
}
@Test func intakeVisitPersistsWithNilDatabaseID() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("records.store")
    let (store, q) = try await fixture(url: url); let r = try await store.recordSubmission(submission(q))
    let reopened = ModelContext(try GPInTheBoxSchema.makeContainer(url: url))
    let id = r.visitID
    #expect(try reopened.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })).first?.databasePatientID == nil)
}
