import Foundation
import SwiftData

public enum GPInTheBoxSchema {
    public static var schema: Schema { Schema([Patient.self, Visit.self, QuestionnaireVersion.self, StoredSubmission.self, Consultation.self]) }
    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
    public static let defaultQuestions: [QuestionSnapshot] = [
        .init(prompt: "What is the main reason for your visit today?", kind: .longText, isRequired: true),
        .init(prompt: "When did it start?", kind: .shortText, isRequired: true),
        .init(prompt: "Describe your symptoms.", kind: .longText, isRequired: false),
        .init(prompt: "Are you currently taking any medications? Please list them.", kind: .longText, isRequired: false),
        .init(prompt: "Do you have any allergies?", kind: .shortText, isRequired: false),
        .init(prompt: "Do you have any ongoing medical conditions?", kind: .longText, isRequired: false),
        .init(prompt: "Is there anything else you'd like the doctor to know?", kind: .longText, isRequired: false)
    ]
}
@ModelActor public actor RecordStore {
    public func seedDefaultQuestionnaireIfEmpty() throws {
        if try modelContext.fetchCount(FetchDescriptor<QuestionnaireVersion>()) == 0 {
            _ = try publishQuestionnaire(GPInTheBoxSchema.defaultQuestions)
        }
    }
    public func questionnaire(id: UUID? = nil) throws -> QuestionnaireSnapshot {
        var request: FetchDescriptor<QuestionnaireVersion>
        if let id {
            request = FetchDescriptor(predicate: #Predicate { $0.id == id })
        } else {
            request = FetchDescriptor(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        }
        request.fetchLimit = 1
        guard let version = try modelContext.fetch(request).first else { throw RecordError.unknownQuestionnaire }
        return QuestionnaireSnapshot(id: version.id, questions: version.questions)
    }
    @discardableResult public func publishQuestionnaire(_ questions: [QuestionSnapshot]) throws -> QuestionnaireSnapshot {
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw RecordError.invalidQuestionnaire }
        var latest = FetchDescriptor<QuestionnaireVersion>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        latest.fetchLimit = 1
        // Clock adjustments or rapid publishing must not make an older version current again.
        let previousDate = try modelContext.fetch(latest).first?.createdAt
        let createdAt = max(Date.now, previousDate?.addingTimeInterval(0.000001) ?? .distantPast)
        let version = QuestionnaireVersion(questions: questions, createdAt: createdAt)
        modelContext.insert(version)
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
        return QuestionnaireSnapshot(id: version.id, questions: questions)
    }
    public func recordSubmission(_ input: IntakeSubmission) throws -> SubmissionReceipt {
        var s = input
        s.medicareID = MedicareID.normalise(s.medicareID)
        s.fullName = s.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Arrival time is server metadata, not part of the idempotency payload.
        var canonical = s; canonical.receivedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(canonical)
        let submissionID = s.submissionID
        if let previous = try modelContext.fetch(FetchDescriptor<StoredSubmission>(predicate: #Predicate { $0.id == submissionID })).first {
            guard previous.payload == payload else { throw RecordError.submissionConflict }
            return SubmissionReceipt(patientID: previous.patientID, visitID: previous.visitID, patientName: previous.patientName, isNewPatient: previous.isNewPatient, isReplay: true)
        }
        guard !s.fullName.isEmpty, !s.medicareID.isEmpty, IdentityValidation.validDOB(s.dateOfBirth, now: s.receivedAt) else { throw RecordError.invalidIdentity }
        let version = try questionnaire(id: s.questionnaireID)
        guard s.answers.map(\.questionID) == version.questions.map(\.id),
              zip(s.answers, version.questions).allSatisfy({ $0.prompt == $1.prompt && (!$1.isRequired || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) else { throw RecordError.invalidQuestionnaire }
        let key = s.medicareID, dob = s.dateOfBirth
        let existing = try modelContext.fetch(FetchDescriptor<Patient>(predicate: #Predicate { $0.medicareID == key && $0.dateOfBirth == dob })).first
        let patient = existing ?? Patient(fullName: s.fullName, medicareID: key, dateOfBirth: dob)
        if existing == nil { modelContext.insert(patient) }
        let visit = Visit(arrivedAt: s.receivedAt, answers: s.answers)
        modelContext.insert(visit)
        // Mutate the collection explicitly; SwiftData maintains Visit.patient through the inverse.
        patient.visits.append(visit)
        patient.revision = UUID()
        let receipt = SubmissionReceipt(patientID: patient.id, visitID: visit.id, patientName: patient.fullName, isNewPatient: existing == nil)
        modelContext.insert(StoredSubmission(id: s.submissionID, payload: payload, receipt: receipt))
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
        return receipt
    }
    public func correctIdentity(patientID: UUID, fullName: String, medicareID: String, dateOfBirth: String) throws {
        try RecordMutations.correctIdentity(context: modelContext, patientID: patientID, fullName: fullName, medicareID: medicareID, dateOfBirth: dateOfBirth)
    }
    public func snapshot(patientID: UUID) throws -> PatientSnapshot {
        guard let p = try modelContext.fetch(FetchDescriptor<Patient>(predicate: #Predicate { $0.id == patientID })).first else { throw RecordError.missingPatient }
        let consultations = try modelContext.fetch(FetchDescriptor<Consultation>(predicate: #Predicate { $0.patientID == patientID }))
        return p.snapshot(consultations: consultations)
    }
}

/// Synchronous mutations run on the supplied context's owning actor. The app uses its main
/// context; HTTP intake uses RecordStore's context, avoiding duplicate cross-context writes.
public enum RecordMutations {
    public static func correctIdentity(context: ModelContext, patientID: UUID, fullName: String, medicareID: String, dateOfBirth: String) throws {
        let key = MedicareID.normalise(medicareID), name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !name.isEmpty, IdentityValidation.validDOB(dateOfBirth) else { throw RecordError.invalidIdentity }
        let dob = dateOfBirth
        let matches = try context.fetch(FetchDescriptor<Patient>(predicate: #Predicate { $0.medicareID == key && $0.dateOfBirth == dob }))
        guard !matches.contains(where: { $0.id != patientID }) else { throw RecordError.identityCollision }
        guard let patient = try context.fetch(FetchDescriptor<Patient>(predicate: #Predicate { $0.id == patientID })).first else { throw RecordError.missingPatient }
        patient.fullName = name; patient.medicareID = key; patient.dateOfBirth = dob; patient.revision = UUID()
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
