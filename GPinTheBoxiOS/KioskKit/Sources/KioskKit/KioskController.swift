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

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case kiosk, patient }
    public let id: Int
    public let role: Role
    public let text: String
}

@MainActor @Observable public final class KioskController {
    public var submitter: Submitter?
    public private(set) var flow = IntakeFlow()
    public private(set) var caption = ""
    public private(set) var isListening = false
    public private(set) var isAskingStillThere = false
    public private(set) var transcript = ""
    public private(set) var lastError: String?
    /// The conversation so far, for display: what the kiosk asked and what was recorded for each answer.
    public private(set) var messages: [ChatMessage] = []
    public var inputMode: InputMode {
        didSet {
            guard inputMode != oldValue else { return }
            noteActivity()
            guard case .asking = flow.phase else { return }
            runSession(inputMode == .voice ? .listen : .wait)
        }
    }

    private static let unreachable = "Couldn't reach the clinic — ask reception"
    private enum Entry { case ask, listen, append, prefill, wait }
    private let speaker: any QuestionSpeaker
    private let listener: (any AnswerListener)?
    private let tidier: AnswerTidier
    private let timings: KioskTimings
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var doneTask: Task<Void, Never>?
    @ObservationIgnored private var wiping: Task<Void, Never>?
    private var generation = 0
    private var appendsTyped = false
    private var listeningAppends = false
    private var promptedPhase: FlowPhase?
    private var nextMessageID = 0
    private var submissionID: UUID?

    public init(speaker: any QuestionSpeaker, listener: (any AnswerListener)?, tidier: AnswerTidier, timings: KioskTimings = .standard) {
        self.speaker = speaker; self.listener = listener; self.tidier = tidier; self.timings = timings
        inputMode = listener == nil ? .typing : .voice
    }

    public func start() {
        guard submitter != nil, flow.phase == .welcome else { return }
        flow.start(); showPrompt(); noteActivity(); runSession(.ask)
    }

    /// The **Done** button: ends the listen the way silence does, so the answer is kept.
    public func finishAnswer() {
        guard isListening, let listener else { return }
        noteActivity(); Task { await listener.stop() }
    }

    public func repeatQuestion() { noteActivity(); if flow.currentIndex != nil { showPrompt(force: true); runSession(.ask) } }
    public func skip() {
        noteActivity()
        guard let i = flow.currentIndex, flow.skip() else { return }
        record(i); showPrompt(); runSession(.ask)
    }

    public func submitTyped(_ text: String) {
        guard let i = flow.currentIndex else { return }
        noteActivity()
        if appendsTyped, case .confirmingCandidate = flow.phase { flow.appendToCandidate(text) }
        else if !flow.answer(text) { showPrompt(force: true); return runSession(.ask) }
        record(i); showPrompt(); appendTranscript(text); runSession(.prefill)
    }

    /// The patient started typing while the mic was open: drop the spoken attempt (nothing is submitted) and wait for the typed answer.
    public func beginTyping() {
        guard isListening, let listener else { return }
        noteActivity()
        sessionTask?.cancel(); sessionTask = nil; generation += 1
        isListening = false; caption = ""; appendsTyped = listeningAppends
        Task { await listener.stop() }
    }

    public func confirmCandidate() {
        guard case .confirmingCandidate(let i) = flow.phase else { return }
        noteActivity(); flow.confirmCandidate(); record(i); showPrompt(); runSession(.ask)
    }

    public func addToCandidate() {
        guard case .confirmingCandidate = flow.phase else { return }
        noteActivity()
        if inputMode == .typing { appendsTyped = true } else { runSession(.append) }
    }
    public func replaceCandidate() { if case .confirmingCandidate = flow.phase { noteActivity(); runSession(.listen) } }

    public func edit(_ index: Int, to text: String) { noteActivity(); flow.edit(index, to: text) }

    /// Re-records one answer from review. Voice mode only: in typing mode the patient edits the answer instead.
    public func respeak(_ index: Int) {
        guard flow.phase == .review, inputMode == .voice, flow.questions.indices.contains(index) else { return }
        noteActivity()
        startSession { [self] gen in
            let heard: String
            do { guard let h = try await listen(gen), !h.isEmpty else { return }; heard = h }
            catch { inputMode = .typing; return }
            let text = await tidier.tidy(heard, for: flow.questions[index])
            guard isLive(gen) else { return }
            flow.edit(index, to: text)
        }
    }

    public func send() {
        guard flow.phase != .sending else { return }
        noteActivity(); flow.beginSending()
        guard flow.phase == .sending else { return }
        guard let submitter else { return flow.sendFailed(Self.unreachable) }
        let id = submissionID ?? UUID()
        submissionID = id; lastError = nil
        let request = flow.request(submissionID: id)
        startSession { [self] gen in
            let outcome = await submitter.submit(request)
            guard isLive(gen) else { return }
            switch outcome {
            case .accepted:
                flow.sendSucceeded(); idleTask?.cancel(); isAskingStillThere = false
                doneTask = Task { [self, delay = timings.doneReset] in if await pause(delay) { reset() } }
            case .rejected(let message):
                flow.sendFailed(message); flow.returnToReview(); lastError = message; noteActivity()
            case .unreachable:
                flow.sendFailed(Self.unreachable); noteActivity()
            }
        }
    }

