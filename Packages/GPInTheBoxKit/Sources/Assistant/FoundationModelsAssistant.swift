import Foundation
import FoundationModels

@Generable private struct ClaimOutput {
    @Guide(description: "A concise statement supported by the excerpts. Preserve negation and uncertainty.") var text: String
    @Guide(description: "Exact IDs copied from supporting excerpts, without brackets.") var chunkIDs: [String]
    @Guide(description: "Verbatim supporting text copied from each cited excerpt, in the same order as chunkIDs.") var quotes: [String]
}
@Generable private struct AnswerOutput { @Guide(description: "Supported claims only. Empty when no answer is found.", .count(0...6)) var claims: [ClaimOutput] }
@Generable private struct FollowUpOutput {
    @Guide(description: "A thing the GP explicitly asked to check or follow up next visit, not a new recommendation.") var item: String
    @Guide(description: "The complete exact sentence copied from the GP note.") var sourceSentence: String
}
@Generable private struct FollowUpsOutput { @Guide(.count(0...12)) var items: [FollowUpOutput] }
@Generable private struct JudgementOutput {
    @Guide(description: "Whether the item is mentioned, including a negative statement. This does NOT mean completed or addressed.") var mentioned: Bool
    @Guide(description: "Exact IDs of excerpts mentioning the item. Empty if not mentioned.") var chunkIDs: [String]
}
public struct FoundationModelsAssistant: AssistantModel {
    public init() {}
    public func availability() -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(reason: "This Mac doesn't support Apple Intelligence")
            case .appleIntelligenceNotEnabled: return .unavailable(reason: "Apple Intelligence is turned off in System Settings")
            case .modelNotReady: return .unavailable(reason: "The model is still downloading")
            @unknown default: return .unavailable(reason: "Unknown reason")
            }
        }
    }
    public func respond(instructions: String, prompt: String) async throws -> ModelAnswer {
        let output: AnswerOutput = try await generate(instructions: instructions, prompt: prompt)
        return ModelAnswer(claims: output.claims.map { GeneratedClaim(text: $0.text, chunkIDs: $0.chunkIDs, quotes: $0.quotes) })
    }
    public func extractFollowUps(fromNote note: String) async throws -> [ExtractedFollowUp] {
        let output: FollowUpsOutput = try await generate(instructions: AssistantPrompts.baseInstructions + " Extract only explicitly requested follow-ups from this GP note. Copy the complete source sentence exactly.", prompt: note)
        return output.items.map { ExtractedFollowUp(item: $0.item, sourceSentence: $0.sourceSentence) }
    }
    public func judgeFollowUp(item: String, excerpts: String) async throws -> FollowUpJudgement {
        let output: JudgementOutput = try await generate(instructions: AssistantPrompts.baseInstructions + " Determine only whether the requested item is mentioned. A denial or statement that it was not done still counts as mentioned, never as completed.", prompt: "Item: \(item)\nIntake excerpts:\n\(excerpts)")
        return FollowUpJudgement(mentioned: output.mentioned, chunkIDs: output.chunkIDs)
    }
    private func generate<T: Generable>(instructions: String, prompt: String) async throws -> T {
        try ContextBudget.check(self)
        let model = SystemLanguageModel.default
        do {
            let reserve = 900
            if #available(macOS 26.4, *) {
                let input = try await model.tokenCount(for: Prompt(prompt))
                let system = try await model.tokenCount(for: Instructions(instructions))
                let schema = try await model.tokenCount(for: T.generationSchema)
                guard input + system + schema + reserve + 128 <= model.contextSize else { throw AssistantError.contextOverflow }
            } else {
                // UTF-8 bytes overestimate typical text token counts; leave room for schema and output.
                guard prompt.utf8.count + instructions.utf8.count <= 2200 else { throw AssistantError.contextOverflow }
            }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt, generating: T.self, options: GenerationOptions(temperature: 0, maximumResponseTokens: reserve))
            try Task.checkCancellation()
            return response.content
        } catch is CancellationError { throw CancellationError() }
        catch let error as AssistantError { throw error }
        catch {
            if #available(macOS 27.0, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: throw AssistantError.contextOverflow
                case .guardrailViolation, .refusal: throw AssistantError.guardrailViolation
                case .unsupportedLanguageOrLocale: throw AssistantError.unsupportedLanguage
                default: throw AssistantError.failed(error.localizedDescription)
                }
            }
            if let error = error as? LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize: throw AssistantError.contextOverflow
                case .guardrailViolation, .refusal: throw AssistantError.guardrailViolation
                case .unsupportedLanguageOrLocale: throw AssistantError.unsupportedLanguage
                default: throw AssistantError.failed(error.localizedDescription)
                }
            }
            throw AssistantError.failed(error.localizedDescription)
        }
    }
}
