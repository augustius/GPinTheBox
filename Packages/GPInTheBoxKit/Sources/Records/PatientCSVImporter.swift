import Foundation
import SwiftData

public struct PatientImportError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// RFC 4180-style parsing, including escaped quotes, embedded newlines and UTF-8 BOM.
public enum PatientCSV {
    public static func rows(_ text: String) throws -> [[String: String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var records: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, i = chars.first == "\u{FEFF}" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," {
                row.append(field); field = ""; closed = false
            } else if c == "\n" {
                row.append(field)
                if row != [""] { records.append(row) }
                row = []; field = ""; closed = false
            } else if c == "\"" && field.isEmpty && !closed {
                quoted = true
            } else {
                guard !closed && c != "\"" else { throw PatientImportError("Invalid CSV quoting near record \(records.count + 1).") }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw PatientImportError("CSV has an unclosed quoted field.") }
        if !row.isEmpty || !field.isEmpty || closed { row.append(field); records.append(row) }
        guard let header = records.first, Set(header).count == header.count, !header.contains("") else {
            throw PatientImportError("CSV needs a unique, non-empty header row.")
        }
        return try records.dropFirst().enumerated().map { index, values in
            guard values.count == header.count else { throw PatientImportError("CSV row \(index + 2) has \(values.count) columns; expected \(header.count).") }
            return Dictionary(uniqueKeysWithValues: zip(header, values))
        }
    }
}

public struct PatientImportResult: Sendable {
    public let patients: Int
    public let notes: Int
}

extension RecordStore {
    /// Import both files together. Validation precedes mutation and failures roll back the batch.
    public func importPatientCSVs(_ files: [String]) throws -> PatientImportResult {
        var patientRows: [[String: String]] = [], noteRows: [[String: String]] = []
        for file in files {
            let rows = try PatientCSV.rows(file)
            guard let first = rows.first else { throw PatientImportError("The selected CSV is empty.") }
            if Set(first.keys) == Set(DatabasePatient.columns) { patientRows += rows }
            else if Set(first.keys) == Set(DatabaseConsultationNote.columns) { noteRows += rows }
            else { throw PatientImportError("CSV columns do not match the patient or consultation-note format.") }
        }
        func validateIDs(_ rows: [[String: String]], key: String) throws {
            let ids = rows.map { $0[key] ?? "" }
            guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(ids).count == ids.count else {
                throw PatientImportError("Empty or duplicate \(key) in the import.")
            }
        }
        try validateIDs(patientRows, key: "patient_id")
        try validateIDs(noteRows, key: "note_id")
        var patients = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<DatabasePatient>()).map { ($0.patient_id, $0) })
        let knownIDs = Set(patients.keys).union(patientRows.compactMap { $0["patient_id"] })
        for row in noteRows {
            guard let id = row["patient_id"], knownIDs.contains(id) else {
                throw PatientImportError("Note \(row["note_id"] ?? "") refers to an unknown patient. Import the patient CSV with it.")
            }
        }
        let existingNotes = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<DatabaseConsultationNote>()).map { ($0.note_id, $0) })
        do {
            for row in patientRows {
                let id = row["patient_id"]!
                if let patient = patients[id] { patient.update(row: row) }
                else {
                    let patient = DatabasePatient(row: row)
                    modelContext.insert(patient); patients[id] = patient
                }
            }
            for row in noteRows {
                let note = existingNotes[row["note_id"]!] ?? DatabaseConsultationNote(row: row)
                if existingNotes[note.note_id] == nil { modelContext.insert(note) }
                note.update(row: row)
                note.patient = patients[row["patient_id"]!]
            }
            try modelContext.save()
        } catch { modelContext.rollback(); throw error }
        return PatientImportResult(patients: patientRows.count, notes: noteRows.count)
    }
}
