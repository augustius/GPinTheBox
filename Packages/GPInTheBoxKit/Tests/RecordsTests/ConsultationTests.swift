import Foundation
import SwiftData
import Testing
@testable import Records

@MainActor private func consultationFixture() throws -> (ModelContainer, Patient, Visit, Consultation) {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true)
    let patient = Patient(fullName: "Synthetic consultation", medicareID: "DEMO-CONSULT", dateOfBirth: "1980-01-01")
    let visit = Visit(arrivedAt: .now, answers: [])
    container.mainContext.insert(patient); container.mainContext.insert(visit); patient.visits.append(visit)
    try container.mainContext.save()
    let consultation = try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "en-AU", audioFileName: "recording.caf")
    return (container, patient, visit, consultation)
}

@Test @MainActor func consultationTranscriptSavedBeforeAudioCanBeReleased() throws {
    let (container, _, _, consultation) = try consultationFixture()
    #expect(throws: ConsultationRecordError.emptyTranscript) {
        try ConsultationMutations.markAudioDeleted(context: container.mainContext, consultation: consultation)
    }
    #expect(consultation.audioFileName == "recording.caf")
    #expect(throws: ConsultationRecordError.recordingNotStopped) {
        try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Hello")
    }
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "  Synthetic cough discussion.  ")
    #expect(consultation.transcript == "Synthetic cough discussion.")
    #expect(consultation.audioFileName == "recording.caf")
    try ConsultationMutations.markAudioDeleted(context: container.mainContext, consultation: consultation)
    #expect(consultation.audioFileName == nil)
    #expect(consultation.approvedSnapshot() == nil)
}

@Test @MainActor func emptyTranscriptionRetainsAudioAndPriorData() throws {
    let (container, _, _, consultation) = try consultationFixture()
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    let revision = consultation.transcriptRevision
    #expect(throws: ConsultationRecordError.emptyTranscript) {
        try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: " \n ")
    }
    #expect(consultation.audioFileName == "recording.caf")
    #expect(consultation.transcriptRevision == revision)
}

@Test @MainActor func transcriptEditsInvalidateDraftAndApproval() throws {
    let (container, patient, _, consultation) = try consultationFixture()
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Cough for three days.")
    let first = consultation.transcriptRevision
    try ConsultationMutations.saveDraft(context: container.mainContext, consultation: consultation, text: "Cough reported.", transcriptRevision: first)
    #expect(consultation.approvedSnapshot() == nil)
    try ConsultationMutations.approveSummary(context: container.mainContext, consultation: consultation, text: "Doctor reviewed: cough reported for three days.", transcriptRevision: first)
    #expect(consultation.approvedSnapshot()?.text == "Doctor reviewed: cough reported for three days.")
    let patientRevision = patient.revision
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Cough for six days, corrected by doctor.")
    #expect(consultation.transcriptRevision != first && patient.revision != patientRevision)
    #expect(consultation.draftSummary.isEmpty && consultation.draftTranscriptRevision == nil)
    #expect(consultation.approvedSummary.isEmpty && consultation.approvedAt == nil && consultation.approvedSnapshot() == nil)
}

@Test @MainActor func staleSummaryCannotBeDraftedOrApproved() throws {
    let (container, _, _, consultation) = try consultationFixture()
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "First text")
    let old = consultation.transcriptRevision
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Edited text")
    #expect(throws: ConsultationRecordError.staleTranscript) {
        try ConsultationMutations.saveDraft(context: container.mainContext, consultation: consultation, text: "Old draft", transcriptRevision: old)
    }
    #expect(throws: ConsultationRecordError.staleTranscript) {
        try ConsultationMutations.approveSummary(context: container.mainContext, consultation: consultation, text: "Old approval", transcriptRevision: old)
    }
    #expect(consultation.draftSummary.isEmpty && consultation.approvedSnapshot() == nil)
}

@Test @MainActor func unchangedTranscriptPreservesApprovalAndRevision() throws {
    let (container, _, _, consultation) = try consultationFixture()
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Cough")
    let revision = consultation.transcriptRevision
    try ConsultationMutations.approveSummary(context: container.mainContext, consultation: consultation, text: "Cough reported", transcriptRevision: revision)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: " Cough \n")
    #expect(consultation.transcriptRevision == revision && consultation.approvedSnapshot() != nil)
}

