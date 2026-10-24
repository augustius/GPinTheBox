# GPInTheBox Demo v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS app that receives patient intake forms over the clinic LAN, stores them per patient, and lets a GP summarise and question the record with on-device Apple Foundation Models.

**Architecture:** All testable logic lives in a local Swift package `GPInTheBoxKit` with three library targets — `Records` (SwiftData models + a `@ModelActor` store), `Intake` (HTML form + embedded Hummingbird server), `Assistant` (chunking, retrieval, summarisation, Q&A behind an `AssistantModel` protocol). A thin SwiftUI app target wires them together. The model is reached only through the `AssistantModel` protocol so every AI behaviour is unit-tested with a fake; the Foundation Models adapter has availability-gated integration tests.

**Tech Stack:** Swift 6.4, Xcode 27.1, SwiftUI, SwiftData, Swift Testing, Hummingbird 2 (`HummingbirdTesting` for route tests), FoundationModels, NaturalLanguage (`NLTokenizer`, `NLContextualEmbedding`), UserNotifications.

**Spec:** `IDEA.MD`

## Global Constraints

- Deployment target: macOS 26.0, Apple Silicon only; package `platforms: [.macOS("26.0")]`.
- AI: Apple Foundation Models only. No network calls to any AI service. No cloud fallback.
- AI never diagnoses, suggests diagnoses or recommends treatment; it uses only record content and cites every claim.
- Citations are labelled exactly `Patient-reported` or `GP-entered`, with the date.
- Nothing is generated in the background; Summarise and Q&A run only on GP action.
- Q&A chat is ephemeral (never persisted).
- Intake server: plain HTTP, bind `0.0.0.0`, port `8080`. No QR, no tokens, no auth.
- Patient matching key: normalised Medicare/insurance ID + date of birth (`yyyy-MM-dd`). Name is not part of the key.
- Every patient fills in the full form every time; no pre-fill.
- Visit statuses: `waiting` → `inConsult` → `done`.
- GP remarks are a single free-text note per visit.
- Notifications are quiet (no sound).
- Out of scope: HTTPS, encryption at rest, login, audit log, multi-Mac sync, EHR integration, voice.

## Review Focus

1. **Medicare ID typed with spaces/dashes/lowercase on a later visit** → still matches the same patient. Test: Task 1 `matchesDespiteFormatting`.
2. **Same Medicare ID, different DOB** → treated as a new patient, never attached to someone else's record. Test: Task 1 `differentDOBCreatesNewPatient`.
3. **`<script>` or quotes in a re-rendered field value or question prompt** → escaped in the HTML. Test: Task 2 `escapesValuesAndPrompts`.
4. **Browser refresh after submitting** → no duplicate visit (POST/redirect/GET). Test: Task 3 `successfulSubmitRedirects`.
5. **First-ever visit (no previous note) and model unavailable** → summary has no follow-up section and no crash; unavailable model throws `AssistantError.unavailable` with a message the UI shows above the raw record. Tests: Task 6 `firstVisitHasNoFollowUps`, `unavailableModelThrows`.

---

## File Structure

```
GPServer/
├── IDEA.MD
├── .gitignore
├── Packages/GPInTheBoxKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── Records/
│   │   │   ├── Models.swift            Patient, Visit, Question, Answer, enums
│   │   │   ├── MedicareID.swift        normalisation
│   │   │   ├── Snapshots.swift         Sendable value copies for other modules
│   │   │   ├── RecordStore.swift       @ModelActor: submissions, questionnaire
│   │   │   └── Schema.swift            container factory, default questionnaire
│   │   ├── Intake/
│   │   │   ├── HTML.swift              escaping
│   │   │   ├── IntakeForm.swift        render + parse/validate
│   │   │   ├── IntakeServer.swift      Hummingbird routes + run
│   │   │   └── LocalAddress.swift      LAN IPv4 lookup for the URL display
│   │   └── Assistant/
│   │       ├── Chunk.swift             Chunk, ChunkSource, RecordChunker
│   │       ├── CitedText.swift         CitedText, CitationParser
│   │       ├── AssistantModel.swift    protocol, errors, prompts
│   │       ├── Retriever.swift         Embedder protocol, hybrid retrieval
│   │       ├── QAService.swift
│   │       ├── Summarizer.swift
│   │       ├── FoundationModelsAssistant.swift
│   │       └── ContextualEmbedder.swift
│   └── Tests/
│       ├── RecordsTests/RecordStoreTests.swift
│       ├── IntakeTests/{IntakeFormTests,IntakeServerTests}.swift
│       └── AssistantTests/{ChunkerTests,CitationTests,RetrieverTests,QAServiceTests,SummarizerTests,FakeAssistantModel,FoundationModelsIntegrationTests}.swift
└── GPInTheBox/
    ├── GPInTheBox.xcodeproj
    └── GPInTheBox/
        ├── GPInTheBoxApp.swift         scenes, container
        ├── AppModel.swift              server lifecycle, availability, URL
        ├── Notifier.swift
        ├── QueueSidebar.swift
        ├── PatientDetailView.swift     intake, history, note editor, status
        ├── AssistantPanel.swift        Summarise, Q&A, error banner
        ├── CitedTextView.swift
        ├── QuestionnaireEditor.swift   Settings scene
        ├── GPInTheBox.entitlements
        └── Info.plist additions
```

