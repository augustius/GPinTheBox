import Foundation
import Observation

public struct KioskTimings: Sendable {
    public var silence, idle, idleGrace, doneReset, cantProceedReset: Duration
    public init(silence: Duration, idle: Duration, idleGrace: Duration, doneReset: Duration, cantProceedReset: Duration) {
        self.silence = silence; self.idle = idle; self.idleGrace = idleGrace; self.doneReset = doneReset
        self.cantProceedReset = cantProceedReset
    }
    public static let standard = KioskTimings(silence: .milliseconds(1500), idle: .seconds(120), idleGrace: .seconds(20),
                                              doneReset: .seconds(5), cantProceedReset: .seconds(10))
}

/// `.voice` is the spoken conversation; `.typing` is quiet mode (nothing spoken, mic only on request).
public enum InputMode: Sendable { case voice, typing }

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case kiosk, patient }
    public let id: Int
    public let role: Role
    /// For the patient, the raw reply as spoken or typed.
    public let text: String
    /// Patient messages only: the answers this reply filled, by question index; `""` means answered "none".
    public internal(set) var picked: [Int: String] = [:]
}

@MainActor @Observable public final class KioskController {
    public var submitter: Submitter?
    public private(set) var flow = IntakeFlow()
    public private(set) var caption = ""
    public private(set) var isListening = false
    public private(set) var isAskingStillThere = false
    /// A reply (typed or spoken) is being digested; only a newer reply or `reset()` may replace the session meanwhile.
    public private(set) var isDigesting = false
    public private(set) var lastError: String?
    /// Text heard by `dictate()`, for the composer to take and then `clearDictation()`.
    public private(set) var dictated = ""
    /// The conversation so far: the kiosk's lines and the patient's replies.
    public private(set) var messages: [ChatMessage] = []
    public var speechAvailable: Bool { listener != nil }
    /// ↻ is available: a target is being asked, no reply is pending, and its ask limit isn't used up.
    public var canRephrase: Bool {
        guard !isDigesting, let t = flow.currentIndex else { return false }
        return flow.askCounts[t] < (flow.questions[t].isRequired ? IntakeFlow.requiredAskLimit : IntakeFlow.optionalAskLimit)
    }
    public var latestKioskMessageID: Int? { messages.last { $0.role == .kiosk }?.id }
    public var inputMode: InputMode {
        didSet {
            guard inputMode != oldValue else { return }
            noteActivity()
            switch flow.phase {
            case .asking where !isDigesting: runTurn(speaking: inputMode == .voice ? latestKioskLine : nil)
            case .cantProceed where inputMode == .typing: runTurn(speaking: nil)
            case .review where inputMode == .typing: cancelRespeak()
            default: break
            }
        }
    }

    private static let unreachable = "Couldn't reach the clinic — ask reception"
    private let speaker: any QuestionSpeaker
    private let listener: (any AnswerListener)?
    private let tidier: AnswerTidier
    private let timings: KioskTimings
    private let seed: UInt64?
    @ObservationIgnored private var lines = CasualLines(seed: 0)
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var autoReset: Task<Void, Never>?
    @ObservationIgnored private var wiping: Task<Void, Never>?
    private var generation = 0
    private var respeakGeneration: Int?
    /// The question the patient is typing a draft for: the mic stays closed for it until they submit or clear the draft.
    private var typingAt: Int?
    private var isSpeaking = false
    private var nextMessageID = 0
    private var submissionID: UUID?

    public init(speaker: any QuestionSpeaker, listener: (any AnswerListener)?, tidier: AnswerTidier,
                timings: KioskTimings = .standard, seed: UInt64? = nil) {
        self.speaker = speaker; self.listener = listener; self.tidier = tidier; self.timings = timings; self.seed = seed
        inputMode = listener == nil ? .typing : .voice
    }

    public func start() {
        guard submitter != nil, flow.phase == .welcome else { return }
        lines = CasualLines(seed: seed ?? UInt64.random(in: .min ... .max))
        flow.start(); noteActivity()
        guard let t = flow.currentIndex else { return }
        post(lines.ask(flow.questions[t], attempt: 0, name: nil, opening: true))
    }

