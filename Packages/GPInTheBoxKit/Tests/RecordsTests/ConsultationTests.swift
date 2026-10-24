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

@Test @MainActor func archivePreservesContentExcludesSummaryAndCanBeRestored() throws {
    let (container, patient, visit, consultation) = try consultationFixture()
    let context = container.mainContext
    #expect(throws: ConsultationRecordError.recordingNotStopped) {
        try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: true)
    }
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    try ConsultationMutations.saveTranscript(context: context, consultation: consultation, text: "Synthetic transcript")
    try ConsultationMutations.approveSummary(context: context, consultation: consultation, text: "Reviewed summary", transcriptRevision: consultation.transcriptRevision)
    let revision = patient.revision
    try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: true)
    #expect(patient.revision != revision)
    #expect(consultation.transcript == "Synthetic transcript" && consultation.audioFileName == "recording.caf")
    #expect(consultation.approvedSummary == "Reviewed summary" && consultation.approvedSnapshot() == nil)
    #expect(try ConsultationMutations.approvedSummaries(context: context, patientID: patient.id, visitID: visit.id).isEmpty)
    #expect(throws: ConsultationRecordError.archived) {
        try ConsultationMutations.saveDraft(context: context, consultation: consultation, text: "Late result", transcriptRevision: consultation.transcriptRevision)
    }
    let fresh = try ConsultationMutations.create(context: context, patientID: patient.id, visitID: visit.id, localeIdentifier: "en-AU")
    #expect(fresh.id != consultation.id && fresh.archivedAt == nil)
    let secondContext = ModelContext(container)
    let id = consultation.id
    #expect(try secondContext.fetch(FetchDescriptor<Consultation>(predicate: #Predicate { $0.id == id })).first?.archivedAt != nil)
    try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: false)
    #expect(consultation.approvedSnapshot()?.text == "Reviewed summary")
}

@Test @MainActor func conversationRolesAndCorrectionsInvalidateApprovedSummary() throws {
    let (container, patient, _, consultation) = try consultationFixture()
    let context = container.mainContext
    let turns = [ConversationTurn(text: "Any medication?", startSeconds: 0, endSeconds: 2, speakerID: "Speaker 1"),
                 ConversationTurn(text: "Metformin", startSeconds: 3, endSeconds: 4, speakerID: "Speaker 2")]
    #expect(throws: ConsultationRecordError.recordingNotStopped) {
        try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: turns)
    }
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: turns)
    #expect(consultation.transcript == "Any medication? Metformin")
    #expect(consultation.conversationText.contains("Speaker 1: Any medication?"))
    #expect(!consultation.conversationText.contains("Doctor"))
    try ConsultationMutations.approveSummary(context: context, consultation: consultation, text: "Medication discussed", transcriptRevision: consultation.transcriptRevision)
    let revision = patient.revision
    try ConsultationMutations.assignSpeakerRole(context: context, consultation: consultation, speakerID: "Speaker 1", role: .doctor)
    try ConsultationMutations.assignSpeakerRole(context: context, consultation: consultation, speakerID: "Speaker 2", role: .patient)
    #expect(consultation.conversationText.contains("Doctor: Any medication?"))
    #expect(consultation.conversationText.contains("Patient: Metformin"))
    #expect(consultation.approvedSnapshot() == nil && patient.revision != revision)
    let beforeEdit = consultation.transcriptRevision
    try ConsultationMutations.updateConversationTurn(context: context, consultation: consultation, turnID: turns[1].id, text: "No medication", speakerID: "Speaker 2")
    #expect(consultation.transcriptRevision != beforeEdit && consultation.transcript == "Any medication? No medication")
    try ConsultationMutations.saveTranscript(context: context, consultation: consultation, text: "Manually replaced transcript")
    #expect(consultation.conversationTurns.isEmpty && consultation.speakerRoles.isEmpty)
    #expect(consultation.conversationText == "Manually replaced transcript")
}

