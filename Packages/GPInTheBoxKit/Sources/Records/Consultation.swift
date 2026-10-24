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
    public var archivedAt: Date? = nil
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
    // Optional additive fields keep existing stores readable after migration.
    public private(set) var conversationTurnsData: Data? = nil
    public private(set) var speakerRolesData: Data? = nil
    public var diarizationStatusRaw: String = "notRequested"

    public var conversationTurns: [ConversationTurn] {
        guard let conversationTurnsData else { return [] }
        return (try? JSONDecoder().decode([ConversationTurn].self, from: conversationTurnsData)) ?? []
    }
    public var speakerRoles: [String: SpeakerRole] {
        guard let speakerRolesData else { return [:] }
        return (try? JSONDecoder().decode([String: SpeakerRole].self, from: speakerRolesData)) ?? [:]
    }
    public var diarizationStatus: ConversationDiarizationStatus {
        ConversationDiarizationStatus(rawValue: diarizationStatusRaw) ?? .notRequested
    }
    public func speakerLabel(for speakerID: String?) -> String {
        guard let speakerID else { return "Unassigned" }
        if let role = speakerRoles[speakerID], role != .unassigned { return role.rawValue }
        if speakerID.hasPrefix("SPEAKER_"), let number = Int(speakerID.dropFirst("SPEAKER_".count)), number >= 0, number < 100_000 {
            return "Speaker \(number + 1)"
        }
        return speakerID
    }
    public var conversationText: String {
        let turns = conversationTurns
        guard !turns.isEmpty else { return transcript }
        return turns.map { turn in
            let seconds = Int(turn.startSeconds)
            let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "[\(time)] \(speakerLabel(for: turn.speakerID)): \(turn.text)"
        }.joined(separator: "\n")
    }

    fileprivate func storeConversation(_ turns: [ConversationTurn], roles: [String: SpeakerRole]) throws {
        let turnsData = try JSONEncoder().encode(turns)
        let rolesData = try JSONEncoder().encode(roles)
        conversationTurnsData = turnsData; speakerRolesData = rolesData
    }
    fileprivate func clearConversation() {
        conversationTurnsData = nil; speakerRolesData = nil
        // A plain-text correction cannot implicitly waive the retained-audio requirement.
        if diarizationStatus != .pending && diarizationStatus != .failed {
            diarizationStatusRaw = ConversationDiarizationStatus.notRequested.rawValue
        }
    }

    public init(id: UUID = UUID(), patientID: UUID, visitID: UUID, startedAt: Date = .now,
                localeIdentifier: String, audioFileName: String? = nil) {
        self.id = id; self.patientID = patientID; self.visitID = visitID; self.startedAt = startedAt
        self.localeIdentifier = localeIdentifier; self.audioFileName = audioFileName
        transcript = ""; transcriptRevision = UUID(); draftSummary = ""; approvedSummary = ""
    }

    public func approvedSnapshot() -> ConsultationSummarySnapshot? {
        guard archivedAt == nil, !approvedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let approvedAt, approvedTranscriptRevision == transcriptRevision else { return nil }
        let text = wasInterrupted ? "Partial consultation recording; may not cover the whole visit.\n" + approvedSummary : approvedSummary
        return ConsultationSummarySnapshot(id: id, text: text, approvedAt: approvedAt)
    }
}

public struct ConversationTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var speakerID: String?
    public init(id: UUID = UUID(), text: String, startSeconds: Double, endSeconds: Double, speakerID: String? = nil) {
        self.id = id; self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.speakerID = speakerID
    }
}

public enum SpeakerRole: String, Codable, Sendable, CaseIterable {
    case doctor = "Doctor", patient = "Patient", other = "Other", unassigned = "Unassigned"
}

