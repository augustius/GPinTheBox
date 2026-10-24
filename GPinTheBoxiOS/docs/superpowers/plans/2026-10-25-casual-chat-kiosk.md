# Casual Chat Kiosk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the kiosk's one-question-at-a-time intake into a casual, ChatGPT-style dark chat. Each reply is mapped to any of the ten questions and shown as editable chips. Hand-written casual lines nudge for the gaps.

**Architecture:**
- **Engine:** `IntakeFlow` (pure) owns the target choice, ask counts, answered-empty markers and the "can't proceed" outcome. A new `CasualLines` (pure, seeded) supplies the hand-written lines. `AnswerTidier.digest` turns one reply into answers: model extraction over all unanswered questions, then the skip and fallback rules. `KioskController` runs the turn loop on its existing session and generation guard.
- **App:** the SwiftUI app becomes a dark chat screen with a pill composer.
- **Unchanged:** the Mac app, the wire format and the ten `q` strings.

**Tech Stack:** Swift 6.4, SwiftUI (iOS 26), Swift Testing, FoundationModels, Speech/AVFoundation (existing adapters). `swift test --package-path GPinTheBoxiOS/KioskKit` runs on the Mac.

**Spec:** `GPinTheBoxiOS/docs/superpowers/specs/2026-10-25-casual-chat-kiosk-design.md` (supersedes D5, D6 and D13 of `2026-10-24-voice-intake-kiosk-design.md`).

## Global Constraints

- **Mac side is untouched:** no Mac or wire changes. The payload stays `[{q, a}]` with the ten exact `KioskQuestions` strings, and answered-empty is sent as `a = ""`. Don't edit `KioskKit/Sources/KioskKit/Protocol/*` (it's duplicated on the Mac).
- **Ask limits:** required questions (Full name, Medicare or insurance ID, Date of birth) are asked at most **3** times; optional questions (4–10) at most **2**, then treated as skipped.
- **Ask counting:** an ask is any posted line targeting the question (first ask, nudge, ↻ rephrase). 🔊 replay is not an ask.
- **Can't-proceed line:** `Sorry, we can't proceed without your {name|Medicare or insurance ID|date of birth}. Please see reception — they can help.` It's followed by a "Please see reception" screen with **Start over**. Nothing is sent, and the session is wiped after **10 s**.
- **Extraction:** never overwrites an already-answered question. The target fallback (whole tidied reply) applies only when extraction returned nothing at all and the reply isn't a skip. DOB must parse to a valid past date and ID must normalise to non-empty, or the question stays unanswered.
- **Skip words:** a whole-reply match (case-insensitive, trailing `.!?` trimmed) of `none`, `no`, `nothing`, `nope`, `n/a`, `skip`, `pass`, `i'd rather not say`, `rather not say`, `prefer not to say`. These mark an **optional** target answered-empty and are ignored for required targets.
- **Copy rules for lines:** friendly, short, Australian English, no advice, reassurance or diagnosis. The only other answer a line may mention is the patient's first name (first whitespace token of the Full name answer).
- **Timings:** extraction timeout 5 s (existing), silence 1.5 s, idle 2 min + 20 s, done reset 5 s, can't-proceed reset 10 s.
- **Voice:** on by default for every patient. The blue button toggles quiet mode, which resets to voice per patient. If speech is unavailable, the voice and mic buttons are hidden.
- **UI colours:** always dark, background `#000000`. Patient bubble `#2f2f2f`, composer pill `#1f1f1f`, blue button `#3d6fd8`, secondary text `#8e8e8e`.
- **Disclaimer copy:** `Answers are checked by clinic staff. Synthetic data only.`
- **Field placeholder:** `Type your answer`.
- **Progress:** answered count (including answered-empty) out of 10, shown as `3 of 10`.
- **Unchanged copy kept as is:** `Tap to start.`, `Clinic not found — ask reception`, `Send to clinic`, `Couldn't reach the clinic — ask reception`, `Thanks, please take a seat.`, `Are you still there?`.

## Prerequisite (before Task 1)

The user's uncommitted Xcode edits to `GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj/project.pbxproj` and `GPinTheBoxiOS/GPInTheBoxKiosk/Info.plist` move the usage strings into build settings and reformat the project. They must be committed, with the user's consent, or set aside before execution, because Task 5 edits that project file.

## Review Focus

