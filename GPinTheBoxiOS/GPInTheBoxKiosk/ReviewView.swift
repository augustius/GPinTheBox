import SwiftUI
import KioskKit
import KioskProtocol

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
                // A plain tap target: the root activity TapGesture swallows List row Buttons.
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.text).font(.headline)
                    let answer = controller.flow.answers[q.id]
                    Text(display(answer, isDOB: q.kind == .dateOfBirth))
                        .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editing = EditTarget(id: q.id) }
                .accessibilityAddTraits(.isButton)
            }
            if !controller.flow.canSend {
                Text("Name, ID and a valid date of birth (YYYY-MM-DD) are needed to send.").font(.footnote).foregroundStyle(.secondary)
            }
            Button { controller.send() } label: { Text("Send to clinic").font(.title2.bold()).frame(maxWidth: 400) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.flow.canSend)
        }
        .padding()
        .sheet(item: $editing) { EditAnswerSheet(controller: controller, index: $0.id) }
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
                TextField("Answer", text: $text, axis: .vertical).font(.title3)
                if controller.inputMode == .voice {
                    Button(controller.isListening ? "Listening…" : "Speak again") { controller.respeak(index) }
                        .disabled(controller.isListening)
                    if !controller.caption.isEmpty && controller.isListening { Text(controller.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(controller.flow.questions[index].text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { controller.edit(index, to: text); dismiss() } }
            }
        }
        .onAppear { text = controller.flow.answers[index] }
        .onChange(of: controller.flow.answers[index]) { text = controller.flow.answers[index] }
        .onChange(of: text) { controller.noteActivity() }
    }
}
