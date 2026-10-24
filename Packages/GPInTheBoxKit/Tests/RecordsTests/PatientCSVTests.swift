import Foundation
import SwiftData
import Testing
@testable import Records

private func csv(_ columns: [String], _ rows: [[String: String]]) -> String {
    func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    return ([columns.map(quote).joined(separator: ",")] + rows.map { row in columns.map { quote(row[$0] ?? "") }.joined(separator: ",") }).joined(separator: "\r\n")
}
@Test func csvHandlesQuotedNewlinesBOMAndMalformedInput() throws {
    let rows = try PatientCSV.rows("\u{FEFF}id,text\r\n1,\"first, second\r\n\"\"quoted\"\"\"\r\n")
    #expect(rows == [["id": "1", "text": "first, second\n\"quoted\""]])
    for malformed in ["id,id\n1,2", "id,text\n1", "id,text\n1,\"unfinished", "id,text\n1,\"closed\"bad"] {
        #expect(throws: PatientImportError.self) { try PatientCSV.rows(malformed) }
    }
}
@Test @MainActor func csvImportLinksNotesUpdatesAndSerializesOnlySelectedPatient() async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let store = RecordStore(modelContainer: container)
    let patients = csv(DatabasePatient.columns, [
        ["patient_id": "P1", "first_name": "Jane", "last_name": "Smith", "medicare_number": "123456/1", "allergies": "Synthetic allergy"],
        ["patient_id": "P2", "first_name": "Other", "last_name": "Jones", "medicare_number": "999"]
    ])
    let notes = csv(DatabaseConsultationNote.columns, [
        ["note_id": "N1", "patient_id": "P1", "visit_date": "2025-01-01", "history": "First, with a comma\nand newline"],
        ["note_id": "N2", "patient_id": "P2", "history": "Other patient secret"]
    ])
    _ = try await store.importPatientCSVs([notes, patients])
    _ = try await store.importPatientCSVs([patients, notes])
    let context = ModelContext(container)
    let records = try context.fetch(FetchDescriptor<DatabasePatient>())
    #expect(records.count == 2)
    #expect(try context.fetchCount(FetchDescriptor<DatabaseConsultationNote>()) == 2)
    let jane = try #require(records.first { $0.patient_id == "P1" })
    #expect(jane.matches("jAnE") && jane.matches("SMITH") && jane.matches("123-456/1"))
    #expect(!jane.matches("Jones"))
    #expect(jane.consultationNotes.count == 1)
    let json = try jane.serializedJSON()
    #expect(!json.contains("Other patient secret"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["first_name"] as? String == "Jane")
    let linked = try #require(object["consultation_notes"] as? [[String: Any]])
    #expect(linked.first?["history"] as? String == "First, with a comma\nand newline")
    let changed = csv(DatabasePatient.columns, [["patient_id": "P1", "first_name": "Updated"]])
    _ = try await store.importPatientCSVs([changed])
    let fresh = ModelContext(container)
    #expect(try fresh.fetch(FetchDescriptor<DatabasePatient>()).first { $0.patient_id == "P1" }?.first_name == "Updated")
}
@Test func csvRejectsOrphansWithoutSavingPartialPatients() async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let store = RecordStore(modelContainer: container)
    let patient = csv(DatabasePatient.columns, [["patient_id": "P1"]])
    let orphan = csv(DatabaseConsultationNote.columns, [["note_id": "N1", "patient_id": "MISSING"]])
    await #expect(throws: PatientImportError.self) { try await store.importPatientCSVs([patient, orphan]) }
    let context = ModelContext(container)
    #expect(try context.fetchCount(FetchDescriptor<DatabasePatient>()) == 0)
}

// Opt-in verification against the user's files without committing their dataset to Git.
@Test func suppliedDemoCSVsRoundTrip() async throws {
    guard let directory = ProcessInfo.processInfo.environment["GP_DEMO_CSV_DIRECTORY"] else { return }
    let files = try ["sydney_gp_patients_demo_500.csv", "consultation_notes.csv"].map {
        try String(contentsOfFile: directory + "/" + $0, encoding: .utf8)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("csv.store")
    let container = try GPInTheBoxSchema.makeContainer(url: url)
    let store = RecordStore(modelContainer: container)
    let report = try await store.importPatientCSVs(files)
    #expect(report.patients == 500 && report.notes == 2461)
    _ = try await store.importPatientCSVs(files)
    let reopened = try GPInTheBoxSchema.makeContainer(url: url)
    let context = ModelContext(reopened)
    #expect(try context.fetchCount(FetchDescriptor<DatabasePatient>()) == 500)
    #expect(try context.fetchCount(FetchDescriptor<DatabaseConsultationNote>()) == 2461)
    let patients = try context.fetch(FetchDescriptor<DatabasePatient>())
    let sourcePatients = try PatientCSV.rows(files[0])
    let sourceNotes = try PatientCSV.rows(files[1])
    for patient in patients {
        let json = try JSONSerialization.jsonObject(with: Data(patient.serializedJSON().utf8)) as! [String: Any]
        let original = try #require(sourcePatients.first { $0["patient_id"] == patient.patient_id })
        for key in DatabasePatient.columns { #expect(json[key] as? String == original[key]) }
        let notes = try #require(json["consultation_notes"] as? [[String: String]])
        #expect(notes.count == sourceNotes.filter { $0["patient_id"] == patient.patient_id }.count)
        for note in notes { #expect(sourceNotes.contains(note)) }
    }
}