1. **Asked for one thing, answered another.** Asked for the name, the patient says "I've had a cough since Monday". The cough fills Reason and Started; the name stays unanswered and is asked again; nothing is written into Name. Test: Task 3 `extractionWithoutTargetDoesNotFillTarget`, Task 4 `answeringAnotherQuestionReasksTarget`.
2. **A skip word to a required question.** "pass" when asked for the ID is re-asked, and after the third unanswered ask the flow goes to can't-proceed with nothing sent. Test: Task 2 `requiredUnansweredAfterThreeAsksCantProceed`, Task 4 `cantProceedSendsNothingAndWipes`.
3. **Chip edited mid-turn.** A chip edited while the kiosk speaks or listens is kept. Clearing a required chip makes it the next target with its count reset. Test: Task 2 `clearingRequiredResetsAskCount`, Task 4 `chipEditDuringListenIsKept`.
4. **Reset or idle during a digest.** A late digest attaches no chips and writes no answers into the next patient's session. Test: Task 4 `resetDuringDigestDropsChips`.
5. **Model returns an already-answered question.** The extracted value for a question answered earlier is ignored, and the chip isn't shown. Test: Task 2 `recordNeverOverwritesAnswered`.

---

## File Structure

```
GPinTheBoxiOS/KioskKit/Sources/KioskKit/
├── CasualLines.swift              NEW  line bank, rotation, chip labels, spoken-text helper
├── IntakeFlow.swift               MODIFY  target choice, ask counts, answered-empty, cantProceed; drop candidates/read-back
├── AnswerTidier.swift             MODIFY  prefill → extract; new digest(reply:target:unanswered:)
├── FoundationModelsAnswerModel.swift  MODIFY  extraction prompt (tidied, any question)
└── KioskController.swift          MODIFY  conversation loop, chips, quiet toggle, dictation, 🔊/↻, cantProceed
GPinTheBoxiOS/KioskKit/Tests/KioskKitTests/
├── CasualLinesTests.swift         NEW
├── IntakeFlowTests.swift          REWRITE for new flow
├── AnswerTidierTests.swift        MODIFY (prefill tests → extract/digest)
├── KioskControllerQuestionTests.swift  REWRITE → conversation tests
├── ChatLogTests.swift             REWRITE for chips
├── KioskControllerSessionTests.swift  MODIFY (helpers, cantProceed)
└── Fakes.swift                    MODIFY (prefill → extract, KioskTimings.test gains cantProceedReset)
GPinTheBoxiOS/GPInTheBoxKiosk/
├── ChatView.swift                 NEW (replaces QuestionView.swift)
├── AnswerEditSheet.swift          NEW (shared by chips and review; moved out of ReviewView)
├── Theme.swift                    NEW colours + dark styling helpers
├── ReviewView.swift, WelcomeView.swift, StaffSetupView.swift, KioskApp.swift  MODIFY (dark restyle, routing, cantProceed screen)
└── QuestionView.swift             DELETE
README.md                          MODIFY patient-flow paragraph + manual checklist
```

---

### Task 1: Casual line bank

**Files:**
- Create: `GPinTheBoxiOS/KioskKit/Sources/KioskKit/CasualLines.swift`
- Test: `GPinTheBoxiOS/KioskKit/Tests/KioskKitTests/CasualLinesTests.swift`

**Interfaces:**
- Produces:
  - `public struct CasualLines: Sendable`
    - `public init(seed: UInt64)`: deterministic. Uses a SplitMix64 generator stored in the struct.
    - `public mutating func ask(_ q: KioskQuestion, attempt: Int, name: String?, opening: Bool) -> String`
      - `attempt == 0` picks from the first-ask variants and `attempt >= 1` from the re-ask variants.
      - Never returns the variant last used for that question unless only one exists.
      - Replaces `{name}` with `name`. A variant containing `{name}` is only eligible when `name != nil`.
      - `opening == true` prefixes `Hey! 👋 Thanks for coming in. `.
    - `public mutating func acknowledgement(name: String?) -> String`: from a pool, e.g. `Got it.`, `Perfect.`, `Thanks, {name}.` (name variant only when `name != nil`).
    - `public static func cantProceed(_ q: KioskQuestion) -> String`: exact copy from Global Constraints. The field words are `name` (fullName), `Medicare or insurance ID` (identifier) and `date of birth` (dateOfBirth).
    - `public static func spoken(_ line: String) -> String`: removes emoji scalars (`properties.isEmojiPresentation`, or `isEmoji` and not ASCII), and collapses double spaces.
    - `static let firstAsk: [[String]]` and `static let reAsk: [[String]]`, indexed by `KioskQuestion.id`.
  - `public enum ChipLabel { public static func text(for q: KioskQuestion) -> String }`. Labels in id order: `Name, ID, Born, Reason, Started, Symptoms, Medications, Allergies, Conditions, Other`.
  - `public static func firstName(from fullName: String) -> String?` on `CasualLines`: the first whitespace token, or nil if blank.
- The builder writes the copy itself within the Global Constraints copy rules. The user reviews it before release.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import KioskKit

