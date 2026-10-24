import SwiftUI
import KioskKit

struct ReviewView: View {
    let controller: KioskController
    @State private var editing: EditTarget?

    var body: some View {
        VStack(spacing: 16) {
            Text("Please check your answers").font(.largeTitle.bold()).padding(.top)
            if let error = controller.lastError {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            List(controller.flow.questions) { q in
                Button { editing = EditTarget(id: q.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(q.text).font(.headline).foregroundStyle(.white)
                            Text(display(q)).foregroundStyle(controller.flow.answers[q.id].isEmpty ? Theme.secondary : .white)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(Theme.secondary)
                    }
                }
                .listRowBackground(Theme.composer)
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 820)
            if !controller.flow.canSend {
                Text("Name, ID and a valid date of birth (YYYY-MM-DD) are needed to send.")
                    .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            Button { controller.send() } label: { Text("Send to clinic").font(.title2.bold()).frame(maxWidth: 400) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!controller.flow.canSend)
        }
        .padding()
        .background(Theme.background)
        .stillThereAlert(controller, enabled: editing == nil)
        .sheet(item: $editing) { AnswerEditSheet(controller: controller, index: $0.id).stillThereAlert(controller) }
    }

    private func display(_ q: KioskQuestion) -> String {
        let answer = controller.flow.answers[q.id]
        if answer.isEmpty && !controller.flow.isAnsweredEmpty(q.id) { return "Not answered" }
        return Theme.display(answer, for: q)
    }
}
