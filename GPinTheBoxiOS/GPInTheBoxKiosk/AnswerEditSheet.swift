import SwiftUI
import KioskKit

/// Edits one answer, from a chip or a review row. In review and voice mode the answer can also be spoken again.
struct AnswerEditSheet: View {
    let controller: KioskController
    let index: Int
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var canRespeak: Bool { controller.flow.phase == .review && controller.inputMode == .voice }

    var body: some View {
        NavigationStack {
            Form {
                AnswerField(kind: controller.flow.questions[index].kind, placeholder: "Answer", text: $text) { save() }
                    .font(.title3)
                    .listRowBackground(Theme.composer)
                if canRespeak {
                    Group {
                        Button(controller.isListening ? "Listening…" : "Speak again") { controller.respeak(index) }
                            .disabled(controller.isListening)
                        if controller.isListening { Button("Done") { controller.finishAnswer() }.bold() }
                        if !controller.caption.isEmpty && controller.isListening {
                            Text(controller.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    .listRowBackground(Theme.composer)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(controller.flow.questions[index].text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .tint(Theme.voiceBlue)
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

/// Single-line, so Return submits the typed answer.
struct AnswerField: View {
    let kind: KioskQuestionKind
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .onSubmit(onSubmit).submitLabel(.done)
            .autocorrectionDisabled(kind != .freeText)
            .textInputAutocapitalization(kind == .fullName ? .words : kind == .freeText ? .sentences : .characters)
            .keyboardType(kind == .dateOfBirth ? .numbersAndPunctuation : .default)
    }
}
