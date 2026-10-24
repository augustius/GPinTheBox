import SwiftUI
import KioskKit
import KioskProtocol

struct QuestionView: View {
    let controller: KioskController
    let index: Int
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var question: KioskQuestion { controller.flow.questions[index] }
    private var typingOnly: Bool { controller.inputMode == .typing }
    private var confirming: Bool { controller.flow.phase == .confirmingCandidate(index) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(controller.messages) { ChatBubble(text: $0.text, fromPatient: $0.role == .patient) }
                if controller.isListening && !controller.caption.isEmpty {
                    ChatBubble(text: controller.caption, fromPatient: true, live: true)
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 2) {
                Text("Question \(index + 1) of \(controller.flow.questions.count)").font(.subheadline).foregroundStyle(.secondary)
                Text(question.text).font(.title3.bold()).multilineTextAlignment(.center)
            }
            .padding(.horizontal).padding(.vertical, 8).frame(maxWidth: .infinity).background(.bar)
        }
        .safeAreaInset(edge: .bottom) { composer }
        .onAppear { fieldFocused = typingOnly }
        .onChange(of: controller.inputMode) { fieldFocused = typingOnly }
        .onChange(of: index) { typed = "" }
    }

    private var composer: some View {
        VStack(spacing: 14) {
            if confirming {
                HStack(spacing: 16) {
                    Button("That's right") { controller.confirmCandidate() }.buttonStyle(.borderedProminent)
                    Button("Add more") { controller.addToCandidate(); fieldFocused = typingOnly }
                    Button("Replace") { controller.replaceCandidate(); fieldFocused = typingOnly }
                }
            }
            HStack(spacing: 12) {
                if !typingOnly {
                    Image(systemName: controller.isListening ? "mic.fill" : "mic")
                        .font(.title2).foregroundStyle(controller.isListening ? .red : .secondary)
                        .symbolEffect(.pulse, isActive: controller.isListening)
                        .accessibilityLabel(controller.isListening ? "Listening" : "Microphone off")
                }
                AnswerField(kind: question.kind, placeholder: question.kind == .dateOfBirth ? "YYYY-MM-DD" : "Type your answer",
                            text: $typed, onSubmit: submit)
                    .textFieldStyle(.roundedBorder).font(.title2).focused($fieldFocused)
                    .onChange(of: typed) {
                        controller.noteActivity()
                        if !typed.isEmpty { controller.beginTyping() }
                    }
            }
            HStack(spacing: 16) {
                Button("Done") { typed.isEmpty ? controller.finishAnswer() : submit() }
                    .buttonStyle(.borderedProminent).disabled(typed.isEmpty && !controller.isListening && !typingOnly)
                Button("Repeat question") { controller.repeatQuestion() }
                if !question.isRequired { Button("Skip") { controller.skip() } }
            }
        }
        .controlSize(.large)
        .padding()
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func submit() {
        guard !typed.isEmpty || typingOnly else { return }
        let text = typed
        typed = ""
        controller.submitTyped(text)
        fieldFocused = typingOnly // Return resigns the field; keep the keyboard up when typing is the only input.
    }
}

private struct ChatBubble: View {
    let text: String
    let fromPatient: Bool
    var live = false

    var body: some View {
        HStack {
            if fromPatient { Spacer(minLength: 48) }
            Text(text)
                .font(.title3).italic(live)
                .foregroundStyle(fromPatient ? (live ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(fromPatient ? (live ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.accentColor))
                                        : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !fromPatient { Spacer(minLength: 48) }
        }
    }
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
