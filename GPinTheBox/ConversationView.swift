import SwiftUI
import SwiftData
import Records
import ConsultationAudio

struct ConversationView: View {
    @Bindable var consultation: Consultation
    @Environment(\.modelContext) private var context
    @State private var error: String?
    private var speakers: [String] { Array(Set(consultation.conversationTurns.compactMap(\.speakerID))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Consultation conversation").font(.headline)
            Text("Speaker labels are estimates. Assign Doctor and Patient only after checking the turns. Unassigned text may include overlapping or uncertain speech. Role or text corrections clear any existing summary approval.").font(.caption).foregroundStyle(Color.careSecondary)
            ForEach(speakers, id: \.self) { speaker in
                Picker(consultation.speakerLabel(for: speaker), selection: Binding(get: { consultation.speakerRoles[speaker] ?? .unassigned }, set: { role in
                    do {
                        try ConsultationMutations.assignSpeakerRole(context: context, consultation: consultation, speakerID: speaker, role: role)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                })) {
                    ForEach(SpeakerRole.allCases, id: \.self) { role in Text(role.rawValue).tag(role) }
                }.frame(maxWidth: 350)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            // Lazy rows avoid constructing thousands of editors for a long consultation.
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(consultation.conversationTurns) { turn in
                    ConversationTurnRow(consultation: consultation, turn: turn, speakers: speakers)
                }
            }
        }
    }
}

private struct ConversationTurnRow: View {
    let consultation: Consultation
    let turn: ConversationTurn
    let speakers: [String]
    @Environment(\.modelContext) private var context
    @State private var editing = false
    @State private var editedText = ""
    @State private var editedSpeaker = ""
    @State private var glossaryTerm = ""
    @State private var glossaryMessage: String?
    @State private var error: String?
    private var role: SpeakerRole { turn.speakerID.flatMap { consultation.speakerRoles[$0] } ?? .unassigned }
    var body: some View {
        HStack {
            if role == .patient { Spacer(minLength: 35) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(consultation.speakerLabel(for: turn.speakerID)).font(.subheadline.bold())
                    Text(timestamp(turn.startSeconds)).font(.caption).foregroundStyle(Color.careSecondary)
                    Spacer()
                    Menu("Assign role") {
                        ForEach(SpeakerRole.allCases, id: \.self) { role in
                            Button(role.rawValue) {
                                do {
                                    try ConsultationMutations.assignTurnRole(context: context, consultation: consultation, turnID: turn.id, role: role)
                                    editing = false; error = nil
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    Button(editing ? "Cancel edit" : "Edit turn") {
                        editing.toggle(); editedText = turn.text; editedSpeaker = turn.speakerID ?? ""; error = nil
                    }.buttonStyle(.borderless)
                }
                if editing {
                    TextField("Spoken words", text: $editedText, axis: .vertical)
                    Picker("Speaker", selection: $editedSpeaker) {
                        Text("Unassigned").tag("")
                        ForEach(speakers, id: \.self) { id in Text(consultation.speakerLabel(for: id)).tag(id) }
                    }
                    Button("Save turn") {
                        do {
                            try ConsultationMutations.updateConversationTurn(context: context, consultation: consultation,
                                turnID: turn.id, text: editedText, speakerID: editedSpeaker.isEmpty ? nil : editedSpeaker)
                            editing = false; error = nil
                        } catch { self.error = error.localizedDescription }
                    }.disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    HStack {
                        TextField("Misheard term to add to glossary", text: $glossaryTerm)
                        Button("Add term") {
                            do {
                                let store = SpeechGlossaryStore()
                                try store.save(store.load() + [glossaryTerm])
                                glossaryMessage = "Added for future transcriptions."; glossaryTerm = ""; error = nil
                            } catch { self.error = error.localizedDescription }
                        }.disabled(glossaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let glossaryMessage { Text(glossaryMessage).font(.caption).foregroundStyle(Color.careSecondary) }
                } else { Text(turn.text).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(.orange) }
            }.padding(12).background(role == .doctor ? Color.careSelection : Color.careAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            if role != .patient { Spacer(minLength: 35) }
        }
    }
    private func timestamp(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
