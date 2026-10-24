import SwiftUI
import SwiftData
import Records
import Assistant
import ConsultationAudio

/// This view owns recording for one visit. Moving away always stops the microphone;
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
    @State private var discarded: Consultation?

    init(visit: Visit, model: AppModel) {
        self.visit = visit; self.model = model
        let visitID = visit.id
        _consultations = Query(filter: #Predicate<Consultation> { $0.visitID == visitID }, sort: \Consultation.startedAt, order: .reverse)
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record once the patient is seated with the doctor. Transcription and summaries run on this Mac. Audio is deleted after the transcript is saved.")
                    .font(.callout).foregroundStyle(.secondary)
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
                        Button { startRecording() } label: { Label("Start recording", systemImage: "mic.fill") }
                            .buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(!consent || working != nil || model.recordingVisitID != nil || visit.status == .done)
                    }
                }
                if !recorder.isRecording {
                    Toggle("The patient has agreed to this consultation being recorded.", isOn: $consent)
                        .disabled(working != nil || visit.status == .done)
                    if visit.status == .done { Text("This visit is finished. Recording is available during an active consultation.").font(.caption).foregroundStyle(.secondary) }
                }
                if let working {
                    HStack { ProgressView().controlSize(.small); Text(working); Button("Cancel") { cancelOperation() } }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let recordingError = recorder.lastError { Text(recordingError).foregroundStyle(.orange) }
                ForEach(consultations) { consultation in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(consultation.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(consultation.localeIdentifier == "en-US" ? "English (US)" : "English (Australia)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if consultation.approvedSnapshot() != nil { Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.teal) }
                        }
                        if consultation.wasInterrupted {
                            Text("This recording ended early or was interrupted. Its transcript may cover only part of the consultation.").font(.caption).foregroundStyle(.orange)
                        }
                        if consultation.transcript.isEmpty {
                            if active?.id != consultation.id || !recorder.isRecording {
                                Text(consultation.endedAt == nil ? "Recording interrupted or not started. Any captured audio is retained for recovery." : "Audio retained until transcription is saved.").foregroundStyle(.secondary)
                                HStack {
                                    Button("Transcribe recording") { transcribe(consultation) }.disabled(working != nil || recorder.isRecording)
                                    Button("Discard recording", role: .destructive) { discarded = consultation }.disabled(working != nil || recorder.isRecording)
                                }
                            }
                        } else {
                            ConsultationReview(consultation: consultation, model: model)
                                .disabled(working != nil || recorder.isRecording)
                            if consultation.audioFileName != nil {
                                Text("The transcript is saved, but audio cleanup is still pending.").font(.caption).foregroundStyle(.orange)
                                Button("Delete saved audio") { deleteSavedAudio(consultation) }.disabled(working != nil)
                            } else { Text("Transcript saved · original audio deleted").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Consultation recording", systemImage: "waveform") }
        .onDisappear { stopForBoundary() }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
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
            for consultation in consultations where !consultation.transcript.isEmpty && consultation.audioFileName != nil {
                deleteSavedAudio(consultation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in stopForBoundary() }
        .alert("Discard this recording?", isPresented: Binding(get: { discarded != nil }, set: { if !$0 { discarded = nil } })) {
            Button("Keep recording", role: .cancel) { discarded = nil }
            Button("Discard", role: .destructive) { if let discarded { discard(discarded) }; discarded = nil }
        } message: { Text("This removes the unsaved audio and the empty recording attempt. It cannot be recovered.") }
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
        if model.recordingVisitID == visit.id { model.recordingVisitID = nil }
        working = nil; consent = false
    }
    private func cancelOperation() { stopForBoundary(); error = "Processing cancelled. Any unsaved recording stays with this visit so you can retry." }
    private func transcribe(_ consultation: Consultation) {
        guard !recorder.isRecording, consultation.transcript.isEmpty else { return }
        let requestID = UUID(); operationID = requestID
        operation?.cancel(); error = nil; working = "Transcribing on this Mac. Speech assets may need to download first…"
        operation = Task { @MainActor in
            do {
                guard let filename = consultation.audioFileName else { throw ConsultationRecordError.invalidAudioFileName }
                let url = try ConsultationAudioFiles.url(fileName: filename)
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                if consultation.endedAt == nil { consultation.wasInterrupted = true }
                try ConsultationMutations.markStopped(context: context, consultation: consultation)
                let transcript = try await OnDeviceTranscriber().transcribe(url: url, localeIdentifier: consultation.localeIdentifier)
                try Task.checkCancellation()
                // This save must succeed before any file deletion.
                try ConsultationMutations.saveTranscript(context: context, consultation: consultation, text: transcript)
                deleteSavedAudio(consultation)
                try Task.checkCancellation()
                working = "Creating a draft summary on this Mac…"
                let revision = consultation.transcriptRevision
                let result = try await ConsultationSummarizer(model: FoundationModelsAssistant()).summarize(transcript: transcript, consultationID: consultation.id, date: consultation.startedAt)
                try Task.checkCancellation()
                let draft = result.claims.map { $0.text }.joined(separator: "\n\n")
                try ConsultationMutations.saveDraft(context: context, consultation: consultation, text: draft, transcriptRevision: revision)
            } catch {
                if operationID == requestID, !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if operationID == requestID { working = nil }
        }
    }
    private func deleteSavedAudio(_ consultation: Consultation) {
        guard !consultation.transcript.isEmpty, let filename = consultation.audioFileName else { return }
        do {
            let url = try ConsultationAudioFiles.url(fileName: filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try ConsultationMutations.markAudioDeleted(context: context, consultation: consultation)
        } catch { self.error = "Transcript saved; audio cleanup needs retry: \(error.localizedDescription)" }
    }
    private func discard(_ consultation: Consultation) {
        guard consultation.transcript.isEmpty, !recorder.isRecording else { return }
        do {
            if let filename = consultation.audioFileName {
                let url = try ConsultationAudioFiles.url(fileName: filename)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            context.delete(consultation); try context.save()
        } catch { context.rollback(); self.error = error.localizedDescription }
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
            DisclosureGroup("Saved consultation transcript") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automated combined transcript. Speaker identities are not inferred. Correct any transcription errors before approving a summary.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $transcriptEdit).font(.body).frame(minHeight: 180)
                    Button("Save transcript corrections") { saveTranscript() }
                        .disabled(generating || transcriptEdit == consultation.transcript || transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if transcriptEdit != consultation.transcript { Text("Saving corrections clears the previous draft and approval; the summary must be reviewed again.").font(.caption).foregroundStyle(.orange) }
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
            Text("Only the doctor-approved summary is included in future visit summaries and record questions. The full transcript stays in this visit’s history.").font(.caption).foregroundStyle(.secondary)
            Toggle("I have checked and corrected this summary against the consultation.", isOn: $reviewed)
            HStack {
                Button("Save draft") { saveDraft() }.disabled(generating || summaryEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptEdit != consultation.transcript)
                Button("Approve & save to patient record") { approve() }.buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!reviewed || generating || summaryEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptEdit != consultation.transcript)
            }
            if let approvedAt = consultation.approvedAt, consultation.approvedSnapshot() != nil {
                Text("Approved \(approvedAt.formatted(date: .abbreviated, time: .shortened)). Available in future visits.").font(.caption).foregroundStyle(.teal)
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
        let transcript = consultation.transcript, revision = consultation.transcriptRevision
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
