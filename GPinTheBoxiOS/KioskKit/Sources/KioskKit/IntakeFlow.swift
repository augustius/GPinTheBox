import Foundation
import KioskProtocol

public enum FlowPhase: Equatable, Sendable { case welcome, asking(Int), confirmingCandidate(Int), review, sending, sendFailed(String), done }

public struct IntakeFlow: Equatable, Sendable {
    public let questions: [KioskQuestion]
    public private(set) var answers: [String]
    public private(set) var candidates: [Int: String] = [:]
    public private(set) var phase: FlowPhase = .welcome

    public init(questions: [KioskQuestion] = KioskQuestions.all) {
        self.questions = questions; answers = Array(repeating: "", count: questions.count)
    }

    public var currentIndex: Int? {
        switch phase { case .asking(let i), .confirmingCandidate(let i): i; default: nil }
    }

    public mutating func start() { if phase == .welcome { phase = .asking(0) } }

    @discardableResult public mutating func answer(_ text: String) -> Bool {
        guard let i = currentIndex else { return false }
        let value = normalised(text, for: i)
        if value.isEmpty && questions[i].isRequired { return false }
        answers[i] = value; advance(from: i); return true
    }

    @discardableResult public mutating func skip() -> Bool {
        guard let i = currentIndex, !questions[i].isRequired else { return false }
        answers[i] = ""; advance(from: i); return true
    }

    public mutating func addCandidates(_ values: [Int: String]) {
        let floor: Int
        switch phase {
        case .asking(let i): floor = i
        case .confirmingCandidate(let i): floor = i + 1
        default: return
        }
        for (i, text) in values where i >= floor && i < questions.count && answers[i].isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { candidates[i] = trimmed }
        }
        if case .asking(let i) = phase, candidates[i] != nil { phase = .confirmingCandidate(i) }
    }

    public mutating func confirmCandidate() {
        guard case .confirmingCandidate(let i) = phase, let c = candidates[i] else { return }
        answers[i] = normalised(c, for: i); advance(from: i)
    }

    public mutating func appendToCandidate(_ text: String) {
        guard case .confirmingCandidate(let i) = phase, let c = candidates[i] else { return }
        answers[i] = normalised(c + " " + text, for: i); advance(from: i)
    }

    public mutating func edit(_ index: Int, to text: String) {
        guard phase == .review, answers.indices.contains(index) else { return }
        answers[index] = normalised(text, for: index)
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

    public static func readback(_ candidate: String) -> String {
        "You mentioned \(candidate). Is that right, or would you like to add anything?"
    }

    private func normalised(_ text: String, for i: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return questions[i].kind == .dateOfBirth ? AnswerFormatting.isoDOB(from: trimmed) ?? trimmed : trimmed
    }

    private mutating func advance(from i: Int) {
        if i + 1 == questions.count { phase = .review }
        else if candidates[i + 1] != nil { phase = .confirmingCandidate(i + 1) }
        else { phase = .asking(i + 1) }
    }
}
