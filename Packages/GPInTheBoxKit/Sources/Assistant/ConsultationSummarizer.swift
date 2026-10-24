import Foundation

/// Generates an unapproved draft from an automated, potentially inaccurate conversation transcript.
/// Saving this output as a clinical record is a separate, explicit doctor-review action.
public struct ConsultationSummarizer: Sendable {
    private let model: any AssistantModel
    private let budgetBytes: Int
    public init(model: any AssistantModel, budgetBytes: Int = ContextBudget.inputBytes) {
        self.model = model
        self.budgetBytes = min(ContextBudget.inputBytes, max(256, budgetBytes))
    }
    public func summarize(transcript: String, consultationID: UUID, date: Date) async throws -> CitedText {
        try ContextBudget.check(model)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError.failed("There is no consultation transcript to summarise") }
        let chunk = Chunk(id: "T-\(consultationID.uuidString)", visitID: consultationID, date: date,
            source: .consultationTranscript, text: text)
        let focus = """
        Transform the supplied transcript into concise factual notes for human review. This is a text-summary task, not advice.
        The input is an unverified combined conversation and may contain transcription errors.
        Do not infer who spoke or assign statements to a person unless a speaker is explicitly identified in the text.
        Preserve the recorded concerns, history, negative statements, uncertainty, and explicitly stated next steps.
        Report any stated assessment or plan as something said in the conversation; never make a new diagnosis or recommendation.
        Do not add missing details or resolve contradictions. Keep exact supporting quotations. The result is an unapproved draft.
        """
        var budget = budgetBytes
        for attempt in 0...3 {
            do {
                let result = try await Summarizer(model: model).reduce([chunk], budget: budget, focus: focus)
                try Task.checkCancellation()
                guard !result.claims.isEmpty else { throw AssistantError.failed("No supported consultation summary could be generated") }
                return result
            } catch AssistantError.contextOverflow {
                if attempt == 3 { throw AssistantError.contextOverflow }
                budget = max(192, budget / 2)
            }
        }
        throw AssistantError.contextOverflow
    }
}