    /// Restarts the idle clock and clears the "Are you still there?" prompt.
    public func noteActivity() {
        idleTask?.cancel(); idleTask = nil; isAskingStillThere = false
        guard flow.phase != .welcome, flow.phase != .done else { return }
        idleTask = Task { [self, idle = timings.idle, grace = timings.idleGrace] in
            guard await pause(idle), countsIdle else { return }
            isAskingStillThere = true
            if await pause(grace) { reset() }
        }
    }

    public func stillHere() { noteActivity() }

    public func reset() {
        sessionTask?.cancel(); sessionTask = nil; generation += 1
        idleTask?.cancel(); idleTask = nil; doneTask?.cancel(); doneTask = nil
        let previous = wiping
        wiping = Task { [speaker, listener, tidier] in
            await previous?.value; await speaker.stop(); await listener?.stop(); await tidier.reset()
        }
        flow = IntakeFlow(); caption = ""; transcript = ""; lastError = nil; submissionID = nil
        isListening = false; isAskingStillThere = false; appendsTyped = false
        messages = []; promptedPhase = nil
        inputMode = listener == nil ? .typing : .voice
    }

    private var countsIdle: Bool {
        switch flow.phase { case .welcome, .sending, .done: false; default: true }
    }

    private func pause(_ delay: Duration) async -> Bool { (try? await Task.sleep(for: delay)) != nil && !Task.isCancelled }

    private func isLive(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func runSession(_ entry: Entry) { startSession { [self] gen in await loop(gen, entry) } }

    /// Replaces the running session task; the body must check `isLive(gen)` after every await before writing state.
    private func startSession(_ body: @escaping @MainActor (Int) async -> Void) {
        let interrupting = sessionTask != nil
        sessionTask?.cancel(); generation += 1; isListening = false; appendsTyped = false
        let gen = generation, wiping = wiping
        sessionTask = Task {
            await wiping?.value
            if interrupting { await speaker.stop(); await listener?.stop() }
            guard isLive(gen) else { return }
            await body(gen)
        }
    }

    private func loop(_ gen: Int, _ first: Entry) async {
        var entry = first
        while isLive(gen), entry != .wait, let i = flow.currentIndex {
            if entry == .ask {
                let confirming = flow.phase == .confirmingCandidate(i)
                await speaker.speak(confirming ? readback(i) : flow.questions[i].text)
                guard isLive(gen), !confirming, inputMode == .voice else { return }
            }
            if entry == .prefill {
                let found = await prefill(from: i)
                guard isLive(gen) else { return }
                flow.addCandidates(found); showPrompt(); entry = .ask; continue
            }
            guard inputMode == .voice else { return }
            listeningAppends = entry == .append
            let heard: String
            do { guard let h = try await listen(gen) else { return }; heard = h }
            catch { inputMode = .typing; appendsTyped = entry == .append; return }
            appendTranscript(heard)
            let text = heard.isEmpty ? "" : await tidier.tidy(heard, for: flow.questions[i])
            // Prefill runs before the answer lands, so the phase change and the next question are back to back.
            let found = text.isEmpty && entry != .append ? [:] : await prefill(from: i + 1)
            guard isLive(gen) else { return }
            if entry == .append { flow.appendToCandidate(text) }
            else if !flow.answer(text) { showPrompt(force: true); entry = .ask; continue }
            record(i); flow.addCandidates(found); showPrompt(); entry = .ask
        }
    }

    /// Logs the current question, or the readback when confirming, once per phase (again when `force`d by a re-ask).
    private func showPrompt(force: Bool = false) {
        guard let i = flow.currentIndex, force || promptedPhase != flow.phase else { return }
        promptedPhase = flow.phase
        say(.kiosk, flow.phase == .confirmingCandidate(i) ? readback(i) : flow.questions[i].text)
    }

    /// The candidate read back for question `i`; a date of birth is read as "1 May 1980", never as the stored ISO text.
    private func readback(_ i: Int) -> String { IntakeFlow.readback(readable(flow.candidates[i] ?? "", for: i)) }

    private func readable(_ value: String, for i: Int) -> String {
        flow.questions[i].kind == .dateOfBirth ? AnswerFormatting.readableDOB(value) ?? value : value
    }

    private func record(_ i: Int) { say(.patient, flow.answers[i].isEmpty ? "Skipped" : readable(flow.answers[i], for: i)) }

    private func say(_ role: ChatMessage.Role, _ text: String) {
        nextMessageID += 1; messages.append(ChatMessage(id: nextMessageID, role: role, text: text))
    }

    private func prefill(from index: Int) async -> [Int: String] {
        let remaining = flow.questions.filter { $0.id >= index && flow.answers[$0.id].isEmpty }
        return remaining.isEmpty ? [:] : await tidier.prefill(transcript: transcript, remaining: remaining)
    }

    /// Listens until the stream ends; returns the last finalized text, or nil if the session moved on. Throws if listening failed.
    private func listen(_ gen: Int) async throws -> String? {
        guard let listener else { return nil }
        caption = ""; isListening = true
        var heard = "", silence: Task<Void, Never>?
        do {
            for try await event in listener.listen() {
                guard isLive(gen) else { break }
                noteActivity()
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
        } catch {
            silence?.cancel()
            guard isLive(gen) else { return nil }
            isListening = false; throw error
        }
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
