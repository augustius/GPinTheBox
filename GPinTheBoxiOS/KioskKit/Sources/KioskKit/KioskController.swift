import Foundation
import Observation
import KioskProtocol

public struct KioskTimings: Sendable {
    public var silence, idle, idleGrace, doneReset: Duration
    public init(silence: Duration, idle: Duration, idleGrace: Duration, doneReset: Duration) {
        self.silence = silence; self.idle = idle; self.idleGrace = idleGrace; self.doneReset = doneReset
    }
    public static let standard = KioskTimings(silence: .milliseconds(1500), idle: .seconds(120), idleGrace: .seconds(20), doneReset: .seconds(5))
}

public enum InputMode: Sendable { case voice, typing }

@MainActor @Observable public final class KioskController {
    public var submitter: Submitter?
    public private(set) var flow = IntakeFlow()
    public private(set) var caption = ""
    public private(set) var isListening = false
    public private(set) var isAskingStillThere = false
    public private(set) var transcript = ""
    public var inputMode: InputMode {
        didSet {
            guard inputMode != oldValue, case .asking = flow.phase else { return }
            runSession(inputMode == .voice ? .listen : .wait)
        }
    }

    private enum Entry { case ask, listen, append, prefill, wait }
    private let speaker: any QuestionSpeaker
    private let listener: (any AnswerListener)?
    private let tidier: AnswerTidier
    private let timings: KioskTimings
    private var sessionTask: Task<Void, Never>?
    private var generation = 0

    public init(speaker: any QuestionSpeaker, listener: (any AnswerListener)?, tidier: AnswerTidier, timings: KioskTimings = .standard) {
        self.speaker = speaker; self.listener = listener; self.tidier = tidier; self.timings = timings
        inputMode = listener == nil ? .typing : .voice
    }

    public func start() {
        guard submitter != nil, flow.phase == .welcome else { return }
        flow.start(); runSession(.ask)
    }

    /// The **Done** button: ends the listen the way silence does, so the answer is kept.
    public func finishAnswer() {
        guard isListening, let listener else { return }
        Task { await listener.stop() }
    }

    public func repeatQuestion() { if flow.currentIndex != nil { runSession(.ask) } }
    public func skip() { if flow.skip() { runSession(.ask) } }

    public func submitTyped(_ text: String) {
        guard flow.currentIndex != nil else { return }
        guard flow.answer(text) else { return runSession(.ask) }
        appendTranscript(text); runSession(.prefill)
    }

    public func confirmCandidate() {
        guard case .confirmingCandidate = flow.phase else { return }
        flow.confirmCandidate(); runSession(.ask)
    }

    public func addToCandidate() { if case .confirmingCandidate = flow.phase { runSession(.append) } }
    public func replaceCandidate() { if case .confirmingCandidate = flow.phase { runSession(.listen) } }

    private func isLive(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func runSession(_ entry: Entry) {
        let interrupting = sessionTask != nil
        sessionTask?.cancel(); generation += 1; isListening = false
        let gen = generation
        sessionTask = Task {
            if interrupting { await speaker.stop(); await listener?.stop() }
            guard isLive(gen) else { return }
            await loop(gen, entry)
        }
    }

    private func loop(_ gen: Int, _ first: Entry) async {
        var entry = first
        while isLive(gen), entry != .wait, let i = flow.currentIndex {
            if entry == .ask {
                let confirming = flow.phase == .confirmingCandidate(i)
                await speaker.speak(confirming ? IntakeFlow.readback(flow.candidates[i] ?? "") : flow.questions[i].text)
                guard isLive(gen), !confirming, inputMode == .voice else { return }
            }
            if entry == .prefill {
                let found = await prefill(from: i)
                guard isLive(gen) else { return }
                flow.addCandidates(found); entry = .ask; continue
            }
            guard let heard = await listen(gen) else { return }
            appendTranscript(heard)
            let text = heard.isEmpty ? "" : await tidier.tidy(heard, for: flow.questions[i])
            // Prefill runs before the answer lands, so the phase change and the next question are back to back.
            let found = text.isEmpty && entry != .append ? [:] : await prefill(from: i + 1)
            guard isLive(gen) else { return }
            if entry == .append { flow.appendToCandidate(text) } else if !flow.answer(text) { entry = .ask; continue }
            flow.addCandidates(found); entry = .ask
        }
    }

    private func prefill(from index: Int) async -> [Int: String] {
        let remaining = flow.questions.filter { $0.id >= index && flow.answers[$0.id].isEmpty }
        return remaining.isEmpty ? [:] : await tidier.prefill(transcript: transcript, remaining: remaining)
    }

    /// Listens until the stream ends; returns the last finalized text, or nil if the session moved on.
    private func listen(_ gen: Int) async -> String? {
        guard let listener else { return nil }
        caption = ""; isListening = true
        var heard = "", silence: Task<Void, Never>?
        do {
            for try await event in listener.listen() {
                guard isLive(gen) else { break }
                switch event {
                case .partial(let text): caption = text
                case .final(let text): caption = text; heard = text
                }
                silence?.cancel()
                silence = Task { [delay = timings.silence] in
                    guard (try? await Task.sleep(for: delay)) != nil else { return }
                    await listener.stop()
                }
            }
        } catch {}
        silence?.cancel()
        guard isLive(gen) else { return nil }
        isListening = false
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript = transcript.isEmpty ? trimmed : transcript + " " + trimmed
    }
}