public enum ConversationDiarizationStatus: String, Codable, Sendable {
    case notRequested, pending, completed, failed, skipped
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
    case speakerAnalysisIncomplete, invalidConversation, unknownSpeaker, unknownTurn, archived, invalidVisit, invalidAudioFileName, unsupportedLocale, emptyTranscript, emptySummary, staleTranscript, recordingNotStopped, invalidEndDate
    public var errorDescription: String? {
        switch self {
        case .speakerAnalysisIncomplete: "Finish speaker separation or explicitly keep the transcript without speaker separation before deleting audio."
        case .invalidConversation: "Conversation turns must have unique IDs, non-empty text, and valid chronological timestamps."
        case .unknownSpeaker: "That speaker does not occur in this conversation."
        case .unknownTurn: "That conversation turn no longer exists."
        case .archived: "Restore this archived recording before editing it."
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

    /// Archiving preserves saved content and retained audio, but excludes it from AI context.
    public static func setArchived(context: ModelContext, consultation: Consultation, archived: Bool) throws {
        let patient = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        if archived && consultation.endedAt == nil { throw ConsultationRecordError.recordingNotStopped }
        guard archived != (consultation.archivedAt != nil) else { return }
        consultation.archivedAt = archived ? .now : nil
        patient.revision = UUID()
        try save(context)
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
        guard consultation.archivedAt == nil else { throw ConsultationRecordError.archived }
        guard consultation.endedAt != nil else { throw ConsultationRecordError.recordingNotStopped }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConsultationRecordError.emptyTranscript }
        if text != consultation.transcript {
            consultation.transcript = text
            consultation.clearConversation()
            invalidateSummary(consultation, patient: patient)
        }
        try save(context)
    }

    /// Persists timed text and speaker analysis in one save. New analysis clears role assignments,
    /// since anonymous speaker IDs can change across diarization runs.
    public static func saveConversation(context: ModelContext, consultation: Consultation, turns: [ConversationTurn],
                                        diarizationStatus: ConversationDiarizationStatus = .completed) throws {
        let patient = try editablePatient(context: context, consultation: consultation)
        try validateTurns(turns)
        let turns = turns.map { turn in
            var result = turn; result.text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines); return result
        }
        try consultation.storeConversation(turns, roles: [:])
        consultation.transcript = turns.map(\.text).joined(separator: " ")
        consultation.diarizationStatusRaw = diarizationStatus.rawValue
        invalidateSummary(consultation, patient: patient)
        try save(context)
    }

    public static func assignSpeakerRole(context: ModelContext, consultation: Consultation, speakerID: String, role: SpeakerRole) throws {
        let patient = try editablePatient(context: context, consultation: consultation)
        let turns = consultation.conversationTurns
        guard turns.contains(where: { $0.speakerID == speakerID }) else { throw ConsultationRecordError.unknownSpeaker }
        var roles = consultation.speakerRoles
        guard (roles[speakerID] ?? .unassigned) != role else { return }
        if role == .unassigned { roles.removeValue(forKey: speakerID) } else { roles[speakerID] = role }
        try consultation.storeConversation(turns, roles: roles)
        invalidateSummary(consultation, patient: patient)
        try save(context)
    }

    public static func updateConversationTurn(context: ModelContext, consultation: Consultation, turnID: UUID,
                                              text: String, speakerID: String?) throws {
        let patient = try editablePatient(context: context, consultation: consultation)
        var turns = consultation.conversationTurns
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { throw ConsultationRecordError.unknownTurn }
        if let speakerID, !turns.contains(where: { $0.speakerID == speakerID }) { throw ConsultationRecordError.unknownSpeaker }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard turns[index].text != text || turns[index].speakerID != speakerID else { return }
        turns[index].text = text; turns[index].speakerID = speakerID
        try validateTurns(turns)
        let ids = Set(turns.compactMap(\.speakerID))
        try consultation.storeConversation(turns, roles: consultation.speakerRoles.filter { ids.contains($0.key) })
        consultation.transcript = turns.map(\.text).joined(separator: " ")
        invalidateSummary(consultation, patient: patient)
        try save(context)
    }

