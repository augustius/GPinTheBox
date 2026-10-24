import Foundation
import SwiftData

/// A consultation belongs permanently to the visit selected when recording begins.
/// Audio is transient: retain its basename only until a transcript has been saved successfully.
@Model public final class Consultation {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var patientID: UUID
    public private(set) var visitID: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var wasInterrupted: Bool = false
    public var localeIdentifier: String
    public var audioFileName: String?
    public var transcript: String
    public var transcriptRevision: UUID
    public var draftSummary: String
    public var draftTranscriptRevision: UUID?
    public var approvedSummary: String
    public var approvedAt: Date?
    public var approvedTranscriptRevision: UUID?

    public init(id: UUID = UUID(), patientID: UUID, visitID: UUID, startedAt: Date = .now,
                localeIdentifier: String, audioFileName: String? = nil) {
        self.id = id; self.patientID = patientID; self.visitID = visitID; self.startedAt = startedAt
        self.localeIdentifier = localeIdentifier; self.audioFileName = audioFileName
        transcript = ""; transcriptRevision = UUID(); draftSummary = ""; approvedSummary = ""
    }

    public func approvedSnapshot() -> ConsultationSummarySnapshot? {
        guard !approvedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let approvedAt, approvedTranscriptRevision == transcriptRevision else { return nil }
        let text = wasInterrupted ? "Partial consultation recording; may not cover the whole visit.\n" + approvedSummary : approvedSummary
        return ConsultationSummarySnapshot(id: id, text: text, approvedAt: approvedAt)
    }
}

public struct ConsultationSummarySnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var approvedAt: Date
    public init(id: UUID, text: String, approvedAt: Date) {
        self.id = id; self.text = text; self.approvedAt = approvedAt
    }
}

public enum ConsultationRecordError: Error, LocalizedError, Equatable {
    case invalidVisit, invalidAudioFileName, unsupportedLocale, emptyTranscript, emptySummary, staleTranscript, recordingNotStopped, invalidEndDate
    public var errorDescription: String? {
        switch self {
        case .invalidVisit: "The consultation does not belong to this patient's visit."
        case .invalidAudioFileName: "The recording filename is invalid."
        case .unsupportedLocale: "Choose English (Australia) or English (US)."
        case .emptyTranscript: "No transcript was produced. The audio is retained so transcription can be retried."
        case .emptySummary: "Enter a non-empty summary before saving."
        case .staleTranscript: "The transcript changed. Generate and review a new summary before saving."
        case .recordingNotStopped: "Stop the recording before saving a transcript."
        case .invalidEndDate: "The recording end time cannot precede its start time."
        }
    }
}

/// Call on the actor that owns `context`. Each operation commits before returning;
/// errors roll back mutations instead of leaving partially approved record content.
public enum ConsultationMutations {
    @discardableResult public static func create(context: ModelContext, patientID: UUID, visitID: UUID,
                                                localeIdentifier: String, audioFileName: String? = nil,
                                                startedAt: Date = .now) throws -> Consultation {
        _ = try owningPatient(context: context, patientID: patientID, visitID: visitID)
        let locale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        guard ["en-AU", "en-US"].contains(locale) else { throw ConsultationRecordError.unsupportedLocale }
        if let audioFileName { try validateAudioFileName(audioFileName) }
        let consultation = Consultation(patientID: patientID, visitID: visitID, startedAt: startedAt,
                                        localeIdentifier: locale, audioFileName: audioFileName)
        context.insert(consultation)
        try save(context)
        return consultation
    }

    public static func markStopped(context: ModelContext, consultation: Consultation, endedAt: Date = .now) throws {
        _ = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        guard endedAt >= consultation.startedAt else { throw ConsultationRecordError.invalidEndDate }
        // Recovery may observe an already-stopped recording: do not alter its original duration.
        if consultation.endedAt == nil { consultation.endedAt = endedAt }
        try save(context)
    }

    public static func saveTranscript(context: ModelContext, consultation: Consultation, text: String) throws {
        let patient = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        guard consultation.endedAt != nil else { throw ConsultationRecordError.recordingNotStopped }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConsultationRecordError.emptyTranscript }
        if text != consultation.transcript {
            consultation.transcript = text; consultation.transcriptRevision = UUID()
            consultation.draftSummary = ""; consultation.draftTranscriptRevision = nil
            consultation.approvedSummary = ""; consultation.approvedAt = nil; consultation.approvedTranscriptRevision = nil
            patient.revision = UUID()
        }
        try save(context)
    }

    public static func saveDraft(context: ModelContext, consultation: Consultation, text: String, transcriptRevision: UUID) throws {
        _ = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        try validateSummary(consultation: consultation, text: text, transcriptRevision: transcriptRevision)
        consultation.draftSummary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        consultation.draftTranscriptRevision = transcriptRevision
        try save(context)
    }

    public static func approveSummary(context: ModelContext, consultation: Consultation, text: String,
                                      transcriptRevision: UUID, approvedAt: Date = .now) throws {
        let patient = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        try validateSummary(consultation: consultation, text: text, transcriptRevision: transcriptRevision)
        consultation.approvedSummary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        consultation.approvedAt = approvedAt; consultation.approvedTranscriptRevision = transcriptRevision
        consultation.draftSummary = consultation.approvedSummary; consultation.draftTranscriptRevision = transcriptRevision
        patient.revision = UUID()
        try save(context)
    }

    /// Call only after removing the audio file, and only after saveTranscript returned successfully.
    public static func markAudioDeleted(context: ModelContext, consultation: Consultation) throws {
        _ = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        guard !consultation.transcript.isEmpty else { throw ConsultationRecordError.emptyTranscript }
        consultation.audioFileName = nil
        try save(context)
    }

    public static func approvedSummaries(context: ModelContext, patientID: UUID, visitID: UUID) throws -> [ConsultationSummarySnapshot] {
        _ = try owningPatient(context: context, patientID: patientID, visitID: visitID)
        let request = FetchDescriptor<Consultation>(predicate: #Predicate { $0.patientID == patientID && $0.visitID == visitID }, sortBy: [SortDescriptor(\.startedAt)])
        return try context.fetch(request).compactMap { $0.approvedSnapshot() }
    }

    private static func validateSummary(consultation: Consultation, text: String, transcriptRevision: UUID) throws {
        guard consultation.transcriptRevision == transcriptRevision else { throw ConsultationRecordError.staleTranscript }
        guard !consultation.transcript.isEmpty else { throw ConsultationRecordError.emptyTranscript }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConsultationRecordError.emptySummary }
    }
    private static func validateAudioFileName(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              !filename.contains("\0") else { throw ConsultationRecordError.invalidAudioFileName }
    }
    private static func owningPatient(context: ModelContext, patientID: UUID, visitID: UUID) throws -> Patient {
        guard let visit = try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitID })).first,
              let patient = visit.patient, patient.id == patientID else { throw ConsultationRecordError.invalidVisit }
        return patient
    }
    private static func save(_ context: ModelContext) throws {
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