@Test @MainActor func conversationRejectsMalformedTurnsAndUnknownSpeakers() throws {
    let (container, _, _, consultation) = try consultationFixture()
    let context = container.mainContext
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    let valid = ConversationTurn(text: "Original", startSeconds: 0, endSeconds: 1, speakerID: "Speaker 1")
    try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: [valid])
    for turns in [[], [valid, valid], [ConversationTurn(text: "", startSeconds: 0, endSeconds: 1)],
                  [ConversationTurn(text: "Bad", startSeconds: .nan, endSeconds: 1)],
                  [ConversationTurn(text: "Bad", startSeconds: 2, endSeconds: 1)],
                  [ConversationTurn(text: "Bad", startSeconds: 0, endSeconds: 1, speakerID: "\nDoctor")]] {
        #expect(throws: ConsultationRecordError.invalidConversation) {
            try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: turns)
        }
    }
    #expect(consultation.conversationTurns == [valid])
    #expect(throws: ConsultationRecordError.unknownSpeaker) {
        try ConsultationMutations.assignSpeakerRole(context: context, consultation: consultation, speakerID: "Missing", role: .doctor)
    }
    #expect(throws: ConsultationRecordError.unknownTurn) {
        try ConsultationMutations.updateConversationTurn(context: context, consultation: consultation, turnID: UUID(), text: "Edit", speakerID: nil)
    }
    try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: true)
    #expect(throws: ConsultationRecordError.archived) {
        try ConsultationMutations.assignSpeakerRole(context: context, consultation: consultation, speakerID: "Speaker 1", role: .doctor)
    }
}

@Test @MainActor func conversationTurnsRolesAndStatusPersistAcrossReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversation.store")
    let id: UUID = try {
        let container = try GPInTheBoxSchema.makeContainer(url: url)
        let patient = Patient(fullName: "Conversation demo", medicareID: "CONVERSATION", dateOfBirth: "1980-01-01")
        let visit = Visit(arrivedAt: .now, answers: [])
        container.mainContext.insert(patient); container.mainContext.insert(visit); patient.visits.append(visit)
        try container.mainContext.save()
        let c = try ConsultationMutations.create(context: container.mainContext, patientID: patient.id, visitID: visit.id, localeIdentifier: "en-AU")
        try ConsultationMutations.markStopped(context: container.mainContext, consultation: c)
        try ConsultationMutations.saveConversation(context: container.mainContext, consultation: c, turns: [ConversationTurn(text: "Synthetic statement", startSeconds: 1, endSeconds: 2, speakerID: "Speaker 1")])
        try ConsultationMutations.assignSpeakerRole(context: container.mainContext, consultation: c, speakerID: "Speaker 1", role: .patient)
        return c.id
    }()
    let reopened = try GPInTheBoxSchema.makeContainer(url: url)
    let c = try #require(reopened.mainContext.fetch(FetchDescriptor<Consultation>(predicate: #Predicate { $0.id == id })).first)
    #expect(c.conversationTurns.count == 1 && c.speakerRoles["Speaker 1"] == .patient)
    #expect(c.diarizationStatus == .completed && c.conversationText == "[00:01] Patient: Synthetic statement")
}


@Test @MainActor func pendingOrFailedSpeakerAnalysisProtectsRetainedAudio() throws {
    let (container, _, _, consultation) = try consultationFixture()
    let context = container.mainContext
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    try ConsultationMutations.saveConversation(context: context, consultation: consultation,
        turns: [ConversationTurn(text: "Pending analysis", startSeconds: 0, endSeconds: 1)], diarizationStatus: .pending)
    for status in [ConversationDiarizationStatus.pending, .failed] {
        try ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: status)
        #expect(throws: ConsultationRecordError.speakerAnalysisIncomplete) {
            try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
        }
        #expect(consultation.audioFileName == "recording.caf")
    }
    try ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: .skipped)
    try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
    #expect(consultation.audioFileName == nil)
    let completed = try ConsultationMutations.create(context: context, patientID: consultation.patientID,
        visitID: consultation.visitID, localeIdentifier: "en-AU", audioFileName: "complete.caf")
    try ConsultationMutations.markStopped(context: context, consultation: completed)
    try ConsultationMutations.saveConversation(context: context, consultation: completed,
        turns: [ConversationTurn(text: "Complete analysis", startSeconds: 0, endSeconds: 1)], diarizationStatus: .completed)
    try ConsultationMutations.markAudioDeleted(context: context, consultation: completed)
    #expect(completed.audioFileName == nil)
}

@Test @MainActor func archivedPendingSpeakerAnalysisPersistsAcrossReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("pending.store")
    let id: UUID = try {
        let container = try GPInTheBoxSchema.makeContainer(url: url)
        let context = container.mainContext
        let patient = Patient(fullName: "Pending synthetic", medicareID: "PENDING", dateOfBirth: "1980-01-01")
        let visit = Visit(arrivedAt: .now, answers: [])
        context.insert(patient); context.insert(visit); patient.visits.append(visit)
        try context.save()
        let c = try ConsultationMutations.create(context: context, patientID: patient.id, visitID: visit.id,
            localeIdentifier: "en-AU", audioFileName: "pending.caf")
        try ConsultationMutations.markStopped(context: context, consultation: c)
        try ConsultationMutations.saveConversation(context: context, consultation: c,
            turns: [ConversationTurn(text: "Preserved text", startSeconds: 0, endSeconds: 1)], diarizationStatus: .pending)
        try ConsultationMutations.setArchived(context: context, consultation: c, archived: true)
        return c.id
    }()
    let reopened = try GPInTheBoxSchema.makeContainer(url: url)
    let c = try #require(reopened.mainContext.fetch(FetchDescriptor<Consultation>(predicate: #Predicate { $0.id == id })).first)
    #expect(c.archivedAt != nil && c.diarizationStatus == .pending)
    #expect(c.audioFileName == "pending.caf" && c.conversationTurns.first?.text == "Preserved text")
    #expect(throws: ConsultationRecordError.speakerAnalysisIncomplete) {
        try ConsultationMutations.markAudioDeleted(context: reopened.mainContext, consultation: c)
    }
}