    public func submitTyped(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = flow.currentIndex, !text.isEmpty else { return }
        noteActivity(); typingAt = nil
        let id = say(.patient, text)
        startSession { [self] gen in await digest(text, id: id, target: t, gen: gen) }
        isDigesting = true
    }

    /// The **Done** button: ends the listen the way silence does, so the reply is kept.
    public func finishAnswer() {
        guard isListening, let listener else { return }
        noteActivity(); Task { await listener.stop() }
    }

    /// The patient started a draft: the mic stays closed for this question. An open listen is dropped without submitting.
    public func beginTyping() {
        guard let i = flow.currentIndex else { return }
        typingAt = i
        guard isListening, let listener else { return }
        noteActivity()
        sessionTask?.cancel(); sessionTask = nil; generation += 1
        isListening = false; caption = ""
        Task { await listener.stop() }
    }

    /// The draft was cleared: in voice mode the mic reopens, without speaking the line again.
    public func endTyping() {
        typingAt = nil
        guard inputMode == .voice, case .asking = flow.phase, !isDigesting, !isSpeaking, !isListening else { return }
        noteActivity(); runTurn(speaking: nil)
    }

    /// Speaks the latest kiosk line again (also in quiet mode). Not an ask, and nothing is logged.
    public func speakAgain() {
        guard !isDigesting, let line = latestKioskLine else { return }
        switch flow.phase { case .asking, .cantProceed: break; default: return }
        noteActivity(); runTurn(speaking: line, evenWhenQuiet: true)
    }

    /// Asks for the current question another way; counts as an ask.
    public func rephrase() {
        guard canRephrase, let t = flow.currentIndex else { return }
        noteActivity()
        post(lines.ask(flow.questions[t], attempt: max(flow.askCounts[t], 1), name: name, opening: false))
    }

    /// Listens once and leaves the text in `dictated` for the composer; nothing is submitted.
    public func dictate() {
        guard !isDigesting, listener != nil, let t = flow.currentIndex else { return }
        noteActivity(); typingAt = t
        startSession { [self] gen in
            do { guard let heard = try await listen(gen) else { return }; dictated = heard }
            catch { inputMode = .typing }
        }
    }

    public func clearDictation() { dictated = "" }

    /// A chip or review edit of an answer already given. A re-record still open is dropped first, so late speech can't overwrite it.
    public func edit(_ index: Int, to text: String) {
        guard flow.questions.indices.contains(index) else { return }
        switch flow.phase {
        case .asking: guard flow.isAnswered(index) else { return }
        case .review: break
        default: return
        }
        noteActivity(); cancelRespeak(); flow.edit(index, to: text)
        if let m = messages.lastIndex(where: { $0.picked[index] != nil }) {
            messages[m].picked[index] = flow.isAnswered(index) ? flow.answers[index] : nil
        }
        // A cleared required answer ahead of the target becomes the target.
        guard !isDigesting, case .asking(let t) = flow.phase, !flow.isAnswered(index), index < t else { return }
        flow.advance(); proceed(acknowledging: false)
    }

    /// Ends a review re-record without keeping anything heard (the edit sheet closed, or the patient typed instead).
    public func cancelRespeak() {
        guard let gen = respeakGeneration, gen == generation else { return }
        respeakGeneration = nil
        sessionTask?.cancel(); sessionTask = nil; generation += 1
        isListening = false; caption = ""
        if let listener { Task { await listener.stop() } }
    }

