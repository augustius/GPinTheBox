import Foundation
import Assistant
import Records
@main struct ModelProbe {
    static func main() async {
        let model = FoundationModelsAssistant()
        print("Availability: \(model.availability())")
        guard model.availability() == .available else { print("SKIPPED: actual-device model tests"); return }
        let first = VisitSnapshot(answers: [.init(questionID: UUID(), prompt: "Reason", value: "Cough for three days")], gpNote: "Recheck blood pressure next visit.")
        let second = VisitSnapshot(answers: [.init(questionID: UUID(), prompt: "Reason", value: "I have not checked my blood pressure. Cough is better.")])
        let patient = PatientSnapshot(fullName: "Synthetic Jane", dateOfBirth: "1980-05-01", visits: [first, second])
        var failures = 0
        do {
            let summary = try await Summarizer(model: model).summarize(patient, visitID: second.id)
            guard !summary.overview.claims.isEmpty, summary.overview.citedChunks.contains(where: { $0.visitID == second.id }), !summary.followUps.isEmpty, !summary.incompleteFollowUps else { throw AssistantError.failed("Missing summary or grounded follow-up") }
            print("PASS: summary \(summary.overview.claims.count) cited claims; \(summary.followUps.count) follow-ups")
        } catch { failures += 1; print("FAIL summary: \(error)") }
        do {
            let answer = try await QAService(model: model).answer("What did the patient say about their cough?", patient: patient)
            guard !answer.claims.isEmpty else { throw AssistantError.failed("No answer") }
            print("PASS: Q&A \(answer.claims.count) cited claims")
        } catch { failures += 1; print("FAIL Q&A: \(error)") }
        do {
            _ = try await model.respond(instructions: AssistantPrompts.baseInstructions, prompt: String(repeating: "oversized synthetic record ", count: 10000))
            failures += 1; print("FAIL: overflow did not throw")
        } catch AssistantError.contextOverflow { print("PASS: bounded context overflow") }
        catch { failures += 1; print("FAIL: unexpected overflow error \(error)") }
        do {
            let prompts = ["What is the main reason for your visit today?", "When did it start?", "Describe your symptoms.", "Are you currently taking any medications? Please list them.", "Do you have any allergies?", "Do you have any ongoing medical conditions?", "Is there anything else you'd like the doctor to know?"]
            let oldValues = ["Dry cough and a sore throat. Fictional demo record.", "Three days ago.", "Dry cough, mild sore throat, and tiredness. No fever or shortness of breath reported.", "No regular medications reported.", "Penicillin — rash (fictional history).", "No ongoing conditions reported.", "This is synthetic test data only, not a real patient. Cough is worse at night."]
            let newValues = ["Cough is better since the previous visit.", "Started a week ago.", "Cough is improving. No fever or shortness of breath.", "No regular medications reported.", "Penicillin — rash (fictional history).", "No ongoing conditions reported.", "I have not checked my blood pressure. Synthetic test record only."]
            func answers(_ values: [String]) -> [Answer] { zip(prompts, values).map { Answer(questionID: UUID(), prompt: $0, value: $1) } }
            let old = VisitSnapshot(answers: answers(oldValues), gpNote: "Ask about cough at the next visit. Recheck blood pressure next visit.")
            let current = VisitSnapshot(answers: answers(newValues))
            let full = PatientSnapshot(fullName: "Synthetic full-form patient", dateOfBirth: "1980-05-01", visits: [old, current])
            let result = try await QAService(model: model).answer("What did the patient report about checking blood pressure at this visit?", patient: full)
            guard result.citedChunks.contains(where: { $0.id == "V2-A7" }) else { throw AssistantError.failed("Current BP evidence missing") }
            print("PASS: full-form Q&A cites current negative BP statement")
        } catch { failures += 1; print("FAIL full-form Q&A: \(error)") }
        if failures > 0 { exit(1) }
    }
}
