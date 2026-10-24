import SwiftUI
import KioskKit
import KioskProtocol

struct QuestionView: View {
    @Bindable var controller: KioskController
    let index: Int
    let canUseVoice: Bool
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var question: KioskQuestion { controller.flow.questions[index] }
    private var typing: Bool { controller.inputMode == .typing }
    private var candidate: String? {
        if case .confirmingCandidate = controller.flow.phase { controller.flow.candidates[index] } else { nil }
    }

    var body: some View {
        VStack(spacing: 28) {
            Text("Question \(index + 1) of \(controller.flow.questions.count)").font(.headline).foregroundStyle(.secondary)
            Text(question.text).font(.largeTitle.bold()).multilineTextAlignment(.center)
            if let candidate {
                Text(IntakeFlow.readback(candidate)).font(.title2).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button("That's right") { controller.confirmCandidate() }.buttonStyle(.borderedProminent)
                    Button("Add more") { controller.addToCandidate(); fieldFocused = typing }
                    Button("Replace") { controller.replaceCandidate(); fieldFocused = typing }
                }
                .controlSize(.large)
            } else if !typing {
                Text(controller.caption.isEmpty ? (controller.isListening ? "Listening…" : " ") : controller.caption)
                    .font(.title2).foregroundStyle(controller.caption.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center).frame(minHeight: 80)
            }
            if typing {
                TextField(question.kind == .dateOfBirth ? "YYYY-MM-DD" : "Type your answer", text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.title2).focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: typed) { controller.noteActivity() }
            }
            if candidate == nil || typing {
                HStack(spacing: 16) {
                    Button("Done") { typing ? submit() : controller.finishAnswer() }
                        .buttonStyle(.borderedProminent).disabled(!typing && !controller.isListening)
                    Button("Repeat question") { controller.repeatQuestion() }
                    if !question.isRequired { Button("Skip") { controller.skip() } }
                }
                .controlSize(.large)
            }
            if typing {
                if canUseVoice { Button("Use voice instead") { controller.inputMode = .voice } }
            } else {
                Button("Type instead") { controller.inputMode = .typing; fieldFocused = true }
            }
        }
        .padding(32)
        .frame(maxWidth: 720)
        .onAppear { fieldFocused = typing }
    }

    private func submit() {
        let text = typed
        typed = ""
        controller.submitTyped(text)
    }
}
