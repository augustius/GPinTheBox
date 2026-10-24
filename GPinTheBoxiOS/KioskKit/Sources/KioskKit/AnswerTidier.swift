import Foundation

public protocol AnswerModel: Sendable {
    var isAvailable: Bool { get }
    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String
    func extract(reply: String, target: KioskQuestion, unanswered: [KioskQuestion]) async throws -> [Int: String]
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

    public func extract(reply: String, target: KioskQuestion, unanswered: [KioskQuestion], answers: [Int: String] = [:]) async -> [Int: String] {
        await candidates(reply: reply, target: target, unanswered: unanswered, answers: answers).values
    }

    /// The model's answers that pass validation; `addressed` is also true when it only repeated answers already recorded.
    private func candidates(reply: String, target: KioskQuestion, unanswered: [KioskQuestion], answers: [Int: String]) async -> (values: [Int: String], addressed: Bool) {
        let remaining = unanswered
        guard extractionEnabled else { return ([:], false) }
        let model = model
        let raw: [Int: String]
        do { raw = try await withTimeout(timeout) { try await model.extract(reply: reply, target: target, unanswered: remaining) } }
        catch { disableExtraction(unlessCancelled: error); return ([:], false) }
        let byID = Dictionary(remaining.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let questionTexts = Set((KioskQuestions.all + remaining).map { Self.comparable($0.text) })
        let recorded = Set(answers.values.map(Self.dedupeKey))
        var values: [Int: String] = [:], seen: Set<String> = [], addressed = false
        for (id, value) in raw.sorted(by: { ($0.key == target.id ? -1 : $0.key) < ($1.key == target.id ? -1 : $1.key) }) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasSuffix("?"), !questionTexts.contains(Self.comparable(text)) else { continue }
            guard let q = byID[id] else { continue }
            guard let value = Self.validated(text, for: q, isTarget: q.id == target.id) else { continue }
            let key = Self.dedupeKey(value)
            if recorded.contains(key) { addressed = true; continue }
            if seen.insert(key).inserted { values[q.id] = value }
        }
        return (values, addressed || !values.isEmpty)
    }

    private static let timeWords: Set<String> = ["today", "yesterday", "since", "ago", "week", "weeks", "month", "months", "year", "years",
        "morning", "mornings", "night", "nights", "tonight", "day", "days", "hour", "hours", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "last", "couple", "few"]

    /// A value in the form its question stores, or nil when it can't be that answer. Values for other questions must also look plausible.
    private static func validated(_ text: String, for q: KioskQuestion, isTarget: Bool) -> String? {
        let hasDigit = text.contains(where: \.isNumber)
        let value: String?
        switch q.kind {
        case .identifier:
            let id = AnswerFormatting.normaliseIdentifier(text)
            value = id.contains(where: \.isNumber) ? id : nil
        case .dateOfBirth: value = AnswerFormatting.isoDOB(from: text).flatMap { KioskDate.isValidPastDOB($0) ? $0 : nil }
        case .fullName: value = isTarget || (!hasDigit && text.split(whereSeparator: \.isWhitespace).count <= 5) ? text : nil
        case .freeText:
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            value = isTarget || q.id != 4 || hasDigit || words.contains(where: timeWords.contains) ? text : nil
        }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func dedupeKey(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static let skipWords: Set<String> = ["none", "no", "nothing", "nope", "n/a", "skip", "pass", "i'd rather not say", "rather not say", "prefer not to say"]

    public static func isSkip(_ reply: String) -> Bool {
        let t = reply.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?\u{2026}").union(.whitespacesAndNewlines)).lowercased()
        return skipWords.contains(t)
    }

    public func digest(reply: String, target: KioskQuestion, unanswered: [KioskQuestion], answers: [Int: String] = [:]) async -> ReplyDigest {
        if Self.isSkip(reply) { return ReplyDigest(values: [:], skippedTarget: !target.isRequired) }
        let found = await candidates(reply: reply, target: target, unanswered: unanswered, answers: answers)
        if found.addressed { return ReplyDigest(values: found.values, skippedTarget: false) }
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