@Test func everyQuestionHasEnoughVariants() {
    for q in KioskQuestions.all {
        #expect(CasualLines.firstAsk[q.id].count >= 3); #expect(CasualLines.reAsk[q.id].count >= 2)
    }
}
@Test func linesGiveNoAdvice() {
    let deny = ["should", "recommend", "don't worry", "it's probably", "normal", "diagnos", "nothing serious"]
    for line in (CasualLines.firstAsk + CasualLines.reAsk).flatMap({ $0 }) {
        for word in deny { #expect(!line.lowercased().contains(word), "\(line)") }
    }
}
@Test func rotationNeverRepeatsBackToBack() {
    var lines = CasualLines(seed: 7); let q = KioskQuestions.all[3]
    var last = ""
    for _ in 0..<20 { let l = lines.ask(q, attempt: 0, name: "Jane", opening: false); #expect(l != last); last = l }
}
@Test func seededRotationIsDeterministic() {
    var a = CasualLines(seed: 42), b = CasualLines(seed: 42)
    for q in KioskQuestions.all { #expect(a.ask(q, attempt: 1, name: nil, opening: false) == b.ask(q, attempt: 1, name: nil, opening: false)) }
}
@Test func nameIsSubstitutedOnlyWhenKnown() {
    var lines = CasualLines(seed: 1)
    for _ in 0..<30 {
        #expect(!lines.ask(KioskQuestions.all[4], attempt: 0, name: nil, opening: false).contains("{name}"))
        #expect(!lines.acknowledgement(name: nil).contains("{name}"))
    }
    #expect(CasualLines.firstName(from: "  Jane Demo ") == "Jane"); #expect(CasualLines.firstName(from: " ") == nil)
}
@Test func openingAndCantProceedCopy() {
    var lines = CasualLines(seed: 3)
    #expect(lines.ask(KioskQuestions.fullName, attempt: 0, name: nil, opening: true).hasPrefix("Hey! 👋 Thanks for coming in. "))
    #expect(CasualLines.cantProceed(KioskQuestions.identifier) == "Sorry, we can't proceed without your Medicare or insurance ID. Please see reception — they can help.")
    #expect(CasualLines.cantProceed(KioskQuestions.dateOfBirth).contains("without your date of birth."))
    #expect(CasualLines.spoken("Hey! 👋 Thanks for coming in.") == "Hey! Thanks for coming in.")
    #expect(KioskQuestions.all.map(ChipLabel.text(for:)) == ["Name", "ID", "Born", "Reason", "Started", "Symptoms", "Medications", "Allergies", "Conditions", "Other"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter CasualLines`
Expected: FAIL to compile (`CasualLines` is undefined).

- [ ] **Step 3: Implement `CasualLines`, `ChipLabel` and `firstName` in `CasualLines.swift`**

Rotation: keep `lastUsed: [Int: String]` and pick uniformly from eligible variants minus the last used.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all tests pass (67 existing + 6 new), with no warnings.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit/Sources/KioskKit/CasualLines.swift GPinTheBoxiOS/KioskKit/Tests/KioskKitTests/CasualLinesTests.swift
git commit -m "feat: add the kiosk's casual line bank"
```

---

### Task 2: IntakeFlow — targets, ask counts, can't proceed

**Files:**
- Modify: `GPinTheBoxiOS/KioskKit/Sources/KioskKit/IntakeFlow.swift`
- Test: rewrite `GPinTheBoxiOS/KioskKit/Tests/KioskKitTests/IntakeFlowTests.swift`. Keep the DOB normalisation, `canSend`, `request` and sending-transition tests, and delete the candidate/read-back ones.

**Interfaces:**
- Produces:
  - `public enum FlowPhase: Equatable, Sendable { case welcome, asking(Int), review, cantProceed(Int), sending, sendFailed(String), done }`. `confirmingCandidate` is removed, and `asking(i)` means the current target is `i`.
  - `public struct IntakeFlow` keeps `questions`, `answers`, `phase`, `canSend`, `request(submissionID:)`, `beginSending`, `sendSucceeded`, `sendFailed`, `returnToReview` and `currentIndex` (now only `.asking(i)`).
  - Removed: `candidates`, `addCandidates`, `confirmCandidate`, `appendToCandidate`, `answer`, `skip`, `readback`.
  - New:
    - `public private(set) var askCounts: [Int]`
    - `public func isAnswered(_ i: Int) -> Bool`: non-empty, or answered-empty.
    - `public func isAnsweredEmpty(_ i: Int) -> Bool`
    - `public var answeredCount: Int`
    - `public var unanswered: [KioskQuestion]`
    - `public mutating func start()`: `welcome` → `advance()`.
    - `public mutating func noteAsked()`: increments `askCounts[current target]`.
    - `@discardableResult public mutating func record(_ values: [Int: String]) -> [Int: String]`. Applies only to unanswered indices, and normalises (DOB via `isoDOB`, trimming). Drops values that are blank after normalising. Returns what was applied.
    - `public mutating func markAnsweredEmpty(_ i: Int)`: optional questions only.
    - `public mutating func advance()`: the target rule below.
    - `public mutating func edit(_ i: Int, to text: String)`. Allowed in `.asking` and `.review`, and normalises. Clearing a **required** answer makes it unanswered with `askCounts[i] = 0`. Clearing an **optional** one makes it answered-empty.
- `advance()` rule:

```text
for each required q in id order, if unanswered:
    askCounts[q] >= 3 ? phase = .cantProceed(q) : phase = .asking(q); return
for each optional q in id order, if unanswered:
    if askCounts[q] >= 2 { mark answered-empty; continue }
    phase = .asking(q); return
phase = .review
```

- [ ] **Step 1: Write the failing tests** (in `IntakeFlowTests.swift`, alongside the kept tests)

```swift
@Test func targetsRequiredFirstThenOptionalInOrder() {
    var f = IntakeFlow(); f.start(); #expect(f.phase == .asking(0))
    f.record([3: "Cough", 0: "Jane Demo"]); f.advance(); #expect(f.phase == .asking(1))
    f.record([1: "DEMO001", 2: "1/5/1980"]); f.advance(); #expect(f.phase == .asking(4))
    #expect(f.answers[2] == "1980-05-01" && f.answeredCount == 4)
}
@Test func recordNeverOverwritesAnswered() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane Demo"])
    #expect(f.record([0: "Jon", 3: "  "]) == [:]); #expect(f.answers[0] == "Jane Demo")
}
@Test func optionalAskedTwiceThenSkipped() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane", 1: "D1", 2: "1980-05-01"]); f.advance()
    #expect(f.phase == .asking(3)); f.noteAsked(); f.advance(); #expect(f.phase == .asking(3))
    f.noteAsked(); f.advance(); #expect(f.phase == .asking(4)); #expect(f.isAnsweredEmpty(3))
}
@Test func requiredUnansweredAfterThreeAsksCantProceed() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane"]); f.advance()
    for _ in 0..<2 { f.noteAsked(); f.advance(); #expect(f.phase == .asking(1)) }
    f.noteAsked(); f.advance(); #expect(f.phase == .cantProceed(1))
}
@Test func clearingRequiredResetsAskCount() {
    var f = IntakeFlow(); f.start(); f.noteAsked(); f.record([0: "Jane", 1: "D1"]); f.advance()
    f.edit(0, to: " "); #expect(!f.isAnswered(0) && f.askCounts[0] == 0)
    f.edit(3, to: ""); #expect(f.isAnsweredEmpty(3))
    f.advance(); #expect(f.phase == .asking(0))
}
@Test func answeredEmptySendsEmptyString() {
    var f = IntakeFlow(); f.start(); f.record([0: "Jane", 1: "D1", 2: "1980-05-01"])
    f.markAnsweredEmpty(7); f.markAnsweredEmpty(0)
    #expect(f.isAnsweredEmpty(7) && !f.isAnsweredEmpty(0))
    #expect(f.request(submissionID: UUID()).answers[7].a == "")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter IntakeFlow`
Expected: FAIL to compile (`record`, `advance`, `noteAsked` and `cantProceed` don't exist yet).

- [ ] **Step 3: Implement the new `IntakeFlow` API and remove the candidate API.** Callers in `KioskController` will break; Task 4 rewires them. For this task only, update `KioskController` minimally so it compiles: replace removed calls with the nearest new equivalent, or stub with `// Task 4`. Note what was stubbed in the commit message.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter "IntakeFlow|DOBParsing|KioskProtocol|CasualLines"`
Expected: PASS. Controller tests may fail until Task 4; the task-done command is the filter above.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: target unanswered questions with ask limits in IntakeFlow"
```

---

### Task 3: Digesting a reply

**Files:**
- Modify: `GPinTheBoxiOS/KioskKit/Sources/KioskKit/AnswerTidier.swift`, `FoundationModelsAnswerModel.swift`, `Tests/KioskKitTests/Fakes.swift`
- Test: `Tests/KioskKitTests/AnswerTidierTests.swift` (rename the prefill tests to extract; add digest tests)

**Interfaces:**
- Consumes: Task 2's `IntakeFlow` isn't needed. The digest is pure over questions.
- Produces:
  - `AnswerModel` protocol: `prefill(transcript:remaining:)` is renamed `extract(reply: String, unanswered: [KioskQuestion]) async throws -> [Int: String]`. `tidy` is unchanged.
  - `AnswerTidier`:
    - `prefill` is renamed `extract(reply:unanswered:) async -> [Int: String]`, with the same validation, timeout, cancellation and disable rules as today's `prefill`. `prefillEnabled` is renamed `extractionEnabled`.
    - Add `public static func isSkip(_ reply: String) -> Bool`, using the skip-word list from Global Constraints.
    - Add `public func digest(reply: String, target: KioskQuestion, unanswered: [KioskQuestion]) async -> ReplyDigest`.
  - `public struct ReplyDigest: Equatable, Sendable { public var values: [Int: String]; public var skippedTarget: Bool }`
  - `digest` rule:

```text
if !target.isRequired && isSkip(reply) → (values: [:], skippedTarget: true)
found = await extract(reply, unanswered)            // includes target
if !found.isEmpty → (found, false)
if isSkip(reply) → ([:], false)                      // required target: ignored, re-asked
t = await tidy(reply, for: target)
switch target.kind: dateOfBirth → isoDOB(t) valid past ? [target: iso] : [:]
                    identifier  → normaliseIdentifier(t) non-empty ? [target: it] : [:]
                    else        → t non-empty ? [target: t] : [:]
```

  - `FoundationModelsAnswerModel.extract`: same `@Generable` result, with the prompt changed to "…which of these questions does the patient's reply answer? For each, give the answer in the patient's own words with filler words removed…". Instructions still forbid adding information, guessing and advice.
  - Fakes: `FakeAnswerModel(isAvailable:tidied:extracted:delay:error:)`. `extracted` is renamed from `prefill`; `extract` returns it filtered to the `unanswered` ids.

- [ ] **Step 1: Write the failing tests**

```swift
let q = KioskQuestions.all
@Test func digestUsesExtractionAcrossQuestions() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"]))
    let d = await t.digest(reply: "I'm Jane Demo, cough since Monday", target: q[0], unanswered: q)
    #expect(d == ReplyDigest(values: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"], skippedTarget: false))
}
@Test func extractionWithoutTargetDoesNotFillTarget() async {
    let t = AnswerTidier(model: FakeAnswerModel(extracted: [3: "Cough"]))
    let d = await t.digest(reply: "I've got a cough", target: q[0], unanswered: q)
    #expect(d.values == [3: "Cough"])
}
@Test func fallbackFillsTargetOnlyWhenNothingExtracted() async {
    let t = AnswerTidier(model: FakeAnswerModel(isAvailable: false))
    #expect(await t.digest(reply: " a dry cough ", target: q[3], unanswered: q).values == [3: "a dry cough"])
    #expect(await t.digest(reply: "1/5/1980", target: q[2], unanswered: q).values == [2: "1980-05-01"])
    #expect(await t.digest(reply: "around May", target: q[2], unanswered: q).values == [:])
    #expect(await t.digest(reply: "- / -", target: q[1], unanswered: q).values == [:])
}
@Test func skipWordsOnlySkipOptionalTargets() async {
    let t = AnswerTidier(model: FakeAnswerModel())
    #expect(await t.digest(reply: "Nope.", target: q[7], unanswered: q) == ReplyDigest(values: [:], skippedTarget: true))
    #expect(await t.digest(reply: "pass", target: q[1], unanswered: q) == ReplyDigest(values: [:], skippedTarget: false))
    #expect(AnswerTidier.isSkip("I'd rather not say!") && !AnswerTidier.isSkip("none, but I'm on aspirin"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter AnswerTidier`
Expected: FAIL to compile (`digest` and `ReplyDigest` don't exist yet).

- [ ] **Step 3: Implement the rename, `isSkip`, `digest` and the prompt change.** Update the existing prefill tests to `extract`, keeping their assertions.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter "AnswerTidier|IntakeFlow|CasualLines"`
Expected: PASS. If Apple Intelligence is available, the gated real-model test runs; it must also pass with the new prompt: "I'm Jane Demo, I've had a cough since Monday" → contains keys 0 and 3.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: digest a patient reply into answers for any question"
```

---

### Task 4: KioskController — the casual conversation

**Files:**
- Modify: `GPinTheBoxiOS/KioskKit/Sources/KioskKit/KioskController.swift`, `Tests/KioskKitTests/Fakes.swift`
- Test: rewrite `KioskControllerQuestionTests.swift` as `KioskConversationTests.swift`; rewrite `ChatLogTests.swift`; update `KioskControllerSessionTests.swift` helpers (`controllerAtReview` now reaches review by typing replies with a fake extractor).

**Interfaces:**
- Consumes: Task 1 `CasualLines`, `ChipLabel`; Task 2 `IntakeFlow` API and `FlowPhase.cantProceed`; Task 3 `AnswerTidier.digest`, `ReplyDigest`.
- Produces (public on `KioskController`):
  - `ChatMessage` gains `public internal(set) var picked: [Int: String] = [:]`. Patient messages only; a value of `""` means answered-empty, displayed as "none". The patient message `text` is the raw reply as spoken or typed.
  - `KioskTimings` gains `cantProceedReset: Duration` (standard **10 s**). The init gains that parameter, and `Fakes.swift`'s `KioskTimings.test` and `with(...)` gain it too (test value 60 s).
  - `public var speechAvailable: Bool` (`listener != nil`). `inputMode` stays: `.voice` means voice conversation and `.typing` means quiet mode. It's settable, and `reset()` restores `.voice` when speech is available.
  - `public var latestKioskMessageID: Int?`
  - `public private(set) var dictated: String`, plus `public func clearDictation()`.
  - Conversation API:
    - `start()`
    - `submitTyped(_ text: String)` (any non-blank text; empty is ignored)
    - `finishAnswer()` (Done on the live caption)
    - `beginTyping()`
    - `endTyping()`: the draft was cleared. In voice mode while `.asking`, it reopens the mic without speaking.
    - `speakAgain()`: speaks the latest kiosk line. No ask count, no message logged, and it works in quiet mode.
    - `rephrase()`: posts and speaks a new variant for the current target and counts as an ask.
    - `dictate()`: first cancels any auto-listen the way `beginTyping()` does (generation bump, then `listener.stop()`, so the cut-off stream is never submitted as a reply). It then listens once and puts the text into `dictated` without submitting, and sets `typingAt` to the target. In voice mode, auto-listen resumes after the next submit.
    - Setting `inputMode = .voice` during `.asking` keeps `typingAt`. It speaks the latest kiosk line (like `speakAgain`, with no ask count) and then listens only if `typingAt != target`. Setting `.typing` stops any listen and speech.
    - `edit(_ index: Int, to text: String)`: chip and review edits, via `flow.edit`, then updates `picked` on the message that carried that index.
  - Removed: `repeatQuestion`, `skip`, `confirmCandidate`, `addToCandidate`, `replaceCandidate`, `transcript`.
  - Kept as-is: `respeak`, `cancelRespeak`, `send`, `noteActivity`, `stillHere`, `reset`, idle behaviour, and the generation guard.
- Turn loop (one session task):

```text
post(line): say(.kiosk, line); flow.noteAsked(); if voice { await speak(CasualLines.spoken(line)) }; if voice && typingAt != target { listen }
reply(text):  id = say(.patient, text) [no chips yet]
              d = await tidier.digest(reply: text, target: flow.questions[t], unanswered: flow.unanswered)
              guard isLive(gen)
              applied = flow.record(d.values); if d.skippedTarget { flow.markAnsweredEmpty(t); applied[t] = "" }
              messages[id].picked = applied; flow.advance()
              .asking(n): line = (applied.isEmpty ? "" : lines.acknowledgement(name:) + " ") + lines.ask(q[n], attempt: flow.askCounts[n], name:, opening: false); post(line)
              .cantProceed(i): say(.kiosk, CasualLines.cantProceed(q[i])); speak if voice; schedule reset after timings.cantProceedReset
              .review: stop (no line)
start(): flow.start(); post(lines.ask(q[target], attempt: 0, name: nil, opening: true))
```

  - `name` = `CasualLines.firstName(from: flow.answers[0])` when Q0 is answered.
  - `CasualLines(seed:)` is created per session in `start()` from `UInt64.random`. Tests inject it with `init(…, seed: UInt64? = nil)` on the controller; when set, it's used for every session.
  - `countsIdle` excludes `.cantProceed` (it has its own reset timer).

- [ ] **Step 1: Write the failing tests** (`KioskConversationTests.swift`, `ChatLogTests.swift`)

```swift
@MainActor @Test func oneReplyFillsSeveralAndShowsChips() async {
    let (c, speaker) = makeController([[.final("I'm Jane Demo, cough since Monday")]],
        model: FakeAnswerModel(extracted: [0: "Jane Demo", 3: "Cough", 4: "Since Monday"]), seed: 1)
    c.start(); await eventually { c.flow.phase == .asking(1) }
    let reply = c.messages.first { $0.role == .patient }!
    #expect(reply.text == "I'm Jane Demo, cough since Monday" && reply.picked == [0: "Jane Demo", 3: "Cough", 4: "Since Monday"])
    #expect(speaker.spoken.first?.hasPrefix("Hey! Thanks for coming in.") == true)  // emoji not spoken
    #expect(c.messages.first?.text.hasPrefix("Hey! 👋") == true)
}
@MainActor @Test func answeringAnotherQuestionReasksTarget() async {
    let (c, _) = makeController([[.final("I've got a cough")]], model: FakeAnswerModel(extracted: [3: "Cough"]), seed: 1)
    c.start(); await eventually { c.flow.askCounts[0] == 2 }
    #expect(c.flow.phase == .asking(0) && c.flow.answers[0] == "" && c.flow.answers[3] == "Cough")
}
@MainActor @Test func cantProceedSendsNothingAndWipes() async {
    let t = FakeTransport(results: [.success(.ok)])
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false), transport: t, seed: 1,
                                timings: .test.with(cantProceedReset: .milliseconds(80)))
    c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.askCounts[1] == 1 }
    c.submitTyped("pass"); await eventually { c.flow.askCounts[1] == 2 }   // wait for each digest; a new submit supersedes an in-flight one
    c.submitTyped("pass"); await eventually { c.flow.askCounts[1] == 3 }
    c.submitTyped("pass"); await eventually { c.flow.phase == .cantProceed(1) }
    #expect(c.messages.last?.text == "Sorry, we can't proceed without your Medicare or insurance ID. Please see reception — they can help.")
    await eventually { c.flow.phase == .welcome && c.messages.isEmpty }
    #expect(await t.requests.isEmpty)
}
@MainActor @Test func quietModeNeitherSpeaksNorListens() async {
    let speaker = FakeSpeaker(); let listener = FakeListener(script: [])
    let c = KioskController(speaker: speaker, listener: listener, tidier: AnswerTidier(model: FakeAnswerModel()), timings: .test, seed: 1)
    c.submitter = Submitter(transport: FakeTransport(results: [])); c.inputMode = .typing; c.start()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(speaker.spoken.isEmpty && listener.listens == 0 && c.messages.count == 1)
    c.speakAgain(); await eventually { speaker.spoken.count == 1 }; #expect(c.flow.askCounts[0] == 1)
}
@MainActor @Test func rephraseCountsAsAskAndPostsNewVariant() async {
    let (c, _) = makeController([], seed: 2); c.inputMode = .typing; c.start()
    let first = c.messages.last!.text; c.rephrase()
    #expect(c.flow.askCounts[0] == 2 && c.messages.last!.text != first)
}
@MainActor @Test func chipEditDuringListenIsKept() async {
    let (c, _) = makeController([[.final("Jane Demo")], []], model: FakeAnswerModel(extracted: [0: "Jane Demo"]), seed: 1)
    c.start(); await eventually { c.flow.phase == .asking(1) && c.isListening }
    c.edit(0, to: "Jane Q Demo"); #expect(c.flow.answers[0] == "Jane Q Demo")
    #expect(c.messages.first { $0.role == .patient }?.picked[0] == "Jane Q Demo" && c.isListening)
}
@MainActor @Test func resetDuringDigestDropsChips() async {
    let (c, _) = makeController([[.final("Jane Demo")]], model: FakeAnswerModel(extracted: [0: "Jane Demo"], delay: .milliseconds(150)), seed: 1)
    c.start(); await eventually { c.messages.contains { $0.role == .patient } }
    c.reset(); try? await Task.sleep(for: .milliseconds(300))
    #expect(c.flow == IntakeFlow() && c.messages.isEmpty)
}
@MainActor @Test func dictationFillsFieldWithoutSubmitting() async {
    let (c, _) = makeController([[], [.final("Jane Demo")]], seed: 1); c.start()
    await eventually { c.isListening }; c.dictate()
    await eventually { c.dictated == "Jane Demo" }
    #expect(c.flow.phase == .asking(0) && !c.messages.contains { $0.role == .patient })
}
@MainActor @Test func optionalSkipShowsNoneChip() async {
    let (c, _) = makeController([], model: FakeAnswerModel(extracted: [:]), seed: 1); c.inputMode = .typing; c.start()
    c.submitTyped("Jane"); await eventually { c.flow.phase == .asking(1) }
    c.submitTyped("D1"); await eventually { c.flow.phase == .asking(2) }
    c.submitTyped("1/5/1980"); await eventually { c.flow.phase == .asking(3) }
    c.submitTyped("no"); await eventually { c.flow.phase == .asking(4) }
    #expect(c.flow.isAnsweredEmpty(3) && c.messages.last { $0.role == .patient }?.picked == [3: ""])
    #expect(c.flow.answers[2] == "1980-05-01")
}
```

  - `makeController` in `Fakes.swift` becomes `makeController(_ script: [[ListenEvent]], model: FakeAnswerModel = FakeAnswerModel(), transport: FakeTransport = FakeTransport(results: [.success(.ok)]), seed: UInt64 = 1, timings: KioskTimings = .test) -> (KioskController, FakeSpeaker)`, and `KioskTimings.with(...)` gains `cantProceedReset:`.
  - Keep and adapt the v1 tests that still apply:
    - `noSpeechKeepsListening`
    - `listenErrorFallsBackToTyping`
    - `typingWhileQuestionIsSpokenKeepsMicClosed` (now: the next line listens again after submit; `endTyping()` reopens it)
    - `editDuringRespeakWinsOverLateSpeech`
    - `cancelRespeakStopsListeningAndKeepsAnswer`
    - `resetMidSessionLeavesNextSessionClean`
    - all session tests (send, idle, reset, sendFailed)
  - Delete the tests for removed APIs.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter "KioskConversation|ChatLog"`
Expected: FAIL to compile (`seed:`, `picked`, `rephrase`, `speakAgain`, `dictate` and `cantProceedReset` don't exist yet).

- [ ] **Step 3: Implement the turn loop and the API above in `KioskController.swift`.** Keep the existing `startSession` / `isLive(gen)` discipline for every await, including digest, speak and listen. A line posted while a draft is being typed must not open the mic (`typingAt`).

- [ ] **Step 4: Run the full suite three times**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit` (×3)
Expected: all pass on each run, with no warnings.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: run intake as a casual conversation with chips and quiet mode"
```

---

### Task 5: Dark ChatGPT-style UI and README

**Files:**
- Create: `GPinTheBoxiOS/GPInTheBoxKiosk/ChatView.swift`, `AnswerEditSheet.swift`, `Theme.swift`
- Delete: `GPinTheBoxiOS/GPInTheBoxKiosk/QuestionView.swift`. Move `AnswerField` into `AnswerEditSheet.swift`.
- Modify: `KioskApp.swift` (routing `.asking` → `ChatView`; new `.cantProceed` screen; `.preferredColorScheme(.dark)` and a black background at the root), `ReviewView.swift`, `WelcomeView.swift`, `StaffSetupView.swift` (dark restyle; review uses `AnswerEditSheet`; answered-empty rows read "none"), `README.md`
- Project file: add or remove the files in `GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj/project.pbxproj`. The prerequisite below means the user's Xcode reformat is already committed before execution starts. Don't stage `.DS_Store`, `.vscode/` or the Mac project.

**Interfaces:**
- Consumes: Task 4 controller API (`messages`, `picked`, `latestKioskMessageID`, `speakAgain`, `rephrase`, `dictate`, `dictated`, `clearDictation`, `beginTyping`, `endTyping`, `submitTyped`, `finishAnswer`, `edit`, `inputMode`, `speechAvailable`, `isListening`, `caption`, `flow.answeredCount`, `flow.phase`), Task 1 `ChipLabel`, `AnswerFormatting.readableDOB`.
- `Theme`: `static let background = Color.black`, `patientBubble = Color(hex 0x2f2f2f)`, `composer = Color(hex 0x1f1f1f)`, `voiceBlue = Color(hex 0x3d6fd8)`, `secondary = Color(hex 0x8e8e8e)`.
- `ChatView` layout:
  - **Kiosk messages:** plain `Text`, leading, no bubble. Under the latest one only, two icon buttons: `speaker.wave.2` → `speakAgain()` and `arrow.clockwise` → `rephrase()`, with accessibility labels "Read aloud" and "Ask another way".
  - **Patient messages:** a trailing bubble in `Theme.patientBubble`, with chips underneath, right-aligned. Each chip reads `"\(ChipLabel.text(for:)): \(value)"`, where a DOB shows readably and `""` shows as "none". Tapping a chip opens `AnswerEditSheet` for that index.
  - **Live caption:** while listening, a dimmed patient bubble with the caption and a small **Done** button → `finishAnswer()`.
  - **Header:** `"\(flow.answeredCount) of 10"` in `Theme.secondary`.
  - **Footer, above the composer:** the disclaimer copy in `Theme.secondary`, footnote size.
  - **Composer:** a capsule in `Theme.composer` containing:
    - a `TextField("Type your answer")`. On change, a non-empty value calls `beginTyping()` and becoming empty calls `endTyping()`. Submit calls `submitTyped`.
    - when `speechAvailable`, a `mic` button → `dictate()`, which fills the field from `dictated` and then calls `clearDictation()`.
    - the trailing circle in `Theme.voiceBlue`. With text present it shows `arrow.up` and sends. Without text, it shows `waveform` (voice on) or `waveform.slash` (quiet) and toggles `inputMode`. It's hidden when `!speechAvailable` and there's no text.
- `AnswerEditSheet(controller:index:)`: the existing `EditAnswerSheet` behaviour (respeak, Done, cancelRespeak on change and disappear), restyled dark and usable from both chips and review.
- `.cantProceed` screen: the last kiosk line, the title "Please see reception", and a **Start over** button → `controller.reset()`.

- [ ] **Step 1: Build for the Simulator**

Run: `xcodebuild -project GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj -scheme GPInTheBoxKiosk -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath DerivedData build`
Expected: `** BUILD SUCCEEDED **` with no compiler warnings.

- [ ] **Step 2: Walk through it in the Simulator in quiet mode, against a scratch in-memory `KioskListener`** (as in v1; never the user's Mac app or data). Save screenshots under `.superpowers/sdd/<plan>/screens/`. Cover:
  - an opening line, then "I'm Jane Demo, cough since Monday" showing three chips;
  - a chip edit;
  - "no" to Allergies showing an "Allergies: none" chip;
  - review with answered-empty rows reading "none";
  - Send, then "Thanks, please take a seat.";
  - and separately, three "pass" replies to the ID question leading to the "Please see reception" screen, then Start over.

  Compare each screen to the reference: dark, unboxed kiosk text, pill composer, blue button.

- [ ] **Step 3: Update `README.md`.** In "Patient flow", describe the casual chat, chips, quiet-mode toggle, 3-tries rule and "Please see reception". In "Manual checks (on device)", add: voice conversation end to end; quiet toggle; dictation button; 🔊 and ↻ on device.

- [ ] **Step 4: Run the KioskKit suite again**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/GPInTheBoxKiosk GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj README.md
git commit -m "feat: dark ChatGPT-style chat screen for the kiosk"
```
