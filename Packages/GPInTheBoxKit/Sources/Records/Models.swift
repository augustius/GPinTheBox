import Foundation
import SwiftData

public enum VisitStatus: String, Codable, Sendable { case waiting, inConsult, done }
public enum QuestionKind: String, Codable, Sendable, CaseIterable { case shortText, longText }
public enum MedicareID {
    public static func normalise(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "/" }
    }
}
public struct Answer: Codable, Hashable, Sendable {
    public var questionID: UUID
    public var prompt: String
    public var value: String
    public init(questionID: UUID, prompt: String, value: String) { self.questionID = questionID; self.prompt = prompt; self.value = value }
}
public struct QuestionSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var prompt: String
    public var kind: QuestionKind
    public var isRequired: Bool
    public init(id: UUID = UUID(), prompt: String, kind: QuestionKind, isRequired: Bool) {
        self.id = id; self.prompt = prompt; self.kind = kind; self.isRequired = isRequired
    }
}
public struct QuestionnaireSnapshot: Codable, Hashable, Sendable {
    public var id: UUID
    public var questions: [QuestionSnapshot]
    public init(id: UUID = UUID(), questions: [QuestionSnapshot]) { self.id = id; self.questions = questions }
}
@Model public final class Patient {
    @Attribute(.unique) public var id: UUID
    public var fullName: String
    public var medicareID: String
    public var dateOfBirth: String
    public var revision: UUID
    @Relationship(deleteRule: .cascade, inverse: \Visit.patient) public var visits: [Visit]
    public init(fullName: String, medicareID: String, dateOfBirth: String) {
        id = UUID(); self.fullName = fullName; self.medicareID = MedicareID.normalise(medicareID)
        self.dateOfBirth = dateOfBirth; revision = UUID(); visits = []
    }
    public func snapshot(consultations: [Consultation] = []) -> PatientSnapshot {
        PatientSnapshot(id: id, fullName: fullName, dateOfBirth: dateOfBirth, revision: revision,
            visits: visits.sorted { $0.arrivedAt == $1.arrivedAt ? $0.id.uuidString < $1.id.uuidString : $0.arrivedAt < $1.arrivedAt }.map { visit in
                VisitSnapshot(id: visit.id, arrivedAt: visit.arrivedAt, answers: visit.answers, gpNote: visit.gpNote, noteUpdatedAt: visit.noteUpdatedAt, consultationSummaries: consultations.filter { $0.patientID == id && $0.visitID == visit.id }.sorted { $0.startedAt < $1.startedAt }.compactMap { $0.approvedSnapshot() })
            })
    }
}
@Model public final class Visit {
    @Attribute(.unique) public var id: UUID
    public var arrivedAt: Date
    public var statusRaw: String
    public var answers: [Answer]
    public var gpNote: String
    public var noteUpdatedAt: Date?
    public var patient: Patient?
    /// Set when a GP started the visit from the patient database without an intake; the database `patient_id`.
    public var databasePatientID: String?
    public init(arrivedAt: Date, answers: [Answer]) {
        id = UUID(); self.arrivedAt = arrivedAt; self.answers = answers; statusRaw = "waiting"; gpNote = ""
    }
    public var status: VisitStatus { get { VisitStatus(rawValue: statusRaw) ?? .waiting } set { statusRaw = newValue.rawValue } }
    public func open() { if status == .waiting { status = .inConsult } }
    public func finish() { status = .done }
    public static func arrivedOnSameDay(as now: Date, calendar: Calendar) -> Predicate<Visit> {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return #Predicate<Visit> { $0.arrivedAt >= start && $0.arrivedAt < end }
    }
}
// Versions and receipts are append-only. Consumers edit value snapshots and publish a new version.
@Model public final class QuestionnaireVersion {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var createdAt: Date
    public private(set) var questions: [QuestionSnapshot]
    public init(questions: [QuestionSnapshot], createdAt: Date = .now) {
        id = UUID(); self.createdAt = createdAt; self.questions = questions
    }
}
@Model public final class StoredSubmission {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var payload: Data
    public private(set) var patientID: UUID
    public private(set) var visitID: UUID
    public private(set) var patientName: String
    public private(set) var isNewPatient: Bool
    public init(id: UUID, payload: Data, receipt: SubmissionReceipt) {
        self.id = id; self.payload = payload; patientID = receipt.patientID; visitID = receipt.visitID
        patientName = receipt.patientName; isNewPatient = receipt.isNewPatient
    }
}
public struct VisitSnapshot: Sendable, Equatable {
    public var id: UUID; public var arrivedAt: Date; public var answers: [Answer]; public var gpNote: String; public var noteUpdatedAt: Date?
    public var consultationSummaries: [ConsultationSummarySnapshot]
    public init(id: UUID = UUID(), arrivedAt: Date = .now, answers: [Answer], gpNote: String = "", noteUpdatedAt: Date? = nil, consultationSummaries: [ConsultationSummarySnapshot] = []) {
        self.id = id; self.arrivedAt = arrivedAt; self.answers = answers; self.gpNote = gpNote; self.noteUpdatedAt = noteUpdatedAt; self.consultationSummaries = consultationSummaries
    }
}
public struct PatientSnapshot: Sendable, Equatable {
    public var id: UUID; public var fullName: String; public var dateOfBirth: String; public var revision: UUID; public var visits: [VisitSnapshot]
    public init(id: UUID = UUID(), fullName: String, dateOfBirth: String, revision: UUID = UUID(), visits: [VisitSnapshot]) {
        self.id = id; self.fullName = fullName; self.dateOfBirth = dateOfBirth; self.revision = revision; self.visits = visits
    }
}
public struct IntakeSubmission: Sendable, Codable {
    public var submissionID: UUID; public var questionnaireID: UUID
    public var fullName: String; public var medicareID: String; public var dateOfBirth: String
    public var answers: [Answer]; public var receivedAt: Date
    public init(submissionID: UUID = UUID(), questionnaireID: UUID, fullName: String, medicareID: String, dateOfBirth: String, answers: [Answer], receivedAt: Date = .now) {
        self.submissionID = submissionID; self.questionnaireID = questionnaireID; self.fullName = fullName
        self.medicareID = medicareID; self.dateOfBirth = dateOfBirth; self.answers = answers; self.receivedAt = receivedAt
    }
}
public struct SubmissionReceipt: Sendable, Equatable {
    public var patientID: UUID; public var visitID: UUID; public var patientName: String; public var isNewPatient: Bool
    public var isReplay: Bool = false
}
public enum RecordError: Error, LocalizedError, Equatable {
    case submissionConflict, identityCollision, invalidIdentity, missingPatient, missingVisit, unknownQuestionnaire, invalidQuestionnaire
    public var errorDescription: String? {
        switch self {
        case .submissionConflict: "This submission ID was already used with different answers. Open a new form."
        case .identityCollision: "Another patient already has this ID and date of birth. No changes were saved."
        case .invalidIdentity: "Enter a name, Medicare or insurance ID, and a valid date of birth."
        case .missingPatient: "The patient could not be found."
        case .missingVisit: "The visit could not be found in this patient’s record."
        case .unknownQuestionnaire: "This questionnaire is unavailable. Please open a new form."
        case .invalidQuestionnaire: "Questions must have unique IDs and non-empty prompts."
        }
    }
}
public enum IdentityValidation {
    public static func validDOB(_ value: String, now: Date = .now) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return false }
        return date <= now
    }
}