    /// Explicit GP correction is permitted even when no automatic speaker could be assigned.
    public static func assignTurnRole(context: ModelContext, consultation: Consultation, turnID: UUID, role: SpeakerRole) throws {
        let patient = try editablePatient(context: context, consultation: consultation)
        var turns = consultation.conversationTurns
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { throw ConsultationRecordError.unknownTurn }
        let speakerID: String? = role == .unassigned ? nil : "MANUAL_" + role.rawValue.uppercased()
        var roles = consultation.speakerRoles
        let mappedRole = speakerID.flatMap { roles[$0] } ?? .unassigned
        guard turns[index].speakerID != speakerID || mappedRole != role else { return }
        turns[index].speakerID = speakerID
        if let speakerID { roles[speakerID] = role }
        let ids = Set(turns.compactMap(\.speakerID))
        try consultation.storeConversation(turns, roles: roles.filter { ids.contains($0.key) })
        invalidateSummary(consultation, patient: patient)
        try save(context)
    }

    public static func setDiarizationStatus(context: ModelContext, consultation: Consultation, status: ConversationDiarizationStatus) throws {
        _ = try editablePatient(context: context, consultation: consultation)
        consultation.diarizationStatusRaw = status.rawValue
        try save(context)
    }

    private static func editablePatient(context: ModelContext, consultation: Consultation) throws -> Patient {
        let patient = try owningPatient(context: context, patientID: consultation.patientID, visitID: consultation.visitID)
        guard consultation.archivedAt == nil else { throw ConsultationRecordError.archived }
        guard consultation.endedAt != nil else { throw ConsultationRecordError.recordingNotStopped }
        return patient
    }
    private static func invalidateSummary(_ consultation: Consultation, patient: Patient) {
        consultation.transcriptRevision = UUID()
        consultation.draftSummary = ""; consultation.draftTranscriptRevision = nil
        consultation.approvedSummary = ""; consultation.approvedAt = nil; consultation.approvedTranscriptRevision = nil
        patient.revision = UUID()
    }
    private static func validateTurns(_ turns: [ConversationTurn]) throws {
        guard !turns.isEmpty, turns.count <= 100_000, Set(turns.map(\.id)).count == turns.count else { throw ConsultationRecordError.invalidConversation }
        var lastStart = -Double.infinity
        for turn in turns {
            guard !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.startSeconds.isFinite, turn.endSeconds.isFinite,
                  turn.startSeconds >= 0, turn.endSeconds >= turn.startSeconds,
                  turn.endSeconds <= 31_536_000, turn.startSeconds >= lastStart else { throw ConsultationRecordError.invalidConversation }
            if let speakerID = turn.speakerID {
                guard !speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, speakerID.count <= 128,
                      !speakerID.contains(where: { $0.isNewline }) else { throw ConsultationRecordError.invalidConversation }
            }
            lastStart = turn.startSeconds
        }
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
        guard consultation.diarizationStatus != .pending && consultation.diarizationStatus != .failed else {
            throw ConsultationRecordError.speakerAnalysisIncomplete
        }
        consultation.audioFileName = nil
        try save(context)
    }

    public static func approvedSummaries(context: ModelContext, patientID: UUID, visitID: UUID) throws -> [ConsultationSummarySnapshot] {
        _ = try owningPatient(context: context, patientID: patientID, visitID: visitID)
        let request = FetchDescriptor<Consultation>(predicate: #Predicate { $0.patientID == patientID && $0.visitID == visitID }, sortBy: [SortDescriptor(\.startedAt)])
        return try context.fetch(request).compactMap { $0.approvedSnapshot() }
    }

    private static func validateSummary(consultation: Consultation, text: String, transcriptRevision: UUID) throws {
        guard consultation.archivedAt == nil else { throw ConsultationRecordError.archived }
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
