import SwiftUI
import KioskKit

struct ChatView: View {
    let controller: KioskController
    @State private var typed = ""
    @State private var editing: EditTarget?
    @FocusState private var fieldFocused: Bool

    private var quiet: Bool { controller.inputMode == .typing }
    private var hasText: Bool { !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(controller.messages) { m in
                    if m.role == .kiosk { kioskLine(m) } else { patientMessage(m) }
                }
                if controller.isListening { liveCaption }
                if controller.isDigesting { ThinkingDots() }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.never)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .safeAreaInset(edge: .top) {
            Text("\(controller.flow.answeredCount) of \(controller.flow.questions.count)")
                .font(.subheadline).foregroundStyle(Theme.secondary)
                .padding(.vertical, 8).frame(maxWidth: .infinity).background(Theme.background)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .background(Theme.background)
        .onAppear { fieldFocused = quiet }
        .onChange(of: controller.inputMode) { fieldFocused = quiet }
        .onChange(of: typed) {
            controller.noteActivity()
            if typed.isEmpty { controller.endTyping() } else { controller.beginTyping() }
        }
        .onChange(of: controller.dictated) {
            let heard = controller.dictated
            guard !heard.isEmpty else { return }
            typed = typed.isEmpty ? heard : typed + " " + heard
            controller.clearDictation(); fieldFocused = true
        }
        .stillThereAlert(controller, enabled: editing == nil)
        .sheet(item: $editing) { AnswerEditSheet(controller: controller, index: $0.id).stillThereAlert(controller) }
    }

    private func kioskLine(_ m: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.text).font(.title3).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            if m.id == controller.latestKioskMessageID {
                HStack(spacing: 18) {
                    Button { controller.speakAgain() } label: { Image(systemName: "speaker.wave.2") }
                        .accessibilityLabel("Read aloud").disabled(controller.isDigesting)
                    Button { controller.rephrase() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Ask another way").disabled(!controller.canRephrase)
                }
                .font(.body).foregroundStyle(Theme.secondary).buttonStyle(.plain)
            }
        }
    }

    private func patientMessage(_ m: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            bubble(Text(m.text))
            if !m.picked.isEmpty {
                TrailingFlow(spacing: 6) {
                    ForEach(m.picked.keys.sorted(), id: \.self) { i in chip(i, value: m.picked[i] ?? "") }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private func chip(_ index: Int, value: String) -> some View {
        let q = controller.flow.questions[index]
        return Button { editing = EditTarget(id: index) } label: {
            HStack(spacing: 4) {
                Text("\(ChipLabel.text(for: q)): \(Theme.display(value, for: q))")
                Image(systemName: "pencil").imageScale(.small)
            }
            .font(.subheadline).foregroundStyle(Theme.chipText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit this answer")
    }

    private var liveCaption: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bubble(Text(controller.caption.isEmpty ? "Listening…" : controller.caption).italic()).opacity(0.6)
            Button("Done") { controller.finishAnswer() }
                .font(.subheadline.bold()).buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private func bubble(_ text: Text) -> some View {
        text.font(.title3).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.patientBubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("Answers are checked by clinic staff. Synthetic data only.")
                .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            composer
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private var composer: some View {
        HStack(spacing: 12) {
            TextField("Type your answer", text: $typed)
                .font(.title3).foregroundStyle(.white)
                .focused($fieldFocused)
                .submitLabel(.send).onSubmit(submit)
                .padding(.leading, 8)
            if controller.speechAvailable {
                Button { controller.dictate() } label: {
                    Image(systemName: "mic").font(.title3).foregroundStyle(Theme.secondary)
                }
                .accessibilityLabel("Dictate").disabled(controller.isDigesting)
            }
            if hasText {
                circle("arrow.up", label: "Send", action: submit)
            } else if controller.speechAvailable {
                circle(quiet ? "waveform.slash" : "waveform", label: quiet ? "Voice off" : "Voice on") {
                    controller.inputMode = quiet ? .voice : .typing
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(Theme.composer, in: Capsule())
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3.bold()).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(Theme.voiceBlue, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func submit() {
        guard hasText else { return }
        let text = typed
        controller.submitTyped(text)
        typed = ""
        fieldFocused = true // Return resigns the field; keep the keyboard up while typing.
    }
}

/// Three pulsing dots in the kiosk's place while a reply is being digested.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.secondary).frame(width: 8, height: 8).opacity(i == step ? 1 : 0.3)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: step)
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Thinking")
    }
}

/// Wraps its subviews into rows, each aligned to the trailing edge.
private struct TrailingFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [i], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}
