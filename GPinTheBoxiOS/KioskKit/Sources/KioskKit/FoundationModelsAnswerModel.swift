import Foundation
import FoundationModels
import KioskProtocol

@Generable private struct TidiedText { var answer: String }
@Generable private struct TidiedID { @Guide(description: "Spell the ID as letters and digits.") var answer: String }
@Generable private struct TidiedDate {
    @Guide(description: "The words the patient used for the year, copied exactly, or nil if no year was said.") var spokenYear: String?
    @Guide(description: "The words the patient used for the month, copied exactly, or nil if no month was said.") var spokenMonth: String?
    @Guide(description: "The words the patient used for the day of the month, such as 'the first', copied exactly and not part of spokenYear, or nil if no day was said.") var spokenDay: String?
    @Guide(description: "spokenYear as a four-digit number, or nil if spokenYear is nil.") var year: Int?
    @Guide(description: "spokenMonth as a number from 1 to 12, or nil if spokenMonth is nil.") var month: Int?
    @Guide(description: "spokenDay as a number from 1 to 31, or nil if spokenDay is nil.") var day: Int?
}
@Generable private struct PrefillCandidate {
    @Guide(description: "The number of the question this answers.") var questionNumber: Int
    @Guide(description: "The patient's own words answering that question.") var answer: String
}
@Generable private struct PrefillResult {
    @Guide(description: "Answers only to questions the transcript explicitly addresses. Empty if none.") var candidates: [PrefillCandidate]
}

public struct FoundationModelsAnswerModel: AnswerModel {
    static let instructions = "You tidy a patient's spoken answer to one clinic intake question. Remove filler words, false starts and repetitions. Keep the patient's own words. Never add information, never guess, and never give medical advice or a diagnosis. If the answer is unclear, return it unchanged."

    public init() {}
    public var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    public func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String {
        let prompt = "Question: \(question.text)\nSpoken answer: \(transcript)"
        switch question.kind {
        case .identifier: return try await generate(prompt, TidiedID.self).answer
        case .dateOfBirth:
            let d = try await generate(prompt, TidiedDate.self)
            guard d.spokenYear != nil, d.spokenMonth != nil, d.spokenDay != nil, let year = d.year, let month = d.month, let day = d.day else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .fullName, .freeText: return try await generate(prompt, TidiedText.self).answer
        }
    }

    public func prefill(transcript: String, remaining: [KioskQuestion]) async throws -> [Int: String] {
        let questions = remaining.map { "\($0.id + 1). \($0.text)" }.joined(separator: "\n")
        let prompt = "Questions:\n\(questions)\n\nSpoken answer: \(transcript)\n\nAnswer only the questions above that the spoken answer explicitly addresses, using their question numbers."
        let ids = Set(remaining.map(\.id))
        var result: [Int: String] = [:]
        for c in try await generate(prompt, PrefillResult.self).candidates where ids.contains(c.questionNumber - 1) {
            result[c.questionNumber - 1] = c.answer
        }
        return result
    }

    private func generate<T: Generable>(_ prompt: String, _ type: T.Type) async throws -> T {
        let session = LanguageModelSession(instructions: Self.instructions)
        return try await session.respond(to: prompt, generating: type, options: GenerationOptions(temperature: 0)).content
    }
}
