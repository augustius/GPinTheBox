import SwiftUI
import ConsultationAudio

@MainActor enum LocalSpeechSettings {
    static func diarize(_ audioURL: URL) async throws -> [SpeakerInterval] {
        try await NativeSpeakerDiarizer().diarize(audioURL: audioURL)
    }
}

struct SpeechSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var terms = ""
    @State private var installed = false
    @State private var preparing = false
    @State private var preparation: Task<Void, Never>?
    @State private var preparationID = UUID()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speech glossary & speaker setup").font(.title2.bold())
            Text("Glossary: one short term per line, up to 100 unique terms. Used as hints by Apple’s on-device dictation engine; recognition is not guaranteed.").foregroundStyle(.secondary)
            TextEditor(text: $terms).font(.body).frame(minHeight: 160).accessibilityLabel("Speech glossary terms")
            Text("Add terms that were repeatedly misheard, then compare fresh synthetic recordings. Changes apply to the next transcription, not saved records.").font(.caption)
            Divider()
            Text("Local speaker separation (Core ML)").font(.headline)
            Text("Runs on this Mac using FluidAudio and a third-party Sortformer model. No Python or account required. The one-time download contains model files only; consultation audio is never uploaded.").font(.callout)
            HStack {
                Label(installed ? "Speaker model installed" : "Speaker model not installed", systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Spacer()
                if preparing {
                    ProgressView().controlSize(.small)
                    Button("Cancel download") { cancelPreparation() }
                } else {
                    Button(installed ? "Verify model" : "Download speaker model") { prepare() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if preparing { Text("Downloading and preparing the model. The first load may take a few minutes.").font(.caption).foregroundStyle(.secondary) }
            Text("After recording, assign the detected voices to Doctor and Patient. Speaker labels may be wrong around overlapping speech; check the conversation before approving its summary.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Save glossary") {
                    do {
                        try SpeechGlossaryStore().save(terms.components(separatedBy: .newlines))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 650)
        .onAppear {
            do { terms = try SpeechGlossaryStore().load().joined(separator: "\n") }
            catch { self.error = error.localizedDescription }
            installed = NativeSpeakerDiarizer().isModelInstalled
        }
        .onDisappear { cancelPreparation() }
    }
    private func prepare() {
        guard !preparing else { return }
        preparing = true; error = nil
        let requestID = UUID(); preparationID = requestID
        preparation = Task { @MainActor in
            do {
                try await NativeSpeakerDiarizer().prepareModels()
                try Task.checkCancellation()
                guard preparationID == requestID else { return }
                installed = NativeSpeakerDiarizer().isModelInstalled
            } catch { if preparationID == requestID, !(error is CancellationError) { self.error = error.localizedDescription } }
            if preparationID == requestID { preparing = false }
        }
    }
    private func cancelPreparation() {
        preparationID = UUID(); preparation?.cancel(); preparation = nil; preparing = false
        installed = NativeSpeakerDiarizer().isModelInstalled
    }
}
