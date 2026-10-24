import Foundation
import Testing
@testable import Assistant

@Test func patientToolUsesInjectedJSONAndBoundsNoteAccess() async throws {
    let first = try PatientDatabaseTool(json: """
    {"patient_id":"P1","allergies":"Synthetic allergy","consultation_notes":[{"note_id":"N1","history":"Previous symptoms"}]}
    """)
    let second = try PatientDatabaseTool(json: """
    {"patient_id":"P2","consultation_notes":[]}
    """)
    let profile = try await first.call(arguments: .init(noteIndex: -1))
    #expect(profile.contains("P1") && profile.contains("consultation_count"))
    #expect(try await first.call(arguments: .init(noteIndex: 0)).contains("N1"))
    #expect(try await first.call(arguments: .init(noteIndex: 1)).contains("No consultation"))
    #expect(!(try await second.call(arguments: .init(noteIndex: -1))).contains("Synthetic allergy"))
    #expect(throws: (any Error).self) { try PatientDatabaseTool(json: "{}") }
}
