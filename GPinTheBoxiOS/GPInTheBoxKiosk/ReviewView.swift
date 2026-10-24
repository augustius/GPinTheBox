import SwiftUI
import KioskKit

struct ReviewView: View {
    let controller: KioskController
    @State private var editing: EditTarget?

    var body: some View {
        VStack(spacing: 16) {
            Text("Please check your answers").font(.largeTitle.bold())
            if let error = controller.lastError {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            List(controller.flow.questions) { q in
                Button { editing = EditTarget(id: q.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.text).font(.headline)
                        let answer = controller.flow.answers[q.id]
                        Text(display(answer, isDOB: q.kind == .dateOfBirth))
                            .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                    }
                }
                .tint(.primary)
            }
            if !controller.flow.canSend {
                Text("Name, ID and a valid date of birth (YYYY-MM-DD) are needed to send.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { controller.send() } label: { Text("Send to clinic").font(.title2.bold()).frame(maxWidth: 400) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.flow.canSend)
        }
        .padding()
        .stillThereAlert(controller, enabled: editing == nil)
        .sheet(item: $editing) { EditAnswerSheet(controller: controller, index: $0.id).stillThereAlert(controller) }
    }

    private func display(_ answer: String, isDOB: Bool) -> String {
        if answer.isEmpty { return "Not answered" }
        return isDOB ? AnswerFormatting.readableDOB(answer) ?? answer : answer
    }
}

private struct EditTarget: Identifiable { let id: Int }

private struct EditAnswerSheet: View {
    let controller: KioskController
    let index: Int
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                AnswerField(kind: controller.flow.questions[index].kind, placeholder: "Answer", text: $text) { save() }
                    .font(.title3)
                if controller.inputMode == .voice {
                    Button(controller.isListening ? "Listening…" : "Speak again") { controller.respeak(index) }
                        .disabled(controller.isListening)
                    if controller.isListening { Button("Done") { controller.finishAnswer() }.bold() }
                    if !controller.caption.isEmpty && controller.isListening { Text(controller.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(controller.flow.questions[index].text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .onAppear { text = controller.flow.answers[index] }
        .onChange(of: controller.flow.answers[index]) { text = controller.flow.answers[index] }
        .onChange(of: text) {
            controller.noteActivity()
            // Typing replaces a re-record in progress, so what the mic hears later can't overwrite the draft.
            if text != controller.flow.answers[index] { controller.cancelRespeak() }
        }
        .onDisappear { controller.cancelRespeak() }
    }

    private func save() { controller.edit(index, to: text); dismiss() }
}
