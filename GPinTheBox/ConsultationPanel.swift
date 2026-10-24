import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftData
import Records
import Assistant
import ConsultationAudio

/// This view owns recording for one visit. Leaving the visit stops the microphone;
/// pending audio remains associated with the original visit for explicit recovery.
struct ConsultationPanel: View {
    let visit: Visit
    let model: AppModel
    @Environment(\.modelContext) private var context
    @Query private var consultations: [Consultation]
    @State private var recorder = ConsultationRecorder()
    @State private var locale = "en-AU"
    @State private var consent = false
    @State private var active: Consultation?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var working: String?
    @State private var error: String?
    @State private var showArchived = false
    @State private var showSpeechSettings = false
    @AppStorage("localSpeech.separateSpeakers") private var separateSpeakers = false
    /// iOS only: the recording pushed onto the navigation stack as a detail screen.
    @State private var openConsultationID: UUID?

    init(visit: Visit, model: AppModel) {
        self.visit = visit; self.model = model
        let visitID = visit.id
        _consultations = Query(filter: #Predicate<Consultation> { $0.visitID == visitID }, sort: \Consultation.startedAt, order: .reverse)
    }
    var body: some View {
        layout
        .sheet(isPresented: $showSpeechSettings) { SpeechSettingsView() }
        // Pushing a recording's detail screen hides this view without leaving the visit,
        // so only stop the microphone and processing when no detail screen is open.
        .onDisappear { if openConsultationID == nil { stopForBoundary() } }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
            if active != nil { model.microphoneIsRecording = isRecording }
            if wasRecording && !isRecording {
                if model.recordingVisitID == visit.id { model.recordingVisitID = nil }
                if let active, active.endedAt == nil {
                    active.wasInterrupted = true
                    do { try ConsultationMutations.markStopped(context: context, consultation: active) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .task {
            // Recover the narrow crash window after transcript save but before audio deletion.
            for consultation in consultations where consultation.archivedAt == nil && !consultation.transcript.isEmpty && consultation.audioFileName != nil && consultation.diarizationStatus != .pending && consultation.diarizationStatus != .failed {
                deleteSavedAudio(consultation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.willTerminateNotification)) { _ in stopForBoundary() }

    }
    #if canImport(AppKit)
    private static let willTerminateNotification = NSApplication.willTerminateNotification
    #else
    private static let willTerminateNotification = UIApplication.willTerminateNotification
    #endif
    private var visibleConsultations: [Consultation] { consultations.filter { showArchived || $0.archivedAt == nil } }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        // iOS: recording controls and a list of recordings; each recording opens as a detail screen.
        List {
            Section { controls } header: { Label("Consultation recording", systemImage: "waveform") }
            Section("Recordings") {
                Toggle("Show archived recordings", isOn: $showArchived)
                ForEach(visibleConsultations) { consultation in
                    Button { openConsultationID = consultation.id } label: {
                        HStack {
                            consultationRow(consultation)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isRecording)
                }
                if visibleConsultations.isEmpty {
                    Text("No recordings yet.").foregroundStyle(Color.careSecondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .scrollContentBackground(.hidden)
        .navigationDestination(item: $openConsultationID) { id in
            Group {
                if let consultation = consultations.first(where: { $0.id == id }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { consultationDetail(consultation) }
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(consultation.startedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash")
                }
            }
            .background(Color.careBackground)
            // Popping clears the selection first; disappearing while still selected means
            // the visit itself was removed, so apply the same cleanup as leaving the panel.
            .onDisappear { if openConsultationID != nil { stopForBoundary() } }
        }
        #else
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                controls
                Toggle("Show archived recordings", isOn: $showArchived)
                ForEach(visibleConsultations) { consultation in
                    VStack(alignment: .leading, spacing: 12) {
                        consultationRow(consultation)
                        consultationDetail(consultation)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.careAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Consultation recording", systemImage: "waveform") }
        #endif
    }

    /// Top-level views become separate rows in the iOS list and stack vertically on macOS.
    @ViewBuilder private var controls: some View {
        Text("Record once the patient is seated with the doctor. Transcription and summaries run on this Mac. Audio is deleted after the transcript and requested speaker analysis are saved.")
            .font(.callout).foregroundStyle(Color.careSecondary)
        HStack {
            Picker("Spoken English", selection: $locale) {
                Text("English (Australia)").tag("en-AU")
                Text("English (US)").tag("en-US")
            }.frame(maxWidth: 310).disabled(working != nil || recorder.isRecording)
            Spacer()
            if recorder.isRecording {
                Label("Recording · \(elapsed)", systemImage: "record.circle.fill").foregroundStyle(.red).font(.headline).accessibilityLabel("Recording in progress")
                Button("Stop & transcribe") { stopAndTranscribe() }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button { startRecording() } label: { Label(consultations.isEmpty ? "Start recording" : "Record again", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).tint(Color.careAccent)
                    .disabled(!consent || working != nil || model.recordingVisitID != nil || visit.status == .done)
            }
        }
        if !recorder.isRecording {
            Toggle("The patient has agreed to this consultation being recorded.", isOn: $consent)
                .disabled(working != nil || visit.status == .done)
            if visit.status == .done { Text("This visit is finished. Recording is available during an active consultation.").font(.caption).foregroundStyle(Color.careSecondary) }
        }
        HStack {
            Button("Speech glossary & setup…") { showSpeechSettings = true }
            Toggle("Separate speakers locally (Core ML)", isOn: $separateSpeakers)
        }.disabled(working != nil || recorder.isRecording)
        if separateSpeakers {
            Text("Download the speaker model once in Speech glossary & setup. Speaker labels are estimates; assign Doctor and Patient after checking the conversation.").font(.caption).foregroundStyle(Color.careSecondary)
        }
        if let working {
            HStack { ProgressView().controlSize(.small); Text(working); Button("Cancel") { cancelOperation() } }
        }
        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
        if let recordingError = recorder.lastError { Text(recordingError).foregroundStyle(.orange) }
        if !consultations.isEmpty && !recorder.isRecording {
            Text("Record again starts a new attempt, even if the previous one was archived. Check patient agreement first. Re-record archives an existing attempt before starting fresh.")
                .font(.caption).foregroundStyle(Color.careSecondary)
        }
    }

    private func consultationRow(_ consultation: Consultation) -> some View {
        HStack {
            Text(consultation.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            Text(consultation.localeIdentifier == "en-US" ? "English (US)" : "English (Australia)").font(.caption).foregroundStyle(Color.careSecondary)
            Spacer()
            #if os(iOS)
            if consultation.archivedAt != nil { Label("Archived", systemImage: "archivebox").foregroundStyle(Color.careSecondary) }
            #endif
            if consultation.approvedSnapshot() != nil { Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(Color.careAccent) }
        }
    }

    @ViewBuilder private func consultationDetail(_ consultation: Consultation) -> some View {
        if consultation.archivedAt != nil {
            Label("Archived — excluded from patient summaries and answers", systemImage: "archivebox")
            Button("Restore recording") { setArchived(consultation, archived: false) }
                .disabled(working != nil || recorder.isRecording)
            if !consultation.transcript.isEmpty {
                DisclosureGroup("Archived transcript and summary") {
                    Text(consultation.transcript).textSelection(.enabled)
                    Text(consultation.approvedSummary.isEmpty ? consultation.draftSummary : consultation.approvedSummary).textSelection(.enabled)
                }
            }
        } else {
            HStack {
                Button("Re-record") { rerecord(consultation) }
                    .disabled(!consent || model.recordingVisitID != nil || visit.status == .done)
                Button("Delete (archive)") { setArchived(consultation, archived: true) }
                Text("Keeps saved content. You can restore it or start a new recording.").font(.caption).foregroundStyle(Color.careSecondary)
            }.disabled(working != nil || recorder.isRecording)
            if consultation.wasInterrupted {
                Text("This recording ended early or was interrupted. Its transcript may cover only part of the consultation.").font(.caption).foregroundStyle(.orange)
            }
            if consultation.transcript.isEmpty {
                if active?.id != consultation.id || !recorder.isRecording {
                    Text(consultation.endedAt == nil ? "Recording interrupted or not started. Any captured audio is retained for recovery." : "Audio retained until transcription is saved.").foregroundStyle(Color.careSecondary)
                    HStack {
                        Button("Transcribe recording") { transcribe(consultation) }.disabled(working != nil || recorder.isRecording)
                    }
                }
            } else {
                ConsultationReview(consultation: consultation, model: model)
                    .disabled(working != nil || recorder.isRecording || consultation.diarizationStatus == .pending || consultation.diarizationStatus == .failed)
                if consultation.audioFileName != nil {
                    if consultation.diarizationStatus == .pending || consultation.diarizationStatus == .failed {
                        Text("Transcript saved. Speaker separation is incomplete; audio is retained for retry.").font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("Retry speaker separation") { retrySpeakers(consultation) }.disabled(consultation.conversationTurns.isEmpty)
                            Button("Keep transcript only & delete audio") { skipSpeakers(consultation) }
                        }.disabled(working != nil || recorder.isRecording)
                    } else {
                        Text("The transcript is saved, but audio cleanup is still pending.").font(.caption).foregroundStyle(.orange)
                        Button("Delete saved audio") { deleteSavedAudio(consultation) }.disabled(working != nil || recorder.isRecording)
                    }
                } else { Text("Transcript saved · original audio deleted").font(.caption).foregroundStyle(Color.careSecondary) }
            }
        }
        #if os(iOS)
        // Processing progress and errors also show here, since the controls are a screen back.
        if let working {
            HStack { ProgressView().controlSize(.small); Text(working); Button("Cancel") { cancelOperation() } }
        }
        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
        #endif
    }

    private var elapsed: String { String(format: "%02d:%02d", Int(recorder.duration) / 60, Int(recorder.duration) % 60) }
    private func startRecording() {
        guard consent, visit.status != .done, model.recordingVisitID == nil, let patient = visit.patient else { return }
        model.recordingVisitID = visit.id
        error = nil; working = "Preparing microphone…"
        let requestID = UUID(); operationID = requestID
        operation = Task { @MainActor in
            do {
                let filename = UUID().uuidString + ".caf"
                let url = try ConsultationAudioFiles.url(fileName: filename)
                let consultation = try ConsultationMutations.create(context: context, patientID: patient.id, visitID: visit.id, localeIdentifier: locale, audioFileName: filename)
                active = consultation
                try await recorder.start(url: url)
                try Task.checkCancellation()
            } catch {
                guard operationID == requestID else { return }
                if recorder.isRecording { _ = try? recorder.stop() }
                if let active { try? ConsultationMutations.markStopped(context: context, consultation: active) }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                if model.recordingVisitID == visit.id { model.recordingVisitID = nil }
            }
            if operationID == requestID { working = nil }
        }
    }
    private func stopAndTranscribe() {
        guard let active else { return }
        do {
            _ = try recorder.stop()
            try ConsultationMutations.markStopped(context: context, consultation: active)
            if model.recordingVisitID == visit.id { model.recordingVisitID = nil }
            consent = false
            transcribe(active)
        } catch {
            self.error = error.localizedDescription
            if model.recordingVisitID == visit.id { model.recordingVisitID = nil }
        }
    }
    private func stopForBoundary() {
        operationID = UUID(); operation?.cancel(); operation = nil
        _ = try? recorder.stop()
        if let active, active.endedAt == nil { active.wasInterrupted = true; try? ConsultationMutations.markStopped(context: context, consultation: active) }
        if model.recordingVisitID == visit.id { model.recordingVisitID = nil; model.microphoneIsRecording = false }
        working = nil; consent = false
    }
    private func cancelOperation() { stopForBoundary(); error = "Processing cancelled. Any unsaved recording stays with this visit so you can retry." }
    private func transcribe(_ consultation: Consultation) {
        guard !recorder.isRecording, consultation.transcript.isEmpty else { return }
        let requestID = UUID(); operationID = requestID
        let wantsSpeakers = separateSpeakers
        operation?.cancel(); error = nil; working = "Transcribing on this Mac. Speech assets may need to download first…"
        operation = Task { @MainActor in
            do {
                guard let filename = consultation.audioFileName else { throw ConsultationRecordError.invalidAudioFileName }
                let url = try ConsultationAudioFiles.url(fileName: filename)
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                if consultation.endedAt == nil { consultation.wasInterrupted = true }
                try ConsultationMutations.markStopped(context: context, consultation: consultation)
                let glossary = try SpeechGlossaryStore().load()
                let result = try await OnDeviceTranscriber().transcribeDetailed(url: url, localeIdentifier: consultation.localeIdentifier, glossary: glossary)
                try Task.checkCancellation()
                guard operationID == requestID else { return }
                let turns = result.segments.map { ConversationTurn(id: $0.id, text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
                // Commit text and pending speaker state together before further work or audio deletion.
                try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: wantsSpeakers ? turns : groupedTurns(turns),
                    diarizationStatus: wantsSpeakers ? .pending : .notRequested)
                if wantsSpeakers {
                    working = "Separating speakers locally…"
                    try await separate(consultation, audioURL: url, requestID: requestID)
                }
                deleteSavedAudio(consultation)
                try await generateInitialDraft(consultation, requestID: requestID)

            } catch {
                if operationID == requestID, !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if operationID == requestID { working = nil }
        }
    }
    private func groupedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var grouped: [ConversationTurn] = []
        for turn in turns {
            if let last = grouped.last, last.speakerID == turn.speakerID,
               turn.startSeconds - last.endSeconds < 1.5, turn.endSeconds - last.startSeconds < 20 {
                grouped[grouped.count - 1].text += " " + turn.text
                grouped[grouped.count - 1].endSeconds = max(last.endSeconds, turn.endSeconds)
            } else { grouped.append(turn) }
        }
        return grouped
    }
    private func separate(_ consultation: Consultation, audioURL: URL, requestID: UUID) async throws {
        let revision = consultation.transcriptRevision
        let turns = consultation.conversationTurns
        do {
            let intervals = try await LocalSpeechSettings.diarize(audioURL)
            try Task.checkCancellation()
            guard operationID == requestID, consultation.transcriptRevision == revision else { throw CancellationError() }
            let mapped = turns.map { turn -> ConversationTurn in
                var mapped = turn
                mapped.speakerID = SpeakerAlignment.speakerID(startSeconds: turn.startSeconds, endSeconds: turn.endSeconds, intervals: intervals)
                return mapped
            }
            try ConsultationMutations.saveConversation(context: context, consultation: consultation, turns: groupedTurns(mapped), diarizationStatus: .completed)
        } catch {
            if operationID == requestID, consultation.archivedAt == nil {
                try? ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: .failed)
            }
            throw error
        }
    }
    private func retrySpeakers(_ consultation: Consultation) {
        guard working == nil, !recorder.isRecording, !consultation.conversationTurns.isEmpty else { return }
        let requestID = UUID(); operationID = requestID
        error = nil; working = "Separating speakers locally…"
        operation = Task { @MainActor in
            do {
                guard let filename = consultation.audioFileName else { throw ConsultationRecordError.invalidAudioFileName }
                try ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: .pending)
                try await separate(consultation, audioURL: ConsultationAudioFiles.url(fileName: filename), requestID: requestID)
                deleteSavedAudio(consultation)
                try await generateInitialDraft(consultation, requestID: requestID)
            } catch { if operationID == requestID, !(error is CancellationError) { self.error = error.localizedDescription } }
            if operationID == requestID { working = nil }
        }
    }
    private func skipSpeakers(_ consultation: Consultation) {
        guard working == nil, !recorder.isRecording else { return }
        do {
            try ConsultationMutations.setDiarizationStatus(context: context, consultation: consultation, status: .skipped)
            deleteSavedAudio(consultation)
        } catch { self.error = error.localizedDescription }
    }
    private func generateInitialDraft(_ consultation: Consultation, requestID: UUID) async throws {
        try Task.checkCancellation()
        guard operationID == requestID else { throw CancellationError() }
        working = "Creating a draft summary on this Mac…"
        let revision = consultation.transcriptRevision
        let result = try await ConsultationSummarizer(model: FoundationModelsAssistant()).summarize(transcript: consultation.conversationText, consultationID: consultation.id, date: consultation.startedAt)
        try Task.checkCancellation()
        guard operationID == requestID else { throw CancellationError() }
        try ConsultationMutations.saveDraft(context: context, consultation: consultation, text: result.claims.map(\.text).joined(separator: "\n\n"), transcriptRevision: revision)
    }
    private func deleteSavedAudio(_ consultation: Consultation) {
        guard !consultation.transcript.isEmpty, consultation.diarizationStatus != .pending, consultation.diarizationStatus != .failed, let filename = consultation.audioFileName else { return }
        do {
            let url = try ConsultationAudioFiles.url(fileName: filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
        } catch { self.error = "Transcript saved; audio cleanup needs retry: \(error.localizedDescription)" }
    }
    private func rerecord(_ consultation: Consultation) {
        guard consent, working == nil, !recorder.isRecording,
              model.recordingVisitID == nil, visit.status != .done else { return }
        do {
            if consultation.endedAt == nil {
                consultation.wasInterrupted = true
                try ConsultationMutations.markStopped(context: context, consultation: consultation)
            }
            try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: true)
            openConsultationID = nil // iOS: return to the recording controls
            startRecording()
        } catch { self.error = error.localizedDescription }
    }
    private func setArchived(_ consultation: Consultation, archived: Bool) {
        guard working == nil, !recorder.isRecording else { return }
        do {
            if archived && consultation.endedAt == nil {
                consultation.wasInterrupted = true
                try ConsultationMutations.markStopped(context: context, consultation: consultation)
            }
            try ConsultationMutations.setArchived(context: context, consultation: consultation, archived: archived)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

}

struct ConsultationReview: View {
    @Bindable var consultation: Consultation
    let model: AppModel
    @Environment(\.modelContext) private var context
    @State private var transcriptEdit = ""
    @State private var summaryEdit = ""
    @State private var reviewed = false
    @State private var generating = false
    @State private var error: String?
    @State private var evidence: CitedText?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !consultation.conversationTurns.isEmpty {
                ConversationView(consultation: consultation).disabled(generating)
            }
            DisclosureGroup("Saved consultation transcript") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automated combined transcript. Speaker identities are not inferred. Correct any transcription errors before approving a summary.").font(.caption).foregroundStyle(Color.careSecondary)
                    TextEditor(text: $transcriptEdit).font(.body).frame(minHeight: 180)
                    Button("Save transcript corrections") { saveTranscript() }
                        .disabled(generating || transcriptEdit == consultation.transcript || transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if transcriptEdit != consultation.transcript { Text("Saving the combined transcript clears speaker timing, draft, and approval. Use conversation turn edits above to preserve speaker labels.").font(.caption).foregroundStyle(.orange) }
                }.padding(.top, 8)
            }
            HStack {
                Text(consultation.approvedSnapshot() == nil ? "Draft consultation summary" : "Approved consultation summary").font(.headline)
                Spacer()
                Button(consultation.draftSummary.isEmpty ? "Generate draft summary" : "Regenerate draft") { generate() }
                    .disabled(generating || transcriptEdit != consultation.transcript)
                if generating { ProgressView().controlSize(.small); Button("Cancel") { operationID = UUID(); operation?.cancel(); generating = false } }
            }
            TextEditor(text: $summaryEdit).font(.body).frame(minHeight: 160)
                .accessibilityLabel("Consultation summary draft")
                .onChange(of: summaryEdit) { _, _ in reviewed = false }
            if let evidence { DisclosureGroup("Generated evidence — verify against the transcript") { CitedTextView(text: evidence) } }
            Text("Only the doctor-approved summary is included in future visit summaries and record questions. The full transcript stays in this visit’s history.").font(.caption).foregroundStyle(Color.careSecondary)
            Toggle("I have checked and corrected this summary against the consultation.", isOn: $reviewed)
            HStack {
                Button("Save draft") { saveDraft() }.disabled(generating || summaryEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptEdit != consultation.transcript)
                Button("Approve & save to patient record") { approve() }.buttonStyle(.borderedProminent).tint(Color.careAccent)
                    .disabled(!reviewed || generating || summaryEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptEdit != consultation.transcript)
            }
            if let approvedAt = consultation.approvedAt, consultation.approvedSnapshot() != nil {
                Text("Approved \(approvedAt.formatted(date: .abbreviated, time: .shortened)). Available in future visits.").font(.caption).foregroundStyle(Color.careAccent)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .onAppear { load() }
        .onChange(of: consultation.transcriptRevision) { _, _ in operationID = UUID(); operation?.cancel(); generating = false; evidence = nil; load() }
        .onChange(of: consultation.draftSummary) { old, new in if summaryEdit == old || summaryEdit.isEmpty { summaryEdit = new } }
        .onDisappear { operationID = UUID(); operation?.cancel() }
    }
    private func load() { transcriptEdit = consultation.transcript; summaryEdit = consultation.draftSummary; reviewed = false }
    private func saveTranscript() {
        do { try ConsultationMutations.saveTranscript(context: context, consultation: consultation, text: transcriptEdit); load(); evidence = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func saveDraft() {
        do { try ConsultationMutations.saveDraft(context: context, consultation: consultation, text: summaryEdit, transcriptRevision: consultation.transcriptRevision); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func approve() {
        guard reviewed else { return }
        do { try ConsultationMutations.approveSummary(context: context, consultation: consultation, text: summaryEdit, transcriptRevision: consultation.transcriptRevision); reviewed = false; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func generate() {
        let requestID = UUID(); operationID = requestID
        operation?.cancel(); generating = true; reviewed = false; error = nil; model.refreshAvailability()
        let transcript = consultation.conversationText, revision = consultation.transcriptRevision
        operation = Task { @MainActor in
            do {
                let result = try await ConsultationSummarizer(model: FoundationModelsAssistant()).summarize(transcript: transcript, consultationID: consultation.id, date: consultation.startedAt)
                try Task.checkCancellation()
                guard operationID == requestID else { return }
                guard consultation.transcriptRevision == revision else { throw ConsultationRecordError.staleTranscript }
                let draft = result.claims.map(\.text).joined(separator: "\n\n")
                try ConsultationMutations.saveDraft(context: context, consultation: consultation, text: draft, transcriptRevision: revision)
                evidence = result; summaryEdit = draft
            } catch { if operationID == requestID, !(error is CancellationError) { self.error = error.localizedDescription } }
            if operationID == requestID { generating = false }
        }
    }
}