Test command for all package tests: `swift test --package-path Packages/GPInTheBoxKit`

---

### Task 1: Package scaffold and Records

**Files:**
- Create: `.gitignore`, `Packages/GPInTheBoxKit/Package.swift`, all of `Sources/Records/*`
- Create (empty placeholder so the package builds): `Sources/Intake/HTML.swift`, `Sources/Assistant/Chunk.swift`
- Test: `Tests/RecordsTests/RecordStoreTests.swift`

**Interfaces:**
- Produces (all `public`):
  - `enum VisitStatus: String, Codable, Sendable { case waiting, inConsult, done }`
  - `enum QuestionKind: String, Codable, Sendable { case shortText, longText }`
  - `struct Answer: Codable, Hashable, Sendable { var questionID: UUID; var prompt: String; var value: String }`
  - `@Model final class Patient { var id: UUID; var fullName: String; var medicareID: String /* normalised */; var dateOfBirth: String /* yyyy-MM-dd */; @Relationship(deleteRule: .cascade, inverse: \Visit.patient) var visits: [Visit] }`
  - `@Model final class Visit { var id: UUID; var arrivedAt: Date; var statusRaw: String; var answers: [Answer]; var gpNote: String; var noteUpdatedAt: Date?; var patient: Patient?; init(arrivedAt: Date, answers: [Answer]) /* status waiting, empty note */; var status: VisitStatus { get set }; func open(); func finish() }` — `open()` moves only `waiting → inConsult`; `finish()` sets `done`.
  - `extension Visit { static func arrivedOnSameDay(as now: Date, calendar: Calendar) -> Predicate<Visit> }`
  - `@Model final class Question { var id: UUID; var prompt: String; var kindRaw: String; var isRequired: Bool; var order: Int }`
  - `enum MedicareID { static func normalise(_ raw: String) -> String }` — uppercase, remove whitespace, `-`, `/`.
  - `struct IntakeSubmission: Sendable { var fullName, medicareID, dateOfBirth: String; var answers: [Answer]; var receivedAt: Date }`
  - `struct SubmissionReceipt: Sendable, Equatable { var patientID: UUID; var visitID: UUID; var patientName: String; var isNewPatient: Bool }`
  - `struct QuestionSnapshot: Sendable, Hashable { var id: UUID; var prompt: String; var kind: QuestionKind; var isRequired: Bool }`
  - `struct VisitSnapshot: Sendable, Equatable { var id: UUID; var arrivedAt: Date; var answers: [Answer]; var gpNote: String; var noteUpdatedAt: Date? }`
  - `struct PatientSnapshot: Sendable, Equatable { var id: UUID; var fullName: String; var dateOfBirth: String; var visits: [VisitSnapshot] /* oldest first */ }`
  - `extension Patient { func snapshot() -> PatientSnapshot }`
  - `enum GPInTheBoxSchema { static func makeContainer(inMemory: Bool) throws -> ModelContainer; static let defaultQuestions: [(prompt: String, kind: QuestionKind, isRequired: Bool)] }`
  - `@ModelActor actor RecordStore { func recordSubmission(_ s: IntakeSubmission) throws -> SubmissionReceipt; func questionnaire() throws -> [QuestionSnapshot] /* sorted by order */; func seedDefaultQuestionnaireIfEmpty() throws }`

- [ ] **Step 1: Init git and package**

`git init` in `GPServer/`. `.gitignore`: `.build/`, `DerivedData/`, `*.xcuserstate`, `xcuserdata/`, `.DS_Store`. `Package.swift`: library products `Records`, `Intake`, `Assistant`; dependency `.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")`; `Intake` depends on `Records` + `Hummingbird`; `Assistant` depends on `Records`; test targets `RecordsTests`, `IntakeTests` (+ `HummingbirdTesting`), `AssistantTests`.

- [ ] **Step 2: Write the failing tests**

