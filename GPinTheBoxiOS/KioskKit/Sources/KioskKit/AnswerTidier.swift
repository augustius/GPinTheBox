import Foundation
import KioskProtocol

public protocol AnswerModel: Sendable {
    var isAvailable: Bool { get }
    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String
    func prefill(transcript: String, remaining: [KioskQuestion]) async throws -> [Int: String]
}

public actor AnswerTidier {
    private let model: any AnswerModel
    private let timeout: Duration
    public private(set) var prefillEnabled: Bool

    public init(model: any AnswerModel, timeout: Duration = .seconds(5)) {
        self.model = model; self.timeout = timeout; prefillEnabled = model.isAvailable
    }

    public func tidy(_ transcript: String, for question: KioskQuestion) async -> String {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isAvailable else { prefillEnabled = false; return raw }
        let model = model
        let output: String
        do { output = try await withTimeout(timeout) { try await model.tidy(transcript, for: question) } }
        catch { disablePrefill(unlessCancelled: error); return raw }
        let tidied: String
        switch question.kind {
        case .identifier: tidied = AnswerFormatting.normaliseIdentifier(output)
        case .dateOfBirth: tidied = KioskDate.isValidPastDOB(output) ? output : raw
        case .fullName, .freeText: tidied = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tidied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !raw.isEmpty ? raw : tidied
    }

    public func prefill(transcript: String, remaining: [KioskQuestion]) async -> [Int: String] {
        guard prefillEnabled else { return [:] }
        let model = model
        let raw: [Int: String]
        do { raw = try await withTimeout(timeout) { try await model.prefill(transcript: transcript, remaining: remaining) } }
        catch { disablePrefill(unlessCancelled: error); return [:] }
        let byID = Dictionary(remaining.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let questionTexts = Set((KioskQuestions.all + remaining).map { Self.comparable($0.text) })
        return raw.reduce(into: [:]) { out, entry in
            let text = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let q = byID[entry.key], !text.hasSuffix("?"), !questionTexts.contains(Self.comparable(text)) else { return }
            let value: String?
            switch q.kind {
            case .identifier: value = AnswerFormatting.normaliseIdentifier(text)
            case .dateOfBirth: value = AnswerFormatting.isoDOB(from: text).flatMap { KioskDate.isValidPastDOB($0) ? $0 : nil }
            case .fullName, .freeText: value = text
            }
            if let value, !value.isEmpty { out[q.id] = value }
        }
    }

    private static func comparable(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespacesAndNewlines))
    }

    public func reset() { prefillEnabled = model.isAvailable }

    private func disablePrefill(unlessCancelled error: any Error) {
        if !(error is CancellationError) && !Task.isCancelled { prefillEnabled = false }
    }
}
