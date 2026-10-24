import Foundation
import FoundationModels

/// Immutable selected-patient JSON; never reads another patient's record or a live model context.
public final class PatientDatabaseTool: Tool {
    public let name = "patientDatabase"
    public let description = "Read the selected patient's profile or one consultation note from their database record. Use profile first to obtain consultation_count; note indices start at zero, newest first."
    private let profile: String
    private let notes: [String]

    @Generable public struct Arguments {
        @Guide(description: "Use -1 for patient profile, or a zero-based consultation note index (newest first).")
        public var noteIndex: Int
        public init(noteIndex: Int) { self.noteIndex = noteIndex }
    }

    public init(json: String) throws {
        guard var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["patient_id"] is String,
              let records = object.removeValue(forKey: "consultation_notes") as? [[String: Any]] else {
            throw PatientDatabaseToolError.invalidJSON
        }
        object["consultation_count"] = records.count
        profile = try Self.encode(object)
        notes = try records.map(Self.encode)
    }
    public func call(arguments: Arguments) async throws -> String {
        if arguments.noteIndex == -1 { return profile }
        guard notes.indices.contains(arguments.noteIndex) else { return "No consultation at this index. There are \(notes.count) consultation notes." }
        return notes[arguments.noteIndex]
    }
    private static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
public enum PatientDatabaseToolError: Error { case invalidJSON }