    /// Re-records one answer from review. Voice mode only: in quiet mode the patient edits the answer instead.
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
        respeakGeneration = generation
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
                scheduleReset(after: timings.doneReset)
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
        idleTask?.cancel(); idleTask = nil; autoReset?.cancel(); autoReset = nil
        let previous = wiping
        wiping = Task { [speaker, listener, tidier] in
            await previous?.value; await speaker.stop(); await listener?.stop(); await tidier.reset()
        }
        flow = IntakeFlow(); caption = ""; dictated = ""; lastError = nil; submissionID = nil
        isListening = false; isSpeaking = false; isDigesting = false; isAskingStillThere = false; typingAt = nil
        messages = []
        inputMode = listener == nil ? .typing : .voice
    }

    private var countsIdle: Bool {
        switch flow.phase { case .welcome, .cantProceed, .sending, .done: false; default: true }
    }

    private var name: String? { flow.isAnswered(0) ? CasualLines.firstName(from: flow.answers[0]) : nil }

    private var latestKioskLine: String? { messages.last { $0.role == .kiosk }?.text }

    private func pause(_ delay: Duration) async -> Bool { (try? await Task.sleep(for: delay)) != nil && !Task.isCancelled }

    private func isLive(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func scheduleReset(after delay: Duration) {
        autoReset?.cancel()
        autoReset = Task { [self] in if await pause(delay) { reset() } }
    }

    /// Replaces the running session task; the body must check `isLive(gen)` after every await before writing state.
    private func startSession(_ body: @escaping @MainActor (Int) async -> Void) {
        let interrupting = sessionTask != nil
        sessionTask?.cancel(); generation += 1; isListening = false; isSpeaking = false; isDigesting = false
        let gen = generation, wiping = wiping
        sessionTask = Task {
            await wiping?.value
            if interrupting { await speaker.stop(); await listener?.stop() }
            guard isLive(gen) else { return }
            await body(gen)
        }
    }

    /// Logs a line that asks for the current target (one ask), then speaks it and listens for the reply.
    private func post(_ line: String) {
        say(.kiosk, line); flow.noteAsked(); runTurn(speaking: line)
    }

    /// Speaks `line` (in voice mode, or always when `evenWhenQuiet`), then in voice mode listens for a reply unless a draft is being typed.
    private func runTurn(speaking line: String?, evenWhenQuiet: Bool = false) {
        let speaks = line != nil && (evenWhenQuiet || inputMode == .voice)
        startSession { [self] gen in
            if speaks, let line {
                await speaker.speak(CasualLines.spoken(line))
                guard isLive(gen) else { return }
                isSpeaking = false
            }
            guard inputMode == .voice, let t = flow.currentIndex, typingAt != t else { return }
            let heard: String
            do { guard let h = try await listen(gen) else { return }; heard = h }
            catch { inputMode = .typing; return }
            if heard.isEmpty { flow.advance(); return proceed(acknowledging: false) }
            let id = say(.patient, heard)
            isDigesting = true
            await digest(heard, id: id, target: t, gen: gen)
        }
        isSpeaking = speaks
    }

    private func digest(_ reply: String, id: Int, target t: Int, gen: Int) async {
        let d = await tidier.digest(reply: reply, target: flow.questions[t], unanswered: flow.unanswered, answers: flow.recordedAnswers)
        guard isLive(gen) else { return }
        isDigesting = false
        var applied = flow.record(d.values)
        if d.skippedTarget { flow.markAnsweredEmpty(t); applied[t] = "" }
        if let m = messages.firstIndex(where: { $0.id == id }) { messages[m].picked = applied }
        flow.advance(); proceed(acknowledging: !applied.isEmpty)
    }

    /// Follows `flow.phase` after an advance: asks for the new target, or ends on the can't-proceed line, or stops at review.
    private func proceed(acknowledging: Bool) {
        switch flow.phase {
        case .asking(let n):
            if typingAt != nil { typingAt = n }   // a draft started meanwhile is for the new line
            post(lines.ask(flow.questions[n], attempt: flow.askCounts[n], name: name, opening: false, acknowledging: acknowledging))
        case .cantProceed(let i):
            let line = CasualLines.cantProceed(flow.questions[i])
            say(.kiosk, line); runTurn(speaking: line)
            scheduleReset(after: timings.cantProceedReset)
        default: break
        }
    }

    @discardableResult private func say(_ role: ChatMessage.Role, _ text: String) -> Int {
        nextMessageID += 1; messages.append(ChatMessage(id: nextMessageID, role: role, text: text))
        return nextMessageID
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
        isListening = false; caption = ""
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