@Test @MainActor func anonymousSpeakerLabelsAreReadableWithoutInferringRoles() throws {
    let (container, _, _, consultation) = try consultationFixture()
    #expect(consultation.speakerLabel(for: "SPEAKER_00") == "Speaker 1")
    #expect(consultation.speakerLabel(for: "SPEAKER_09") == "Speaker 10")
    #expect(consultation.speakerLabel(for: nil) == "Unassigned")
    try ConsultationMutations.markStopped(context: container.mainContext, consultation: consultation)
    try ConsultationMutations.saveConversation(context: container.mainContext, consultation: consultation,
        turns: [ConversationTurn(text: "Synthetic text", startSeconds: 0, endSeconds: 1, speakerID: "SPEAKER_00")])
    try ConsultationMutations.assignSpeakerRole(context: container.mainContext, consultation: consultation, speakerID: "SPEAKER_00", role: .doctor)
    #expect(consultation.speakerLabel(for: "SPEAKER_00") == "Doctor")
    #expect(consultation.conversationTurns[0].speakerID == "SPEAKER_00")
}


@Test @MainActor func GPManuallyAssignsUncertainTurnWithoutAutomaticRoleGuessing() throws {
    let (container, patient, _, consultation) = try consultationFixture()
    let context = container.mainContext
    let turn = ConversationTurn(text: "A synthetic concern", startSeconds: 0, endSeconds: 1)
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: [turn], diarizationStatus: .failed)
    #expect(consultation.conversationText.contains("Unassigned:"))
    try ConsultationMutations.approveSummary(context: context, consultation: consultation, text: "Old summary", transcriptRevision: consultation.transcriptRevision)
    let revision = patient.revision
    #expect(throws: ConsultationRecordError.unknownTurn) {
        try ConsultationMutations.assignTurnRole(context: context, consultation: consultation, turnID: UUID(), role: .doctor)
    }
    try ConsultationMutations.assignTurnRole(context: context, consultation: consultation, turnID: turn.id, role: .patient)
    #expect(consultation.conversationText.contains("Patient: A synthetic concern"))
    #expect(consultation.conversationTurns[0].speakerID == "MANUAL_PATIENT")
    #expect(consultation.approvedSnapshot() == nil && patient.revision != revision)
    try ConsultationMutations.assignTurnRole(context: context, consultation: consultation, turnID: turn.id, role: .doctor)
    #expect(consultation.conversationText.contains("Doctor: A synthetic concern"))
    #expect(consultation.speakerRoles["MANUAL_PATIENT"] == nil)
    try ConsultationMutations.assignTurnRole(context: context, consultation: consultation, turnID: turn.id, role: .unassigned)
    #expect(consultation.conversationTurns[0].speakerID == nil && consultation.speakerRoles.isEmpty)
}


@Test @MainActor func plainTranscriptCorrectionCannotWaivePendingSpeakerAudioRetention() throws {
    let (container, _, _, consultation) = try consultationFixture()
    let context = container.mainContext
    try ConsultationMutations.markStopped(context: context, consultation: consultation)
    for status in [ConversationDiarizationStatus.pending, .failed] {
        try ConsultationMutations.saveConversation(context: context, consultation: consultation,
            turns: [ConversationTurn(text: "Original", startSeconds: 0, endSeconds: 1)], diarizationStatus: status)
        try ConsultationMutations.saveTranscript(context: context, consultation: consultation, text: "Corrected plain text")
        #expect(consultation.conversationTurns.isEmpty && consultation.speakerRoles.isEmpty)
        #expect(consultation.diarizationStatus == status)
        #expect(throws: ConsultationRecordError.speakerAnalysisIncomplete) {
            try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
        }
        #expect(consultation.audioFileName == "recording.caf")
    }
    try ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: .skipped)
    try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
    #expect(consultation.audioFileName == nil)
}
