import Foundation

public enum FlowPhase: Equatable, Sendable { case welcome, asking(Int), review, cantProceed(Int), sending, sendFailed(String), done }

public struct IntakeFlow: Equatable, Sendable {
    public static let requiredAskLimit = 3, optionalAskLimit = 2
    public let questions: [KioskQuestion]
    public private(set) var answers: [String]
    public private(set) var askCounts: [Int]
    public private(set) var phase: FlowPhase = .welcome
    private var answeredEmpty: Set<Int> = []

    public init(questions: [KioskQuestion] = KioskQuestions.all) {
        self.questions = questions
        answers = Array(repeating: "", count: questions.count); askCounts = Array(repeating: 0, count: questions.count)
    }

    public var currentIndex: Int? { if case .asking(let i) = phase { i } else { nil } }

    public func isAnswered(_ i: Int) -> Bool { !answers[i].isEmpty || answeredEmpty.contains(i) }
    public func isAnsweredEmpty(_ i: Int) -> Bool { answeredEmpty.contains(i) }
    public var answeredCount: Int { questions.indices.count(where: isAnswered) }
    public var unanswered: [KioskQuestion] { questions.filter { !isAnswered($0.id) } }
    /// The non-empty answers given so far, by question index.
    public var recordedAnswers: [Int: String] { Dictionary(uniqueKeysWithValues: questions.indices.filter { !answers[$0].isEmpty }.map { ($0, answers[$0]) }) }

    public mutating func start() { if phase == .welcome { advance() } }

    public mutating func noteAsked() { if let i = currentIndex { askCounts[i] += 1 } }

    @discardableResult public mutating func record(_ values: [Int: String]) -> [Int: String] {
        var applied: [Int: String] = [:]
        for (i, text) in values where questions.indices.contains(i) && !isAnswered(i) {
            let value = normalised(text, for: i)
            if !value.isEmpty { answers[i] = value; applied[i] = value }
        }
        return applied
    }

    public mutating func markAnsweredEmpty(_ i: Int) {
        guard questions.indices.contains(i), !questions[i].isRequired, !isAnswered(i) else { return }
        answeredEmpty.insert(i)
    }

    public mutating func advance() {
        for q in questions where q.isRequired && !isAnswered(q.id) {
            phase = askCounts[q.id] >= Self.requiredAskLimit ? .cantProceed(q.id) : .asking(q.id); return
        }
        for q in questions where !q.isRequired && !isAnswered(q.id) {
            if askCounts[q.id] >= Self.optionalAskLimit { answeredEmpty.insert(q.id); continue }
            phase = .asking(q.id); return
        }
        phase = .review
    }

    public mutating func edit(_ i: Int, to text: String) {
        switch phase { case .asking, .review: break; default: return }
        guard questions.indices.contains(i) else { return }
        answers[i] = normalised(text, for: i)
        if !answers[i].isEmpty { answeredEmpty.remove(i) }
        else if questions[i].isRequired { askCounts[i] = 0 }
        else { answeredEmpty.insert(i) }
    }

    public var canSend: Bool {
        for q in questions {
            let a = answers[q.id].trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isRequired && a.isEmpty { return false }
            if q.kind == .dateOfBirth && !a.isEmpty && !KioskDate.isValidPastDOB(a) { return false }
        }
        return true
    }

    public func request(submissionID: UUID) -> KioskRequest {
        KioskRequest(submissionID: submissionID, answers: questions.map {
            KioskAnswer(q: $0.text, a: answers[$0.id].trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    public mutating func beginSending() {
        switch phase { case .review, .sendFailed: if canSend { phase = .sending }; default: break }
    }
    public mutating func sendSucceeded() { if phase == .sending { phase = .done } }
    public mutating func sendFailed(_ message: String) { if phase == .sending { phase = .sendFailed(message) } }
    public mutating func returnToReview() { if case .sendFailed = phase { phase = .review } }

    private func normalised(_ text: String, for i: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return questions[i].kind == .dateOfBirth ? AnswerFormatting.isoDOB(from: trimmed) ?? trimmed : trimmed
    }
}