```swift
import Testing, Foundation, SwiftData
@testable import Records

func makeStore() throws -> RecordStore {
    RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true))
}
func submission(name: String = "Jane Citizen", medicare: String = "2123 45670 1",
                dob: String = "1980-05-01", value: String = "Cough") -> IntakeSubmission {
    IntakeSubmission(fullName: name, medicareID: MedicareID.normalise(medicare), dateOfBirth: dob,
                     answers: [Answer(questionID: UUID(), prompt: "Reason", value: value)], receivedAt: .now)
}

@Test func firstSubmissionCreatesPatient() async throws {
    let r = try await makeStore().recordSubmission(submission())
    #expect(r.isNewPatient && r.patientName == "Jane Citizen")
}
@Test func matchesDespiteFormatting() async throws {
    let store = try makeStore()
    let a = try await store.recordSubmission(submission(medicare: "2123 45670 1"))
    let b = try await store.recordSubmission(submission(name: "Jane C", medicare: "2123-45670-1"))
    #expect(b.patientID == a.patientID && !b.isNewPatient && b.visitID != a.visitID)
}
@Test func differentDOBCreatesNewPatient() async throws {
    let store = try makeStore()
    let a = try await store.recordSubmission(submission(dob: "1980-05-01"))
    let b = try await store.recordSubmission(submission(dob: "1981-05-01"))
    #expect(b.patientID != a.patientID && b.isNewPatient)
}
@Test func normaliseStripsSeparators() { #expect(MedicareID.normalise(" ab 12-3/4 ") == "AB1234") }
@Test func newVisitIsWaitingAndTransitions() throws {
    let v = Visit(arrivedAt: .now, answers: [])
    #expect(v.status == .waiting); v.open(); #expect(v.status == .inConsult)
    v.open(); #expect(v.status == .inConsult); v.finish(); #expect(v.status == .done)
    v.open(); #expect(v.status == .done)
}
@Test func seedsDefaultQuestionnaireOnce() async throws {
    let store = try makeStore()
    try await store.seedDefaultQuestionnaireIfEmpty(); try await store.seedDefaultQuestionnaireIfEmpty()
    let qs = try await store.questionnaire()
    #expect(qs.map(\.prompt) == GPInTheBoxSchema.defaultQuestions.map(\.prompt))
}
@Test func snapshotOrdersVisitsOldestFirst() async throws { /* two submissions with receivedAt t0 < t1, fetch Patient, assert snapshot().visits.map(\.arrivedAt) == [t0, t1] */ }
@Test func sameDayPredicateExcludesYesterday() throws { /* insert visits at now and now-1day in a context; fetch with arrivedOnSameDay(as: now, calendar: .current); expect 1 */ }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter RecordsTests`
Expected: compile failure (types not defined).

- [ ] **Step 4: Implement the Records interfaces above**

`recordSubmission` fetches `Patient` where `medicareID == s.medicareID && dateOfBirth == s.dateOfBirth`; if found, appends a visit and leaves `fullName` unchanged; otherwise creates the patient. Saves before returning. Default questions (exact copy, in order):

| prompt | kind | required |
|---|---|---|
| What is the main reason for your visit today? | longText | yes |
| When did it start? | shortText | yes |
| Describe your symptoms. | longText | no |
| Are you currently taking any medications? Please list them. | longText | no |
| Do you have any allergies? | shortText | no |
| Do you have any ongoing medical conditions? | longText | no |
| Is there anything else you'd like the doctor to know? | longText | no |

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter RecordsTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add .gitignore IDEA.MD docs Packages
git commit -m "feat(records): patient/visit models, Medicare+DOB matching, default questionnaire"
```

---

### Task 2: Intake form rendering and validation

**Files:**
- Create: `Sources/Intake/HTML.swift`, `Sources/Intake/IntakeForm.swift`
- Test: `Tests/IntakeTests/IntakeFormTests.swift`

**Interfaces:**
- Consumes: `QuestionSnapshot`, `IntakeSubmission`, `Answer`, `MedicareID.normalise` (Task 1).
- Produces:
  - `enum HTML { static func escape(_ s: String) -> String }` — escapes `& < > " '`.
  - `struct IntakeValidationErrors: Error, Equatable { var messages: [String: String] }` — keyed by field name.
  - `enum IntakeForm { static func render(questions: [QuestionSnapshot], values: [String: String] = [:], errors: [String: String] = [:]) -> String; static func thanksPage() -> String; static func parse(fields: [String: String], questions: [QuestionSnapshot], now: Date) -> Result<IntakeSubmission, IntakeValidationErrors>; static func fieldName(for id: UUID) -> String /* "q_<uuid>" */ }`
  - Fixed field names: `fullName`, `medicareID`, `dateOfBirth` (`<input type="date">`).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing, Foundation
@testable import Intake
import Records

let q1 = QuestionSnapshot(id: UUID(), prompt: "Reason?", kind: .longText, isRequired: true)
let q2 = QuestionSnapshot(id: UUID(), prompt: "Allergies?", kind: .shortText, isRequired: false)
let now = ISO8601DateFormatter().date(from: "2026-10-24T09:00:00Z")!
func fields(_ extra: [String: String] = [:]) -> [String: String] {
    ["fullName": " Jane ", "medicareID": "2123 4567", "dateOfBirth": "1980-05-01",
     IntakeForm.fieldName(for: q1.id): "Cough"].merging(extra) { $1 }
}

