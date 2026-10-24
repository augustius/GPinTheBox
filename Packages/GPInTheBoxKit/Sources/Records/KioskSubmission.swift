import Foundation
import SwiftData
import KioskProtocol

public enum KioskQuestionID {
    /// Deterministic question ID for a kiosk question index: 00000000-0000-0000-0000-<index, 12 digits>.
    public static func forIndex(_ index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", index))!
    }
}

extension RecordStore {
    /// Records a voice-kiosk submission. Kiosk visits always create a new patient.
    public func recordKioskSubmission(submissionID: UUID, answers: [KioskAnswer], receivedAt: Date = .now) throws -> SubmissionReceipt {
        // Arrival time is server metadata, not part of the idempotency payload.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(KioskRequest(submissionID: submissionID, answers: answers))
        if let previous = try modelContext.fetch(FetchDescriptor<StoredSubmission>(predicate: #Predicate { $0.id == submissionID })).first {
            guard previous.payload == payload else { throw RecordError.submissionConflict }
            return SubmissionReceipt(patientID: previous.patientID, visitID: previous.visitID, patientName: previous.patientName, isNewPatient: previous.isNewPatient, isReplay: true)
        }
        func value(_ q: KioskQuestion) -> String { answers.first { $0.q == q.text }?.a ?? "" }
        let name = value(KioskQuestions.fullName).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MedicareID.normalise(value(KioskQuestions.identifier))
        let dob = value(KioskQuestions.dateOfBirth)
        guard !name.isEmpty, !key.isEmpty, IdentityValidation.validDOB(dob, now: receivedAt) else { throw RecordError.invalidIdentity }
        let patient = Patient(fullName: name, medicareID: key, dateOfBirth: dob)
        modelContext.insert(patient)
        let visit = Visit(arrivedAt: receivedAt, answers: answers.enumerated().map {
            Answer(questionID: KioskQuestionID.forIndex($0.offset), prompt: $0.element.q, value: $0.element.a)
        })
        modelContext.insert(visit)
        patient.visits.append(visit)
        patient.revision = UUID()
        let receipt = SubmissionReceipt(patientID: patient.id, visitID: visit.id, patientName: patient.fullName, isNewPatient: true)
        modelContext.insert(StoredSubmission(id: submissionID, payload: payload, receipt: receipt))
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
        return receipt
    }
}