@Test @MainActor func summariesAreRestrictedToTheirOwnVisitAndPatient() throws {
    let (container, patient, visit, consultation) = try consultationFixture()
    let other = Patient(fullName: "Other patient", medicareID: "OTHER", dateOfBirth: "1990-01-01")
    let otherVisit = Visit(arrivedAt: .now, answers: [])
    container.mainContext.insert(other); container.mainContext.insert(otherVisit); other.visits.append(otherVisit)
    try container.mainContext.save()
    #expect(throws: ConsultationRecordError.invalidVisit) {
        try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: otherVisit.id, localeIdentifier: "en-US")
    }
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Synthetic transcript")
    try ConsultationMutations.approveSummary(context: container.mainContext, consultation: consultation, text: "Reviewed summary", transcriptRevision: consultation.transcriptRevision)
    #expect(try ConsultationMutations.approvedSummaries(context: container.mainContext, patientID: patient.id, visitID: visit.id).count == 1)
    #expect(try ConsultationMutations.approvedSummaries(context: container.mainContext, patientID: other.id, visitID: otherVisit.id).isEmpty)
    #expect(patient.snapshot(consultations: [consultation]).visits[0].consultationSummaries.count == 1)
    #expect(other.snapshot(consultations: [consultation]).visits[0].consultationSummaries.isEmpty)
}

@Test @MainActor func invalidRecordingMetadataDoesNotCreateConsultation() throws {
    let (container, patient, visit, _) = try consultationFixture()
    for filename in ["../secret.caf", "/tmp/file.caf", "folder\\file.caf", "", ".."] {
        #expect(throws: ConsultationRecordError.invalidAudioFileName) {
            try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "en-AU", audioFileName: filename)
        }
    }
    #expect(throws: ConsultationRecordError.unsupportedLocale) {
        try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "fr-FR")
    }
    let us = try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "en_US")
    #expect(us.localeIdentifier == "en-US")
    #expect(try container.mainContext.fetchCount(FetchDescriptor<Consultation>()) == 2)
}

@Test @MainActor func consultationPersistsAcrossReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("records.store")
    let consultationID: UUID = try {
        let container = try GPInTheBoxSchema.makeContainer(url: url)
        let patient = Patient(fullName: "Persisted demo", medicareID: "PERSIST", dateOfBirth: "1980-01-01")
        let visit = Visit(arrivedAt: .now, answers: [])
        container.mainContext.insert(patient); container.mainContext.insert(visit); patient.visits.append(visit)
        try container.mainContext.save()
        let c = try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "en-US", audioFileName: "pending.caf")
        try ConsultationMutations.markStopped(context: container.mainContext, consultation: c)
        try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: c, text: "Persisted transcript")
        try ConsultationMutations.approveSummary(context: container.mainContext, consultation: c, text: "Reviewed persistent summary", transcriptRevision: c.transcriptRevision)
        try ConsultationMutations.markAudioDeleted(context: container.mainContext, consultation: c)
        return c.id
    }()
    let reopened = try GPInTheBoxSchema.makeContainer(url: url)
    let consultation = try #require(reopened.mainContext.fetch(FetchDescriptor<Consultation>(predicate: #Predicate { $0.id == consultationID })).first)
    #expect(consultation.transcript == "Persisted transcript")
    #expect(consultation.approvedSnapshot()?.text == "Reviewed persistent summary")
    #expect(consultation.audioFileName == nil && consultation.endedAt != nil)
}

@Test @MainActor func preConsultationStoreMigratesWithoutLosingVisits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("legacy.store")
    let patientID: UUID = try {
        let original = Schema([Patient.self, Visit.self, QuestionnaireVersion.self, StoredSubmission.self])
        let config = ModelConfiguration(schema: original, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: original, configurations: [config])
        let patient = Patient(fullName: "Existing demo", medicareID: "LEGACY", dateOfBirth: "1980-01-01")
        let visit = Visit(arrivedAt: .now, answers: [])
        visit.gpNote = "Existing note must survive."
        container.mainContext.insert(patient); container.mainContext.insert(visit); patient.visits.append(visit)
        try container.mainContext.save()
        return patient.id
    }()
    let upgraded = try GPInTheBoxSchema.makeContainer(url: url)
    let patient = try #require(upgraded.mainContext.fetch(FetchDescriptor<Patient>(predicate: #Predicate { $0.id == patientID })).first)
    #expect(patient.fullName == "Existing demo" && patient.visits.count == 1)
    #expect(patient.visits[0].gpNote == "Existing note must survive.")
    #expect(try upgraded.mainContext.fetchCount(FetchDescriptor<Consultation>()) == 0)
    let c = try ConsultationMutations.create(context: upgraded.mainContext, patientID: patient.id, visitID: patient.visits[0].id, localeIdentifier: "en-AU")
    #expect(c.patientID == patient.id)
}

@Test @MainActor func interruptedConsultationKeepsPartialProvenanceInFutureRecords() throws {
    let (container, _, _, consultation) = try consultationFixture()
    consultation.wasInterrupted = true
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: container.mainContext, consultation: consultation, text: "Only the first part was recorded.")
    try ConsultationMutations.approveSummary(context: container.mainContext, consultation: consultation, text: "Opening concerns discussed.", transcriptRevision: consultation.transcriptRevision)
    #expect(consultation.approvedSnapshot()?.text.contains("may not cover the whole visit") == true)
    #expect(consultation.approvedSnapshot()?.text.contains("Opening concerns discussed.") == true)
}