@Test func parsesValidSubmission() throws {
    let s = try IntakeForm.parse(fields: fields(), questions: [q1, q2], now: now).get()
    #expect(s.fullName == "Jane" && s.medicareID == "21234567" && s.dateOfBirth == "1980-05-01")
    #expect(s.answers == [Answer(questionID: q1.id, prompt: "Reason?", value: "Cough"),
                          Answer(questionID: q2.id, prompt: "Allergies?", value: "")])
}
@Test func reportsMissingRequiredFields() {
    guard case .failure(let e) = IntakeForm.parse(fields: ["medicareID": " - "], questions: [q1], now: now) else { Issue.record(); return }
    #expect(e.messages == ["fullName": "Please enter your full name.",
                           "medicareID": "Please enter your Medicare or insurance ID.",
                           "dateOfBirth": "Please enter a valid date of birth.",
                           IntakeForm.fieldName(for: q1.id): "This question is required."])
}
@Test func rejectsFutureDOB() { /* dateOfBirth "2027-01-01" → messages["dateOfBirth"] == "Please enter a valid date of birth." */ }
@Test func acceptsUnicode() throws { /* fullName "Nguyễn Thị Hoa", answer "头痛" round-trip unchanged */ }
@Test func escapesValuesAndPrompts() {
    let evil = QuestionSnapshot(id: UUID(), prompt: "<b>x</b>", kind: .shortText, isRequired: false)
    let html = IntakeForm.render(questions: [evil], values: ["fullName": "\"><script>alert(1)</script>"])
    #expect(!html.contains("<script>") && !html.contains("<b>x</b>"))
    #expect(html.contains("&lt;script&gt;") && html.contains("&lt;b&gt;x&lt;/b&gt;"))
}
@Test func renderShowsErrorsAndKeepsValues() { /* render with errors ["fullName": "Please enter your full name."], values ["medicareID": "123"]; html contains the message and value="123" */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter IntakeFormTests`
Expected: compile failure.

- [ ] **Step 3: Implement `HTML.escape`, `IntakeForm.render/thanksPage/parse/fieldName`**

All values trimmed. DOB parsed with a `yyyy-MM-dd` `DateFormatter` (`en_US_POSIX`, UTC); invalid or later than `now` fails. Form posts to `/submit`, `method="post"`, `accept-charset="utf-8"`, mobile viewport meta, inline CSS only. `longText` → `<textarea>`, `shortText` → `<input type="text">`. Page title and heading: `Patient intake`. Thanks page heading: `Thank you`, body: `Your answers have been sent to the doctor. Please take a seat.`

- [ ] **Step 4: Run to verify pass** — same command, all pass.

- [ ] **Step 5: Commit** — `git commit -m "feat(intake): HTML intake form rendering and validation"`

---

### Task 3: Intake HTTP server

**Files:**
- Create: `Sources/Intake/IntakeServer.swift`, `Sources/Intake/LocalAddress.swift`
- Test: `Tests/IntakeTests/IntakeServerTests.swift`

**Interfaces:**
- Consumes: `RecordStore.questionnaire()`, `RecordStore.recordSubmission(_:)` (Task 1); `IntakeForm` (Task 2).
- Produces:
  - `struct IntakeServer: Sendable { init(store: RecordStore, host: String = "0.0.0.0", port: Int = 8080, onSubmission: @escaping @Sendable (SubmissionReceipt) async -> Void); func buildRouter() -> Router<BasicRequestContext>; func run() async throws }`
  - `enum LocalAddress { static func primaryIPv4() -> String? }` — first non-loopback IPv4 on an up interface (prefer `en0`), via `getifaddrs`.
  - Routes: `GET /` → 200 form; `POST /submit` → 303 `Location: /thanks` on success, 400 with re-rendered form on validation failure; `GET /thanks` → 200. All HTML responses `Content-Type: text/html; charset=utf-8`.

- [ ] **Step 1: Write the failing tests**

Use `Application(router: server.buildRouter()).test(.router) { client in ... }` with an in-memory store seeded via `seedDefaultQuestionnaireIfEmpty()`. Form bodies are `application/x-www-form-urlencoded`, percent-encoded.

```swift
@Test func getRootServesForm() async throws          // 200, body contains "Patient intake" and first default question prompt
@Test func successfulSubmitRedirects() async throws  // POST valid body → 303, Location "/thanks"; onSubmission called exactly once with isNewPatient == true; a second identical POST yields isNewPatient == false (same patientID)
@Test func invalidSubmitReturns400() async throws    // POST empty body → 400, body contains "Please enter your full name."; onSubmission not called
@Test func decodesPlusAndUnicode() async throws      // fullName=Nguy%E1%BB%85n+Hoa → receipt.patientName == "Nguyễn Hoa"
@Test func primaryIPv4IsNotLoopback()                // result is nil or does not start with "127."
```

Capture receipts in an `actor Receipts { var all: [SubmissionReceipt] }`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter IntakeServerTests`
Expected: compile failure.

- [ ] **Step 3: Implement `IntakeServer` and `LocalAddress`**

Decode the POST body to `[String: String]` with Hummingbird's `URLEncodedFormDecoder`. `run()` builds `Application(router:configuration: .init(address: .hostname(host, port: port)))` and calls `runService()`.

- [ ] **Step 4: Run to verify pass** — same command, all pass.

- [ ] **Step 5: Commit** — `git commit -m "feat(intake): Hummingbird intake server with POST/redirect/GET"`

---

### Task 4: Chunking, citations and the model boundary

**Files:**
- Create: `Sources/Assistant/Chunk.swift`, `Sources/Assistant/CitedText.swift`, `Sources/Assistant/AssistantModel.swift`
- Test: `Tests/AssistantTests/ChunkerTests.swift`, `Tests/AssistantTests/CitationTests.swift`, `Tests/AssistantTests/FakeAssistantModel.swift`

**Interfaces:**
- Consumes: `PatientSnapshot`, `VisitSnapshot`, `Answer` (Task 1).
- Produces:
  - `enum ChunkSource: Sendable { case patientReported, gpEntered; var label: String }` — `"Patient-reported"` / `"GP-entered"`.
  - `struct Chunk: Sendable, Hashable, Identifiable { var id: String; var visitID: UUID; var date: Date; var source: ChunkSource; var text: String }`
  - `enum RecordChunker { static func chunks(for patient: PatientSnapshot) -> [Chunk]; static func chunks(forVisit v: VisitSnapshot, number: Int) -> [Chunk] }` — IDs `V{n}-A{i}` for non-empty answers (text `"{prompt}: {value}"`, date `arrivedAt`) and `V{n}-N{i}` for each note sentence (`NLTokenizer(unit: .sentence)`, date `noteUpdatedAt ?? arrivedAt`); `n`, `i` 1-based, visits numbered oldest first.
  - `struct CitedText: Sendable, Equatable { enum Segment: Sendable, Equatable { case text(String), citation(Chunk) }; var segments: [Segment]; var citedChunks: [Chunk] }`
  - `enum CitationParser { static func parse(_ raw: String, chunks: [Chunk]) -> CitedText }` — recognises `[V1-A2]` and `[V1-A2, V3-N1]`; unknown IDs are dropped; brackets that aren't citations stay as text.
  - `enum ModelAvailability: Sendable, Equatable { case available, unavailable(reason: String) }`
  - `enum AssistantError: Error, Equatable { case unavailable(String), guardrailViolation, unsupportedLanguage, contextOverflow, failed(String); var userMessage: String }`
  - `struct ExtractedFollowUp: Sendable, Equatable { var item: String; var sourceSentence: String }`
  - `struct FollowUpJudgement: Sendable, Equatable { var mentioned: Bool; var chunkIDs: [String] }`
  - `protocol AssistantModel: Sendable { func availability() -> ModelAvailability; func respond(instructions: String, prompt: String) async throws -> String; func extractFollowUps(fromNote note: String) async throws -> [ExtractedFollowUp]; func judgeFollowUp(item: String, excerpts: String) async throws -> FollowUpJudgement }` — all throws are `AssistantError`.
  - `enum AssistantPrompts { static let baseInstructions: String; static func excerpts(_ chunks: [Chunk]) -> String }` — one line per chunk: `[V1-A2] (Patient-reported, 2026-10-24) text`.
  - Test helper `final class FakeAssistantModel: AssistantModel, @unchecked Sendable` with settable `availabilityValue`, a `respondHandler: (String, String) throws -> String`, `followUps`, `judgements: [String: FollowUpJudgement]`, and `respondPrompts: [String]` recording calls (lock-protected).

Exact copy:

```
baseInstructions:
You are assisting a GP. Use only the record excerpts provided. Do not diagnose, suggest diagnoses, or recommend treatment. Cite every claim with the excerpt ID in square brackets, for example [V2-A1]. If the excerpts do not contain the answer, say "Not found in the record."

userMessage:
unavailable(r)       → On-device AI is unavailable: {r}. The raw record is shown below.
guardrailViolation   → The on-device model declined to process this record. The raw record is shown below.
unsupportedLanguage  → The on-device model doesn't support the language in this record. The raw record is shown below.
contextOverflow      → This record is too long for the on-device model, even after splitting. The raw record is shown below.
failed(m)            → The on-device model failed: {m}. The raw record is shown below.
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func chunksAnswersAndNoteSentences() {
    // patient with visit1 (answers "Reason":"Cough", "Allergies":"" ; note "Prescribed amoxicillin. Recheck BP next visit.")
    // and visit2 (answer "Reason":"Follow-up")
    // expect ids == ["V1-A1", "V1-N1", "V1-N2", "V2-A1"]
    // V1-A1.text == "Reason: Cough", .source == .patientReported; V1-N2.text == "Recheck BP next visit.", .source == .gpEntered
}
@Test func parsesSingleAndMultipleCitations() {
    // chunks A = V1-A1, B = V1-N1
    // parse("Has cough [V1-A1]. On antibiotics [V1-A1, V1-N1].")
    // segments == [.text("Has cough "), .citation(A), .text(". On antibiotics "), .citation(A), .citation(B), .text(".")]
}
@Test func dropsUnknownCitations()   // "x [V9-A9] y" → segments == [.text("x  y")] (adjacent text merged); citedChunks empty
@Test func leavesNonCitationBrackets() // "[note] ok" → [.text("[note] ok")]
@Test func excerptLineFormat()       // excerpts([V1-A1 dated 2026-10-24]) == "[V1-A1] (Patient-reported, 2026-10-24) Reason: Cough"
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/GPInTheBoxKit --filter "ChunkerTests|CitationTests"`, compile failure.

- [ ] **Step 3: Implement the interfaces above**

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit** — `git commit -m "feat(assistant): record chunking, citation parsing, model protocol"`

---

### Task 5: Retrieval and Q&A

**Files:**
- Create: `Sources/Assistant/Retriever.swift`, `Sources/Assistant/QAService.swift`
- Test: `Tests/AssistantTests/RetrieverTests.swift`, `Tests/AssistantTests/QAServiceTests.swift`

**Interfaces:**
- Consumes: `Chunk`, `RecordChunker`, `CitationParser`, `AssistantModel`, `AssistantPrompts`, `AssistantError` (Task 4).
- Produces:
  - `protocol Embedder: Sendable { func embed(_ text: String) async throws -> [Float] }`
  - `struct Retriever: Sendable { init(embedder: (any Embedder)?); func topChunks(for query: String, in chunks: [Chunk], k: Int = 6) async -> [Chunk] }`
  - `struct QAService: Sendable { init(model: any AssistantModel, retriever: Retriever); func answer(_ question: String, patient: PatientSnapshot) async throws -> CitedText }`

Scoring: keyword score = fraction of distinct query word tokens (`NLTokenizer(unit: .word)`, lowercased, minus a small English stopword list) present in the chunk; semantic score = cosine similarity; combined `0.5 * keyword + 0.5 * semantic`. If the embedder is nil or throws, keyword only. Stable sort, ties keep chunk order.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func keywordOnlyFindsMetformin() async {
    // chunks: "Reason: Cough", "Medications: metformin 500mg", "Allergies: none"
    // Retriever(embedder: nil).topChunks(for: "Is she on metformin?", in: chunks, k: 1).map(\.text) == ["Medications: metformin 500mg"]
}
@Test func embedderBoostsSynonym() async  // fake embedder mapping "diabetes tablets" and the metformin chunk to the same vector → metformin chunk ranks first with k: 1
@Test func throwingEmbedderFallsBackToKeywords() async
@Test func answerCitesRetrievedChunks() async throws {
    // fake.respondHandler returns "Takes metformin [V1-A2]."
    // answer.citedChunks.map(\.id) == ["V1-A2"]; fake.respondPrompts.last contains "[V1-A2]" and the question
}
@Test func answerPropagatesUnavailable() async // fake availability .unavailable(reason: "Apple Intelligence is off") → throws AssistantError.unavailable("Apple Intelligence is off"); respond never called
```

- [ ] **Step 2: Run to verify failure** — `--filter "RetrieverTests|QAServiceTests"`.

- [ ] **Step 3: Implement `Retriever` and `QAService`**

`answer` checks availability first, retrieves over `RecordChunker.chunks(for:)`, prompt = `"Record excerpts:\n{excerpts}\n\nQuestion: {question}"`, instructions = `AssistantPrompts.baseInstructions`, result through `CitationParser`.

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit** — `git commit -m "feat(assistant): hybrid retrieval and cited Q&A"`

---

### Task 6: Summariser with map-reduce and follow-ups

**Files:**
- Create: `Sources/Assistant/Summarizer.swift`
- Test: `Tests/AssistantTests/SummarizerTests.swift`

**Interfaces:**
- Consumes: Task 4 types.
- Produces:
  - `struct FollowUpResult: Sendable, Equatable { enum Status: Sendable, Equatable { case addressed([Chunk]), notMentioned }; var item: String; var noteSource: Chunk?; var status: Status }`
  - `struct PatientSummary: Sendable, Equatable { var followUps: [FollowUpResult]; var overview: CitedText }`
  - `struct Summarizer: Sendable { init(model: any AssistantModel, budgetCharacters: Int = 6000); func summarize(_ patient: PatientSnapshot, visitID: UUID) async throws -> PatientSummary }`

Algorithm (not determined by the signature):

```
check availability → throw .unavailable(reason)
chunks = RecordChunker.chunks(for: patient restricted to visits up to and including visitID)
overview:
  reduce(texts = excerpt lines, budget):
    if joined(texts).count <= budget → respond(base + "Summarise this patient's record for the GP.", joined)
    else greedily pack lines into batches each <= budget; partials = respond per batch
         ("Summarise these excerpts. Keep the citations."); return reduce(partials, budget)
  on AssistantError.contextOverflow: budget /= 2 and restart; if budget < 500 throw .contextOverflow
  parse final text with CitationParser against all chunks
follow-ups:
  previous = latest visit before visitID with non-empty gpNote; none → []
  items = extractFollowUps(fromNote: previous.gpNote)
  noteSource = previous visit's N-chunk whose trimmed text == or contains trimmed sourceSentence, else nil
  judgement = judgeFollowUp(item, excerpts: excerpts(current visit's A-chunks))
  validIDs = judgement.chunkIDs ∩ current visit's chunk IDs
  status = mentioned && !validIDs.isEmpty ? .addressed(chunks for validIDs) : .notMentioned
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func firstVisitHasNoFollowUps() async throws  // single visit → followUps == []; extractFollowUps never called
@Test func unavailableModelThrows() async          // .unavailable(reason: "Model is downloading") → throws AssistantError.unavailable("Model is downloading")
@Test func shortRecordIsOneCall() async throws     // respondPrompts.count == 1; overview cites the chunk ID the fake returns
@Test func longRecordIsMapReduced() async throws   // budgetCharacters: 200, 10 answers of ~60 chars → respondPrompts.count > 1, every recorded prompt (excerpt text only; instructions are passed separately).count <= 200; final overview parsed
@Test func overflowHalvesBudgetThenGivesUp() async // respondHandler always throws .contextOverflow → throws AssistantError.contextOverflow
@Test func followUpAddressedAndNotMentioned() async throws {
    // visit1 note "Recheck BP. Ask about cough."; visit2 answers "Reason: Cough better", "Other: none"
    // fake.followUps = [("Recheck BP","Recheck BP."), ("Ask about cough","Ask about cough.")]
    // fake.judgements = ["Recheck BP": (false, []), "Ask about cough": (true, ["V2-A1"])]
    // expect [FollowUpResult(item:"Recheck BP", noteSource: V1-N1, status: .notMentioned),
    //         FollowUpResult(item:"Ask about cough", noteSource: V1-N2, status: .addressed([V2-A1]))]
}
@Test func judgementCitingOtherVisitIsNotMentioned() async throws // judgement (true, ["V1-N1"]) → .notMentioned
```

- [ ] **Step 2: Run to verify failure** — `--filter SummarizerTests`.

- [ ] **Step 3: Implement `Summarizer`**

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit** — `git commit -m "feat(assistant): map-reduce summary with follow-up tracking"`

---

### Task 7: Foundation Models and embedding adapters

**Files:**
- Create: `Sources/Assistant/FoundationModelsAssistant.swift`, `Sources/Assistant/ContextualEmbedder.swift`
- Test: `Tests/AssistantTests/FoundationModelsIntegrationTests.swift`

**Interfaces:**
- Consumes: `AssistantModel`, `AssistantError`, `ModelAvailability`, `ExtractedFollowUp`, `FollowUpJudgement`, `AssistantPrompts` (Task 4); `Embedder` (Task 5).
- Produces:
  - `struct FoundationModelsAssistant: AssistantModel { init() }` — a fresh `LanguageModelSession(instructions:)` per call on `SystemLanguageModel.default`.
  - `struct ContextualEmbedder: Embedder { static func make() async -> ContextualEmbedder? }` — `NLContextualEmbedding(language: .english)`; requests assets if missing, `load()`s, returns nil on any failure; `embed` mean-pools token vectors.

Mapping:
- `availability()`: `.available` → `.available`; `.unavailable(.deviceNotEligible)` → `"This Mac doesn't support Apple Intelligence"`; `.appleIntelligenceNotEnabled` → `"Apple Intelligence is turned off in System Settings"`; `.modelNotReady` → `"The model is still downloading"`; other → `"Unknown reason"`.
- `LanguageModelSession.GenerationError`: `.exceededContextWindowSize` → `.contextOverflow`; `.guardrailViolation` → `.guardrailViolation`; `.unsupportedLanguageOrLocale` → `.unsupportedLanguage`; anything else → `.failed(error.localizedDescription)`.
- `extractFollowUps` and `judgeFollowUp` use guided generation: private `@Generable` structs mirroring `ExtractedFollowUp` (array wrapper) and `FollowUpJudgement`, with `@Guide` descriptions: items are "things the GP asked to check or follow up at the next visit, copied from the note"; `sourceSentence` is "the exact sentence from the note"; `chunkIDs` are "IDs of excerpts that mention the item".

- [ ] **Step 1: Write the integration tests** (gated, so they skip on CI and ineligible Macs)

```swift
@Suite(.enabled(if: SystemLanguageModel.default.isAvailable))
struct FoundationModelsIntegrationTests {
    @Test func respondsWithCitation() async throws   // excerpt "[V1-A1] (Patient-reported, 2026-10-24) Reason: Cough for 3 days" → response contains "[V1-A1]"
    @Test func extractsFollowUps() async throws      // note "Prescribed amoxicillin. Recheck BP next visit." → items non-empty, some sourceSentence == "Recheck BP next visit."
}
@Test func availabilityNeverCrashes() { _ = FoundationModelsAssistant().availability() }
```

- [ ] **Step 2: Run to verify failure** — `--filter FoundationModelsIntegrationTests`, compile failure.

- [ ] **Step 3: Implement both adapters**

- [ ] **Step 4: Run to verify pass** — on this Mac with Apple Intelligence on, the gated suite runs and passes; record whether it ran or was skipped in the commit message body.

- [ ] **Step 5: Commit** — `git commit -m "feat(assistant): Foundation Models and contextual embedding adapters"`

---

### Task 8: App shell — server, queue, notifications

**Files:**
- Create: `GPInTheBox/GPInTheBox.xcodeproj` (macOS App, SwiftUI, Swift, no Core Data/SwiftData template, no tests), `GPInTheBoxApp.swift`, `AppModel.swift`, `Notifier.swift`, `QueueSidebar.swift`, `GPInTheBox.entitlements`
- Modify: target Info (add `NSLocalNetworkUsageDescription`)

**Interfaces:**
- Consumes: `GPInTheBoxSchema.makeContainer`, `RecordStore`, `Visit.arrivedOnSameDay`, `VisitStatus` (Task 1); `IntakeServer`, `LocalAddress` (Task 3); `FoundationModelsAssistant` (Task 7).
- Produces:
  - `@Observable @MainActor final class AppModel { let container: ModelContainer; var serverURL: String? /* "http://<ip>:8080" */; var serverError: String?; var availability: ModelAvailability; var selectedVisitID: UUID?; func start() async }`
  - `enum Notifier { static func requestAuthorization() async; static func postArrival(_ r: SubmissionReceipt) async }` — title `New patient: {name}` or `Returning patient: {name}`, body `Intake form received.`, `sound = nil`.

- [ ] **Step 1: Create the Xcode project and link the package**

Create the project (Xcode MCP `XcodeNewProject` or Xcode GUI) at `GPInTheBox/`, deployment target macOS 26.0. Add local package `../Packages/GPInTheBoxKit`, link `Records`, `Intake`, `Assistant`. Entitlements: App Sandbox, `com.apple.security.network.server`, `com.apple.security.network.client` (for one-time embedding asset download). `NSLocalNetworkUsageDescription` = `GPInTheBox receives patient intake forms from devices on your clinic network.`

- [ ] **Step 2: Implement `AppModel.start()`**

Seeds the questionnaire, requests notification authorisation, reads availability, sets `serverURL` from `LocalAddress.primaryIPv4()`, and runs `IntakeServer(store:onSubmission: Notifier.postArrival)` in a detached task; a thrown error (e.g. port 8080 in use) sets `serverError = "Intake server couldn't start: {error}"`.

- [ ] **Step 3: Implement the window**

`NavigationSplitView`: sidebar = `QueueSidebar` (`@Query(filter: Visit.arrivedOnSameDay(as: .now, calendar: .current), sort: \Visit.arrivedAt)`, row = patient name, arrival time, status badge `Waiting`/`In consult`/`Done`); detail = placeholder `Select a patient` (Task 9 replaces it). Toolbar shows `Intake form: {serverURL}` with a copy button, or `serverError` in red. When `availability` is unavailable, a persistent banner shows `AssistantError.unavailable(reason).userMessage`.

- [ ] **Step 4: Verify build and end-to-end intake manually**

Run: `xcodebuild -project GPInTheBox/GPInTheBox.xcodeproj -scheme GPInTheBox -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.
Then launch the app, and from another terminal:
`curl -s -o /dev/null -w '%{http_code}\n' -d 'fullName=Jane+Citizen&medicareID=2123+45670+1&dateOfBirth=1980-05-01' http://localhost:8080/submit` → `400` (required questions missing). Open the toolbar URL on an iPhone on the same Wi-Fi, submit the form → thanks page, a quiet notification appears, and the patient shows as `Waiting` in the sidebar.

- [ ] **Step 5: Commit** — `git commit -m "feat(app): app shell with intake server, today's queue and notifications"`

---

### Task 9: Patient detail, notes, Summarise/Q&A UI, questionnaire editor

**Files:**
- Create: `PatientDetailView.swift`, `AssistantPanel.swift`, `CitedTextView.swift`, `QuestionnaireEditor.swift`
- Modify: `GPInTheBoxApp.swift` (detail column, `Settings` scene)

**Interfaces:**
- Consumes: `Visit`, `Patient.snapshot()`, `Question` (Task 1); `QAService`, `Retriever` (Task 5); `Summarizer`, `PatientSummary` (Task 6); `FoundationModelsAssistant`, `ContextualEmbedder` (Task 7); `CitedText`, `ChunkSource.label`, `AssistantError.userMessage` (Task 4).
- Produces: views only.

- [ ] **Step 1: `PatientDetailView(visit:)`**

On appear calls `visit.open()`. Sections, top to bottom: header (name, DOB, `Finish visit` button → `visit.finish()`); **Today's intake** (prompt/answer list, raw); **GP note** (`TextEditor` bound to `visit.gpNote`, updates `noteUpdatedAt` on change); **Past visits** (newest first, each with date, answers and note, collapsed by default); `AssistantPanel`.

- [ ] **Step 2: `AssistantPanel(patient: PatientSnapshot, visitID: UUID)`**

`Summarise` button → `Summarizer.summarize`; while running shows a progress indicator; result shows **Follow-ups from last visit** (only if non-empty; each item with `Addressed` + citations or `Not mentioned`, plus a link to its note source) then **Summary** via `CitedTextView`. Q&A: text field + `Ask` button; Q&A history is `@State` (lost when the selection changes, per spec). Any `AssistantError` shows `userMessage` in a banner; raw sections above stay visible. Neither action runs automatically.

- [ ] **Step 3: `CitedTextView(text: CitedText)`**

Citations render as small chips `[V2-A1]`; clicking shows a popover with `source.label`, the date (`.dateTime.day().month().year()`) and the chunk's full text.

- [ ] **Step 4: `QuestionnaireEditor`** in a `Settings` scene

List of `Question` sorted by `order`: edit prompt, kind picker (`Short answer` / `Long answer`), `Required` toggle, drag to reorder (rewrites `order`), add and delete. Changes take effect on the next `GET /`.

- [ ] **Step 5: Verify manually against the spec**

Build (same command as Task 8, expect `** BUILD SUCCEEDED **`), run `swift test --package-path Packages/GPInTheBoxKit` (all pass), then in the app:
1. Submit Jane's form; open her → status `In consult`; write note `Prescribed amoxicillin. Recheck BP next visit.`; `Finish visit` → `Done`.
2. Submit again with Medicare `2123-45670-1`, same DOB, reason `Cough better` → her second visit appears with the first under Past visits.
3. `Summarise` → follow-up `Recheck BP` shows `Not mentioned`; summary has clickable citations labelled `Patient-reported` / `GP-entered`.
4. Ask `What was prescribed last time?` → answer cites `V1-N1`.
5. Turn off Apple Intelligence → banner with the unavailable message; raw intake still visible.
6. Add a question in Settings → it appears on a reloaded form.

- [ ] **Step 6: Commit** — `git commit -m "feat(app): patient detail, notes, summary and Q&A UI, questionnaire editor"`
