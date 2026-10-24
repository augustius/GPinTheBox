import Foundation

public protocol AnswerModel: Sendable {
    var isAvailable: Bool { get }
    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String
    func extract(reply: String, unanswered: [KioskQuestion]) async throws -> [Int: String]
}

public struct ReplyDigest: Equatable, Sendable {
    public var values: [Int: String]
    public var skippedTarget: Bool
    public init(values: [Int: String], skippedTarget: Bool) { self.values = values; self.skippedTarget = skippedTarget }
}

public actor AnswerTidier {
    private let model: any AnswerModel
    private let timeout: Duration
    public private(set) var extractionEnabled: Bool

    public init(model: any AnswerModel, timeout: Duration = .seconds(5)) {
        self.model = model; self.timeout = timeout; extractionEnabled = model.isAvailable
    }

    public func tidy(_ transcript: String, for question: KioskQuestion) async -> String {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isAvailable else { extractionEnabled = false; return raw }
        let model = model
        let output: String
        do { output = try await withTimeout(timeout) { try await model.tidy(transcript, for: question) } }
        catch { disableExtraction(unlessCancelled: error); return raw }
        let tidied: String
        switch question.kind {
        case .identifier: tidied = AnswerFormatting.normaliseIdentifier(output)
        case .dateOfBirth: tidied = KioskDate.isValidPastDOB(output) ? output : raw
        case .fullName, .freeText: tidied = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return tidied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !raw.isEmpty ? raw : tidied
    }

    public func extract(reply: String, unanswered: [KioskQuestion]) async -> [Int: String] {
        let remaining = unanswered
        guard extractionEnabled else { return [:] }
        let model = model
        let raw: [Int: String]
        do { raw = try await withTimeout(timeout) { try await model.extract(reply: reply, unanswered: remaining) } }
        catch { disableExtraction(unlessCancelled: error); return [:] }
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

    private static let skipWords: Set<String> = ["none", "no", "nothing", "nope", "n/a", "skip", "pass", "i'd rather not say", "rather not say", "prefer not to say"]

    public static func isSkip(_ reply: String) -> Bool {
        let t = reply.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?\u{2026}").union(.whitespacesAndNewlines)).lowercased()
        return skipWords.contains(t)
    }

    public func digest(reply: String, target: KioskQuestion, unanswered: [KioskQuestion]) async -> ReplyDigest {
        if Self.isSkip(reply) { return ReplyDigest(values: [:], skippedTarget: !target.isRequired) }
        let found = await extract(reply: reply, unanswered: unanswered)
        if !found.isEmpty { return ReplyDigest(values: found, skippedTarget: false) }
        let tidied = await tidy(reply, for: target)
        let value: String?
        switch target.kind {
        case .dateOfBirth: value = AnswerFormatting.isoDOB(from: tidied).flatMap { KioskDate.isValidPastDOB($0) ? $0 : nil }
        case .identifier: value = AnswerFormatting.normaliseIdentifier(tidied)
        case .fullName, .freeText: value = tidied
        }
        guard let value, !value.isEmpty else { return ReplyDigest(values: [:], skippedTarget: false) }
        return ReplyDigest(values: [target.id: value], skippedTarget: false)
    }

    private static func comparable(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespacesAndNewlines))
    }

    public func reset() { extractionEnabled = model.isAvailable }

    private func disableExtraction(unlessCancelled error: any Error) {
        if !(error is CancellationError) && !Task.isCancelled { extractionEnabled = false }
    }
}
