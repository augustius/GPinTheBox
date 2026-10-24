import SwiftUI
import Records
struct QuestionnaireEditor: View {
    let model: AppModel
    @State private var questions: [QuestionSnapshot] = []
    @State private var message: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Intake questionnaire").font(.title2.bold())
            Text("Publishing creates a new version. Forms already open keep their original questions.").foregroundStyle(.secondary)
            List {
                ForEach($questions) { $question in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Question", text: $question.prompt)
                        HStack {
                            Picker("Type", selection: $question.kind) { Text("Short answer").tag(QuestionKind.shortText); Text("Long answer").tag(QuestionKind.longText) }.frame(width: 230)
                            Toggle("Required", isOn: $question.isRequired)
                            Spacer()
                            Button(role: .destructive) { questions.removeAll { $0.id == question.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 8)
                }.onMove { from, to in questions.move(fromOffsets: from, toOffset: to) }
            }
            if let message { Text(message).font(.callout) }
            HStack {
                Button("Add question") { questions.append(.init(prompt: "", kind: .shortText, isRequired: false)) }
                Spacer()
                Button("Publish questionnaire") {
                    saving = true
                    Task {
                        do { _ = try await model.store?.publishQuestionnaire(questions); message = "Published. New forms will use these questions." }
                        catch { message = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || questions.isEmpty)
            }
        }.padding(24).task {
            do { questions = try await model.store?.questionnaire().questions ?? [] }
            catch { message = error.localizedDescription }
        }
    }
}
