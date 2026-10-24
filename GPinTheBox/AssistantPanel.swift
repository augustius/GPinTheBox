import SwiftUI
import Records
import Assistant

struct ChatEntry: Identifiable { let id = UUID(); var question: String; var answer: CitedText }
struct AssistantPanel: View {
    let patient: PatientSnapshot; let visitID: UUID; let model: AppModel
    @State private var gate = GenerationGate()
    @State private var task: Task<Void, Never>?
    @State private var summary: PatientSummary?
    @State private var history: [ChatEntry] = []
    @State private var question = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                Text("Generated on this Mac, only when you ask. Check every claim against its source; matching citations do not prove accuracy.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { runSummary() } label: { Label("Summarise", systemImage: "sparkles") }.buttonStyle(.borderedProminent).tint(.teal).disabled(busy)
                    if busy { ProgressView().controlSize(.small); Button("Cancel") { invalidate(clear: false) } }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let summary {
                    if summary.incompleteFollowUps { Text("Some follow-up checks could not be completed. Review the original GP note and today’s intake.").foregroundStyle(.orange) }
                    if !summary.followUps.isEmpty {
                        Text("Follow-ups from last visit").font(.headline)
                        ForEach(summary.followUps) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.item).fontWeight(.medium)
                                SourceView(chunk: item.noteSource)
                                switch item.status {
                                case .notMentioned: Text("Not mentioned").foregroundStyle(.secondary)
                                case .mentioned(let chunks):
                                    Text("Mentioned in today’s intake · completion not assessed").foregroundStyle(.teal)
                                    ForEach(chunks) { SourceView(chunk: $0) }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text("Summary").font(.headline)
                    CitedTextView(text: summary.overview)
                }
                Divider()
                Text("Ask the record").font(.headline)
                HStack {
                    TextField("For example: What was reported at the last visit?", text: $question).textFieldStyle(.roundedBorder).onSubmit { if !busy { runQuestion() } }
                    Button("Ask") { runQuestion() }.disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Each question searches the record independently. Chat is cleared when you change patients or edit the record.").font(.caption).foregroundStyle(.secondary)
                ForEach(history) { entry in
                    Text(entry.question).fontWeight(.semibold)
                    CitedTextView(text: entry.answer)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("On-device assistant", systemImage: "sparkles") }
        .onChange(of: patient) { _, _ in invalidate(clear: true) }
        .onDisappear { invalidate(clear: true) }
    }
    private func invalidate(clear: Bool) {
        task?.cancel(); task = nil; gate.invalidate(); busy = false
        if clear { summary = nil; history = []; error = nil; question = "" }
    }
    private func begin() -> GenerationIdentity {
        task?.cancel()
        let identity = GenerationIdentity(patientID: patient.id, visitID: visitID, revision: patient.revision)
        gate.begin(identity); busy = true; error = nil; model.refreshAvailability()
        return identity
    }
    private func runSummary() {
        let identity = begin(), snapshot = patient
        task = Task { @MainActor in
            do {
                let result = try await Summarizer(model: FoundationModelsAssistant()).summarize(snapshot, visitID: visitID)
                guard !Task.isCancelled, gate.accepts(identity) else { return }
                summary = result
            } catch { if gate.accepts(identity), !Task.isCancelled { self.error = error.localizedDescription } }
            if gate.accepts(identity) { busy = false }
        }
    }
    private func runQuestion() {
        let input = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let identity = begin(), snapshot = patient
        task = Task { @MainActor in
            do {
                let embedder = await model.prepareEmbedder()
                try Task.checkCancellation()
                let result = try await QAService(model: FoundationModelsAssistant(), retriever: Retriever(embedder: embedder)).answer(input, patient: snapshot)
                guard !Task.isCancelled, gate.accepts(identity) else { return }
                history.append(ChatEntry(question: input, answer: result)); question = ""
            } catch { if gate.accepts(identity), !Task.isCancelled { self.error = error.localizedDescription } }
            if gate.accepts(identity) { busy = false }
        }
    }
}
struct CitedTextView: View {
    let text: CitedText
    var body: some View {
        if text.isNotFound { Text("Not found in the supplied record excerpts.").foregroundStyle(.secondary) }
        ForEach(text.claims) { claim in
            VStack(alignment: .leading, spacing: 8) {
                Text(claim.text).textSelection(.enabled)
                ForEach(Array(claim.sources.enumerated()), id: \.offset) { _, chunk in SourceView(chunk: chunk) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
struct SourceView: View {
    let chunk: Chunk
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showing.toggle() } label: { Text("[\(chunk.id)] \(chunk.source.label) · \(chunk.date.formatted(date: .abbreviated, time: .omitted))").font(.caption.weight(.medium)) }.buttonStyle(.link)
                .popover(isPresented: $showing) { VStack(alignment: .leading, spacing: 8) { Text(chunk.source.label).font(.headline); Text(chunk.date, style: .date); Text(chunk.text).textSelection(.enabled) }.padding().frame(width: 360) }
            Text(chunk.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
