# SteadyCare Voice Intake Kiosk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iOS/iPadOS waiting-room kiosk that asks the 10 intake questions aloud, transcribes and tidies the spoken answers on device, lets the patient review them, and sends `[{q, a}]` to the SteadyCare Mac over Bonjour, where every payload becomes a new patient record.

**Architecture:** A new shared package `Packages/KioskProtocol` holds the question strings, wire types and framing, so the Mac and the kiosk can't drift apart. On the Mac, `Records` gains `recordKioskSubmission` and `Intake` gains an `NWListener`-based `KioskListener` started next to `IntakeServer`. On iOS, the testable logic lives in a local package `GPinTheBoxiOS/KioskKit`: a pure `IntakeFlow` state machine, an `AnswerTidier` around Foundation Models, a `Submitter` around an `NWConnection` transport, and a `@MainActor` `KioskController` that orchestrates them. Speech, model and network sit behind protocols with fakes. A thin SwiftUI app target, `GPInTheBoxKiosk`, renders the controller.

**Tech Stack:** Swift 6.4, Xcode 27.1, SwiftUI, Swift Testing, `Speech` (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`), `FoundationModels`, `AVFoundation` (`AVSpeechSynthesizer`, `AVAudioEngine`, `AVAudioSession`), `Network` (`NWListener`, `NWBrowser`, `NWConnection`), SwiftData (Mac only).

**Spec:** `GPinTheBoxiOS/docs/superpowers/specs/2026-10-24-voice-intake-kiosk-design.md`

## Global Constraints

- iOS/iPadOS 26.0+ (kiosk), macOS 26.0+ (Mac). Package manifests use `swift-tools-version: 6.2`, like `GPInTheBoxKit`.
- Synthetic data only. Local network only. No authentication, no TLS, no pairing.
- Bonjour service type: `_steadycare._tcp`. Framing: 4-byte big-endian length prefix, then UTF-8 JSON. One request and one response per connection. 256 KB message cap (`256 * 1024`).
- Question strings are the payload `q` values byte for byte and live only in `KioskProtocol.KioskQuestions`. Questions 1–3 are required. Skipped questions are sent with `a == ""`.
- DOB is stored and sent as `yyyy-MM-dd`, must be a valid past date, and is shown to the patient as e.g. `1 May 1980`.
- Speech locale is `en_AU`. Fall back to `en_US` only when `en_AU` isn't supported, and flag that in the UI.
- Timings: silence ends an answer after 1.5 s, model calls time out after 5 s, sending gives up after 30 s, idle prompt after 2 min, reset 20 s after the prompt, reset 5 s after Done.
- The model only transcribes and tidies. It never advises, diagnoses or invents. Nothing is sent without the patient tapping **Send to clinic**.
- Patient-facing copy, exactly: `Tap to start.` · `Clinic not found — ask reception` · `Repeat question` · `Skip` · `Done` · `Send to clinic` · `Couldn't reach the clinic — ask reception` · `Thanks, please take a seat.` · `Are you still there?` · `You mentioned <X>. Is that right, or would you like to add anything?`
- Mac: every kiosk payload inserts a new `Patient`. Never match it against an existing patient. Never read or modify `QuestionnaireVersion`.
- Reset wipes the transcript, the answers, the candidates and the `submissionID`. Nothing is persisted on the kiosk except the remembered Mac service name (`UserDefaults` key `kiosk.clinicServiceName`).

## Review Focus

1. **Patient stays silent, or says nothing usable, on a required question:** the kiosk stays on that question and asks again. It never advances with an empty name, ID or DOB. Tests: Task 4 `requiredAnswerCannotBeEmpty`, Task 8 `noSpeechKeepsListening`.
2. **Idle reset or Done-reset while a speak, listen or model call is still running:** nothing from the previous patient lands in the next session. Test: Task 9 `resetDuringTidyDiscardsLateResult`.
3. **Mac rejects the payload with an error ack** (e.g. a DOB the kiosk accepted but the Mac rejects): no retries. The kiosk goes back to review with the Mac's message and keeps the answers. Tests: Task 6 `errorAckIsNotRetried`, Task 9 `rejectedSendReturnsToReview`.
4. **Patient walks away from the "Couldn't reach the clinic" screen:** the idle timeout still wipes the session, because that screen holds identity data. Test: Task 9 `idleResetWipesAfterSendFailure`.
5. **Model returns pre-fill candidates for the current question, an already answered one, or a blank one:** these are ignored. Test: Task 4 `candidatesOnlyForLaterUnansweredQuestions`.

---

## File Structure

```
Packages/
├── KioskProtocol/                      NEW, shared by Mac and kiosk
│   ├── Package.swift                   iOS 26 + macOS 26, no dependencies
│   ├── Sources/KioskProtocol/
│   │   ├── KioskQuestions.swift        KioskQuestion, KioskQuestions.all
│   │   ├── KioskMessages.swift         KioskAnswer, KioskRequest, KioskResponse, KioskService
│   │   ├── KioskFraming.swift          frame(), KioskFrameDecoder
│   │   └── KioskDate.swift             isValidPastDOB
│   └── Tests/KioskProtocolTests/KioskProtocolTests.swift
└── GPInTheBoxKit/
    ├── Package.swift                   MODIFY: path dep on ../KioskProtocol
    ├── Sources/Records/KioskSubmission.swift      NEW: recordKioskSubmission, KioskQuestionID
    ├── Sources/Intake/KioskListener.swift         NEW
    ├── Tests/RecordsTests/KioskSubmissionTests.swift
    └── Tests/IntakeTests/KioskListenerTests.swift
GPinTheBox/GPInTheBoxApp.swift          MODIFY: start KioskListener
GPinTheBox/Info.plist                   MODIFY: local network + Bonjour keys
GPinTheBoxiOS/
├── KioskKit/                           NEW package (testable kiosk logic)
│   ├── Package.swift                   iOS 26 + macOS 26 (so `swift test` runs on the Mac)
│   ├── Sources/KioskKit/
│   │   ├── IntakeFlow.swift            pure state machine
│   │   ├── AnswerFormatting.swift      readableDOB, normaliseIdentifier
│   │   ├── Timeout.swift               withTimeout
│   │   ├── AnswerTidier.swift          AnswerModel protocol, AnswerTidier actor
│   │   ├── FoundationModelsAnswerModel.swift
│   │   ├── Submitter.swift             KioskTransport protocol, Submitter
│   │   ├── NetworkTransport.swift      NWConnection transport
│   │   ├── ClinicDiscovery.swift       ClinicSelection, ClinicBrowser
│   │   ├── Speech.swift                QuestionSpeaker/AnswerListener protocols, ListenEvent
│   │   ├── SystemQuestionSpeaker.swift AVSpeechSynthesizer adapter
│   │   ├── SpeechAnalyzerListener.swift SpeechAnalyzer adapter + SpeechSetup
│   │   └── KioskController.swift       @MainActor orchestration
│   └── Tests/KioskKitTests/            one file per source file under test + Fakes.swift
├── GPInTheBoxKiosk.xcodeproj           NEW iOS app project
└── GPInTheBoxKiosk/                    app sources: App, Welcome, Question, Review, Staff views
```

---

### Task 1: KioskProtocol shared package

**Files:**
- Create: `Packages/KioskProtocol/Package.swift`, `Packages/KioskProtocol/Sources/KioskProtocol/{KioskQuestions,KioskMessages,KioskFraming,KioskDate}.swift`
- Test: `Packages/KioskProtocol/Tests/KioskProtocolTests/KioskProtocolTests.swift`

**Interfaces:**
- Produces (all `public`):
  - `enum KioskQuestionKind: String, Sendable { case fullName, identifier, dateOfBirth, freeText }`
  - `struct KioskQuestion: Sendable, Hashable, Identifiable { let id: Int /* 0-based position */; let text: String; let kind: KioskQuestionKind; let isRequired: Bool }`
  - `enum KioskQuestions { static let all: [KioskQuestion]; static var fullName: KioskQuestion; static var identifier: KioskQuestion; static var dateOfBirth: KioskQuestion }`
  - `struct KioskAnswer: Codable, Hashable, Sendable { var q: String; var a: String }`
  - `struct KioskRequest: Codable, Hashable, Sendable { var submissionID: UUID; var answers: [KioskAnswer] }`
  - `enum KioskResponse: Codable, Equatable, Sendable { case ok; case error(message: String) }`, with hand-written coding to `{"status":"ok"}` / `{"status":"error","message":"…"}`
  - `enum KioskService { static let type = "_steadycare._tcp"; static let maxMessageBytes = 256 * 1024 }`
  - `enum KioskFramingError: Error, Equatable { case tooLarge(Int) }`
  - `enum KioskFraming { static func frame(_ body: Data) throws -> Data }`
  - `struct KioskFrameDecoder: Sendable { init(maxBytes: Int = KioskService.maxMessageBytes); mutating func append(_ data: Data) throws -> Data? }`. It returns the body once complete and throws `.tooLarge` as soon as the 4-byte header declares more than `maxBytes`.
  - `enum KioskDate { static func isValidPastDOB(_ value: String, now: Date = .now) -> Bool }`. Same rules as the Mac's `IdentityValidation.validDOB`: `en_US_POSIX`, GMT, non-lenient `yyyy-MM-dd`, round-trips, `<= now`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import KioskProtocol

@Test func questionsMatchSpecByteForByte() {
    #expect(KioskQuestions.all.map(\.text) == [
        "Full name", "Medicare or insurance ID", "Date of birth",
        "What is the main reason for your visit today?", "When did it start?", "Describe your symptoms",
        "Are you currently taking any medications? Please list them", "Do you have any allergies?",
        "Do you have any ongoing medical conditions?", "Is there anything else you'd like the doctor to know?"])
    #expect(KioskQuestions.all.map(\.isRequired) == [true, true, true] + Array(repeating: false, count: 7))
    #expect(KioskQuestions.all.map(\.id) == Array(0..<10))
    #expect(KioskQuestions.dateOfBirth.kind == .dateOfBirth && KioskQuestions.identifier.id == 1)
}
@Test func responseWireFormat() throws {
    let e = JSONEncoder(); e.outputFormatting = .sortedKeys
    #expect(String(decoding: try e.encode(KioskResponse.ok), as: UTF8.self) == #"{"status":"ok"}"#)
    #expect(String(decoding: try e.encode(KioskResponse.error(message: "No")), as: UTF8.self) == #"{"message":"No","status":"error"}"#)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: Data(#"{"status":"error","message":"x"}"#.utf8)) == .error(message: "x"))
}
@Test func requestRoundTripsWithQAKeys() throws {
    let r = KioskRequest(submissionID: UUID(), answers: [.init(q: "Full name", a: "Jane Demo")])
    let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
    #expect(json.contains(#""q":"Full name""#) && json.contains(#""a":"Jane Demo""#))
    #expect(try JSONDecoder().decode(KioskRequest.self, from: Data(json.utf8)) == r)
}
@Test func framingRoundTripsAcrossChunks() throws {
    let body = Data("{\"status\":\"ok\"}".utf8)
    let framed = try KioskFraming.frame(body)
    #expect(framed.prefix(4) == Data([0, 0, 0, UInt8(body.count)]))
    var decoder = KioskFrameDecoder()
    #expect(try decoder.append(framed.prefix(3)) == nil)
    #expect(try decoder.append(framed.dropFirst(3).prefix(5)) == nil)
    #expect(try decoder.append(framed.dropFirst(8)) == body)
}
@Test func framingRejectsOversizeFromHeaderAlone() throws {
    var decoder = KioskFrameDecoder(maxBytes: 10)
    #expect(throws: KioskFramingError.tooLarge(11)) { try decoder.append(Data([0, 0, 0, 11])) }
    #expect(throws: KioskFramingError.tooLarge(KioskService.maxMessageBytes + 1)) {
        try KioskFraming.frame(Data(count: KioskService.maxMessageBytes + 1))
    }
}
@Test func dobValidation() {
    let now = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
    #expect(KioskDate.isValidPastDOB("1980-05-01", now: now))
    for bad in ["1980-02-30", "2999-01-01", "1980-5-1", "01/05/1980", ""] { #expect(!KioskDate.isValidPastDOB(bad, now: now)) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/KioskProtocol`
Expected: FAIL, because the package and its types don't exist yet.

- [ ] **Step 3: Implement the package**

Write `Package.swift` with `platforms: [.iOS("26.0"), .macOS("26.0")]`, a library product `KioskProtocol`, and the test target. Code the questions table in the order the test gives, with kinds `fullName`, `identifier`, `dateOfBirth`, then `freeText` ×7. Give `KioskResponse` explicit `init(from:)`/`encode(to:)` keyed on `status` and `message`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/KioskProtocol`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/KioskProtocol
git commit -m "feat: add shared KioskProtocol package for kiosk questions and wire format"
```

---

### Task 2: Mac store — `recordKioskSubmission`

**Files:**
- Modify: `Packages/GPInTheBoxKit/Package.swift`. Add `.package(path: "../KioskProtocol")`, and make `Records` and `Intake` depend on `.product(name: "KioskProtocol", package: "KioskProtocol")`.
- Create: `Packages/GPInTheBoxKit/Sources/Records/KioskSubmission.swift`
- Test: `Packages/GPInTheBoxKit/Tests/RecordsTests/KioskSubmissionTests.swift`

**Interfaces:**
- Consumes: Task 1 `KioskAnswer`, `KioskRequest`, `KioskQuestions`. Existing `RecordStore`, `Patient`, `Visit`, `Answer`, `StoredSubmission`, `SubmissionReceipt`, `RecordError`, `MedicareID.normalise`, `IdentityValidation.validDOB`.
- Produces:
  - `public enum KioskQuestionID { static func forIndex(_ index: Int) -> UUID }`. Returns `00000000-0000-0000-0000-` followed by the index zero-padded to 12 digits.
  - `extension RecordStore { public func recordKioskSubmission(submissionID: UUID, answers: [KioskAnswer], receivedAt: Date = .now) throws -> SubmissionReceipt }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import SwiftData
import KioskProtocol
@testable import Records

func kioskAnswers(id: String = "demo 001", dob: String = "1980-05-01", name: String = " Jane Demo ") -> [KioskAnswer] {
    KioskQuestions.all.map { q in
        switch q.kind {
        case .fullName: KioskAnswer(q: q.text, a: name)
        case .identifier: KioskAnswer(q: q.text, a: id)
        case .dateOfBirth: KioskAnswer(q: q.text, a: dob)
        case .freeText: KioskAnswer(q: q.text, a: q.id == 3 ? "Cough" : "")
        }
    }
}
@Test func kioskSubmissionAlwaysCreatesNewPatient() async throws {
    let (store, q) = try await fixture()
    let web = try await store.recordSubmission(submission(q, medicare: "DEMO001"))
    let a = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    let b = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    #expect(a.isNewPatient && b.isNewPatient && !a.isReplay)
    #expect(Set([web.patientID, a.patientID, b.patientID]).count == 3)
    #expect(a.patientName == "Jane Demo")
}
@Test func kioskAnswersMapToDeterministicQuestionIDs() async throws {
    let (store, _) = try await fixture()
    let r = try await store.recordKioskSubmission(submissionID: UUID(), answers: kioskAnswers())
    let visit = try #require(try await store.snapshot(patientID: r.patientID).visits.first)
    #expect(visit.answers.map(\.prompt) == KioskQuestions.all.map(\.text))
    #expect(visit.answers.map(\.questionID) == (0..<10).map(KioskQuestionID.forIndex))
    #expect(KioskQuestionID.forIndex(3).uuidString == "00000000-0000-0000-0000-000000000003")
}
@Test func kioskReplayAndConflict() async throws {
    let (store, _) = try await fixture(); let id = UUID()
    let a = try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers())
    let b = try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers(), receivedAt: .now.addingTimeInterval(60))
    #expect(b.isReplay && b.visitID == a.visitID && b.patientID == a.patientID)
    await #expect(throws: RecordError.submissionConflict) {
        try await store.recordKioskSubmission(submissionID: id, answers: kioskAnswers(name: "Changed"))
    }
    #expect(try await store.snapshot(patientID: a.patientID).visits.count == 1)
}
@Test(arguments: [kioskAnswers(name: " "), kioskAnswers(id: ""), kioskAnswers(dob: "2999-01-01"), kioskAnswers(dob: "1980-02-30"),
                  Array(kioskAnswers().dropFirst(3)), []])
func kioskInvalidIdentityInsertsNothing(answers: [KioskAnswer]) async throws {
    let container = try GPInTheBoxSchema.makeContainer(inMemory: true); let store = RecordStore(modelContainer: container)
    await #expect(throws: RecordError.invalidIdentity) { try await store.recordKioskSubmission(submissionID: UUID(), answers: answers) }
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<Patient>()) == 0)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredSubmission>()) == 0)
}
@Test func kioskIdentityFoundByTextNotPosition() async throws {
    let (store, _) = try await fixture()
    let r = try await store.recordKioskSubmission(submissionID: UUID(), answers: Array(kioskAnswers().reversed()))
    let p = try await store.snapshot(patientID: r.patientID)
    #expect(p.fullName == "Jane Demo" && p.dateOfBirth == "1980-05-01")
}
```

`fixture()` and `submission(_:medicare:)` already exist in `RecordStoreTests.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter KioskSubmission`
Expected: FAIL to compile, because `recordKioskSubmission` and `KioskQuestionID` don't exist yet.

- [ ] **Step 3: Implement `recordKioskSubmission` in `KioskSubmission.swift`**

Mirror `recordSubmission`:
1. The canonical payload is `JSONEncoder` with `.sortedKeys` of `KioskRequest(submissionID:answers:)` as received, without `receivedAt`.
2. Look up the replay by `StoredSubmission.id`. An equal payload returns the previous receipt with `isReplay: true`. A different payload throws `.submissionConflict`.
3. Find the identity values with `answers.first { $0.q == KioskQuestions.fullName.text }` (likewise for the ID and DOB). Trim the name, apply `MedicareID.normalise` to the ID, and require `IdentityValidation.validDOB(dob, now: receivedAt)`. Otherwise throw `.invalidIdentity`.
4. Always insert a new `Patient` and a `Visit(arrivedAt: receivedAt, answers: answers.enumerated().map { Answer(questionID: KioskQuestionID.forIndex($0.offset), prompt: $0.element.q, value: $0.element.a) })`. Insert a `StoredSubmission` with `isNewPatient: true`, then save, rolling back on error.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/GPInTheBoxKit`
Expected: all package tests pass, the existing ones included.

- [ ] **Step 5: Commit**

```bash
git add Packages/GPInTheBoxKit/Package.swift Packages/GPInTheBoxKit/Package.resolved Packages/GPInTheBoxKit/Sources/Records/KioskSubmission.swift Packages/GPInTheBoxKit/Tests/RecordsTests/KioskSubmissionTests.swift
git commit -m "feat: record kiosk submissions as new patients with idempotent replay"
```

---

### Task 3: Mac `KioskListener` and app wiring

**Files:**
- Create: `Packages/GPInTheBoxKit/Sources/Intake/KioskListener.swift`
- Modify: `GPinTheBox/GPInTheBoxApp.swift` (`AppModel.start()`, near the `serverTask` at lines 79–85), `GPinTheBox/Info.plist`
- Test: `Packages/GPInTheBoxKit/Tests/IntakeTests/KioskListenerTests.swift`

**Interfaces:**
- Consumes: Task 1 `KioskRequest`, `KioskResponse`, `KioskFraming`, `KioskFrameDecoder`, `KioskService`. Task 2 `recordKioskSubmission`.
- Produces:
  - `public final class KioskListener: Sendable`
    - `public init(store: RecordStore, port: NWEndpoint.Port = .any, service: NWListener.Service? = NWListener.Service(type: KioskService.type), readTimeout: Duration = .seconds(10), onSubmission: @escaping @Sendable (SubmissionReceipt) async -> Void = { _ in })`
    - `public func start() async throws -> NWEndpoint.Port`. Resumes when the listener is `.ready` and throws on `.failed`.
    - `public func stop()`
    - `func respond(to body: Data) async -> KioskResponse` (internal, tested directly)
  - Error messages, exactly: decode failure → `"The request could not be read."`. Oversize → `"The request is too large."`. `RecordError` → its `localizedDescription`. Any other error → `"The clinic couldn't save this intake. Please ask reception."`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import Network
import KioskProtocol
import Records
@testable import Intake

func kioskBody(_ id: UUID = UUID(), dob: String = "1980-05-01") throws -> Data {
    try JSONEncoder().encode(KioskRequest(submissionID: id, answers: [
        .init(q: "Full name", a: "Jane Demo"), .init(q: "Medicare or insurance ID", a: "DEMO001"), .init(q: "Date of birth", a: dob)]))
}
@Test func respondSavesOnceAndAcksReplays() async throws {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)); let receipts = Receipts()
    let listener = KioskListener(store: store, service: nil, onSubmission: { await receipts.append($0) })
    let body = try kioskBody()
    #expect(await listener.respond(to: body) == .ok)
    #expect(await listener.respond(to: body) == .ok)
    #expect(await receipts.all.count == 1)
}
@Test func respondReportsErrors() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    #expect(await listener.respond(to: Data("nope".utf8)) == .error(message: "The request could not be read."))
    #expect(await listener.respond(to: try kioskBody(dob: "2999-01-01")) == .error(message: RecordError.invalidIdentity.errorDescription!))
}
@Test func loopbackFramedRequestGetsAck() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    let port = try await listener.start(); defer { listener.stop() }
    let reply = try await exchange(try KioskFraming.frame(try kioskBody()), port: port)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: reply) == .ok)
}
@Test func loopbackOversizeHeaderGetsError() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    let port = try await listener.start(); defer { listener.stop() }
    let reply = try await exchange(Data([0x00, 0x04, 0x93, 0xE0]) /* 300_000 */, port: port)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: reply) == .error(message: "The request is too large."))
}
```

`exchange(_:port:) async throws -> Data` is a test helper in the same file. It opens an `NWConnection` to `127.0.0.1:port`, sends the bytes, reads one frame through `KioskFrameDecoder`, and fails the test after 5 s. `Receipts` already exists in `IntakeTests.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter KioskListener`
Expected: FAIL to compile, because `KioskListener` doesn't exist yet.

- [ ] **Step 3: Implement `KioskListener`**

Keep the `NWListener` in a `Mutex` from `Synchronization`, and use `NWParameters.tcp`. For each connection: start it on a private queue, then read with `receive(minimumIncompleteLength: 1, maximumLength: 65_536)` into a `KioskFrameDecoder`. If the read takes longer than `readTimeout`, cancel without replying. On a full body, send `respond(to:)`. On `.tooLarge`, send the oversize error. Either way, frame the reply, send it, then cancel the connection. Call `onSubmission` only when `!receipt.isReplay`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/GPInTheBoxKit`
Expected: all package tests pass.

- [ ] **Step 5: Wire it into the app**

In `AppModel`, add `private var kioskListener: KioskListener?`. In `start()`, after the `serverTask` is created, create `KioskListener(store: store, onSubmission: { [weak self] receipt in await self?.received(receipt) })` and `try await start()` it. On failure, set `serverError = "Kiosk listener couldn't start: \(error.localizedDescription)"` if `serverError` is still nil. In `Info.plist`, add `NSLocalNetworkUsageDescription` = `SteadyCare receives intake answers from the waiting-room kiosk on this network.` and `NSBonjourServices` = `["_steadycare._tcp"]`.

- [ ] **Step 6: Build the Mac app**

Run: `xcodebuild -project GPinTheBox/GPInTheBox.xcodeproj -scheme GPInTheBox -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build`
Expected: `** BUILD SUCCEEDED **`. Then launch the app and run `dns-sd -B _steadycare._tcp`, which should list the Mac's name.

- [ ] **Step 7: Commit**

```bash
git add Packages/GPInTheBoxKit/Sources/Intake/KioskListener.swift Packages/GPInTheBoxKit/Tests/IntakeTests/KioskListenerTests.swift GPinTheBox/GPInTheBoxApp.swift GPinTheBox/Info.plist
git commit -m "feat: accept kiosk intake over Bonjour on the Mac"
```

---

### Task 4: KioskKit package and `IntakeFlow`

**Files:**
- Create: `GPinTheBoxiOS/KioskKit/Package.swift`, `Sources/KioskKit/IntakeFlow.swift`, `Sources/KioskKit/AnswerFormatting.swift`
- Test: `GPinTheBoxiOS/KioskKit/Tests/KioskKitTests/IntakeFlowTests.swift`

**Interfaces:**
- Consumes: Task 1 `KioskQuestion`, `KioskQuestions`, `KioskRequest`, `KioskAnswer`, `KioskDate`.
- Produces (all `public`):
  - `enum FlowPhase: Equatable, Sendable { case welcome, asking(Int), confirmingCandidate(Int), review, sending, sendFailed(String), done }`
  - `struct IntakeFlow: Equatable, Sendable`
    - `let questions: [KioskQuestion]`, `private(set) var answers: [String]` (index-aligned, starts as `""`), `private(set) var candidates: [Int: String]`, `private(set) var phase: FlowPhase`
    - `init(questions: [KioskQuestion] = KioskQuestions.all)`, `var currentIndex: Int?` (for asking/confirming)
    - `mutating func start()`: `welcome → asking(0)`
    - `@discardableResult mutating func answer(_ text: String) -> Bool`: sets the current answer and advances. Returns false without advancing when the trimmed text is empty and the question is required.
    - `@discardableResult mutating func skip() -> Bool`: false on required questions
    - `mutating func addCandidates(_ values: [Int: String])`: keeps only indices greater than the current one, unanswered, and with non-blank trimmed text
    - `mutating func confirmCandidate()`, `mutating func appendToCandidate(_ text: String)`. The appended result is `candidate + " " + text`. Replacing uses `answer(_:)`.
    - `mutating func edit(_ index: Int, to text: String)`: review only
    - `var canSend: Bool`, `func request(submissionID: UUID) -> KioskRequest` (values trimmed)
    - `mutating func beginSending()` (from `review` or `sendFailed`), `sendSucceeded()`, `sendFailed(_ message: String)`, `returnToReview()`
    - `static func readback(_ candidate: String) -> String`
  - `enum AnswerFormatting { static func readableDOB(_ iso: String) -> String?; static func normaliseIdentifier(_ raw: String) -> String }`. `readableDOB` uses `en_AU`, GMT and `d MMMM yyyy`. `normaliseIdentifier` uppercases and removes whitespace, `-` and `/`, matching the Mac's `MedicareID.normalise`.

Advance rule after the answer at index `i`: if `i + 1 == questions.count`, go to `review`. Otherwise, if `candidates[i + 1]` exists, go to `confirmingCandidate(i + 1)`, else to `asking(i + 1)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import KioskProtocol
@testable import KioskKit

func answeredFlow() -> IntakeFlow {
    var f = IntakeFlow(); f.start()
    f.answer("Jane Demo"); f.answer("DEMO001"); f.answer("1980-05-01")
    for _ in 3..<10 { f.skip() }
    return f
}
@Test func walksQuestionsToReview() {
    let f = answeredFlow()
    #expect(f.phase == .review && f.canSend)
    let r = f.request(submissionID: UUID())
    #expect(r.answers.map(\.q) == KioskQuestions.all.map(\.text))
    #expect(r.answers.map(\.a) == ["Jane Demo", "DEMO001", "1980-05-01"] + Array(repeating: "", count: 7))
}
@Test func requiredAnswerCannotBeEmpty() {
    var f = IntakeFlow(); f.start()
    #expect(!f.answer("  ") && !f.skip() && f.phase == .asking(0))
}
@Test func candidatesOnlyForLaterUnansweredQuestions() {
    var f = IntakeFlow(); f.start(); f.answer("Jane Demo")
    f.addCandidates([0: "Other", 1: "DEMO001", 4: "  ", 5: "Cough and fever"])
    #expect(f.candidates == [1: "DEMO001", 5: "Cough and fever"])
}
@Test func candidateConfirmAppendAndReplace() {
    var f = IntakeFlow(); f.start(); f.addCandidates([1: "DEMO001", 2: "1980-05-01", 3: "Cough"])
    f.answer("Jane Demo"); #expect(f.phase == .confirmingCandidate(1))
    f.confirmCandidate(); #expect(f.answers[1] == "DEMO001" && f.phase == .confirmingCandidate(2))
    f.answer("1981-06-02"); #expect(f.answers[2] == "1981-06-02")
    f.appendToCandidate("since Monday"); #expect(f.answers[3] == "Cough since Monday" && f.phase == .asking(4))
    #expect(IntakeFlow.readback("Cough") == "You mentioned Cough. Is that right, or would you like to add anything?")
}
@Test func canSendNeedsValidPastDOB() {
    var f = answeredFlow()
    f.edit(2, to: "2999-01-01"); #expect(!f.canSend)
    f.edit(2, to: "1 May 1980"); #expect(!f.canSend)
    f.edit(2, to: "1980-05-01"); f.edit(0, to: " "); #expect(!f.canSend)
}
@Test func sendingTransitions() {
    var f = answeredFlow()
    f.beginSending(); #expect(f.phase == .sending)
    f.sendFailed("Couldn't reach the clinic — ask reception"); f.beginSending(); f.sendSucceeded()
    #expect(f.phase == .done)
}
@Test func formatting() {
    #expect(AnswerFormatting.readableDOB("1980-05-01") == "1 May 1980")
    #expect(AnswerFormatting.readableDOB("garbage") == nil)
    #expect(AnswerFormatting.normaliseIdentifier(" demo-00 1/ ") == "DEMO001")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: FAIL, because the package doesn't exist yet.

- [ ] **Step 3: Implement the package, `IntakeFlow` and `AnswerFormatting`**

`Package.swift`: `platforms: [.iOS("26.0"), .macOS("26.0")]`, dependency `.package(path: "../../Packages/KioskProtocol")`, library `KioskKit` and test target `KioskKitTests`. Methods called in the wrong phase are no-ops.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: add KioskKit with the intake question flow"
```

---

### Task 5: `AnswerTidier` and the Foundation Models adapter

**Files:**
- Create: `Sources/KioskKit/Timeout.swift`, `Sources/KioskKit/AnswerTidier.swift`, `Sources/KioskKit/FoundationModelsAnswerModel.swift`
- Test: `Tests/KioskKitTests/AnswerTidierTests.swift`, `Tests/KioskKitTests/Fakes.swift`

**Interfaces:**
- Consumes: Task 1 `KioskQuestion`, `KioskDate`. Task 4 `AnswerFormatting.normaliseIdentifier`.
- Produces:
  - `struct TimeoutError: Error`. `func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T` races the operation against `Task.sleep` in a task group.
  - `public protocol AnswerModel: Sendable { var isAvailable: Bool { get }; func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String; func prefill(transcript: String, remaining: [KioskQuestion]) async throws -> [Int: String] }`. `prefill` is keyed by `KioskQuestion.id`.
  - `public actor AnswerTidier`
    - `init(model: any AnswerModel, timeout: Duration = .seconds(5))`
    - `private(set) var prefillEnabled: Bool`. Starts as `model.isAvailable` and turns false after any fallback.
    - `func tidy(_ transcript: String, for question: KioskQuestion) async -> String`
    - `func prefill(transcript: String, remaining: [KioskQuestion]) async -> [Int: String]`. Returns `[:]` when disabled. An error or timeout returns `[:]` and disables pre-fill.
    - `func reset()`. Sets `prefillEnabled = model.isAvailable`.
  - `public struct FoundationModelsAnswerModel: AnswerModel` with `init()`
  - Fakes in `Fakes.swift`, used again by Tasks 6–9: `struct FakeError: Error {}`, and `FakeAnswerModel(isAvailable: Bool = true, tidied: [String: String] = [:], prefill: [Int: String] = [:], delay: Duration? = nil, error: Error? = nil)`. `tidy` returns `tidied[transcript] ?? transcript`.

`tidy` rules, in order:
1. Unavailable, throws, or timed out → the trimmed raw transcript, and pre-fill is disabled.
2. `.identifier` → `normaliseIdentifier(modelOutput)`.
3. `.dateOfBirth` → the model output if `KioskDate.isValidPastDOB`, else the trimmed raw transcript.
4. A blank model output for a non-blank transcript → the raw transcript.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func tidyUsesModelAndNormalisesID() async {
    let t = AnswerTidier(model: FakeAnswerModel(tidied: ["D E M O zero zero one": "demo 001"]))
    #expect(await t.tidy("D E M O zero zero one", for: KioskQuestions.identifier) == "DEMO001")
}
@Test func invalidModelDateFallsBackToTranscript() async {
    let t = AnswerTidier(model: FakeAnswerModel(tidied: ["first of may eighty": "1980-13-01"]))
    #expect(await t.tidy("first of may eighty", for: KioskQuestions.dateOfBirth) == "first of may eighty")
}
@Test(arguments: [FakeAnswerModel(isAvailable: false), FakeAnswerModel(error: FakeError()), FakeAnswerModel(delay: .seconds(1))])
func fallbackUsesRawTranscriptAndDisablesPrefill(model: FakeAnswerModel) async {
    let t = AnswerTidier(model: model, timeout: .milliseconds(50))
    #expect(await t.tidy(" um a cough ", for: KioskQuestions.all[3]) == "um a cough")
    #expect(await t.prefillEnabled == false)
    #expect(await t.prefill(transcript: "x", remaining: Array(KioskQuestions.all.dropFirst(4))) == [:])
}
@Test func prefillPassesThroughAndResetReenables() async {
    let t = AnswerTidier(model: FakeAnswerModel(prefill: [5: "Cough"]))
    #expect(await t.prefill(transcript: "I've had a cough", remaining: Array(KioskQuestions.all.dropFirst(4))) == [5: "Cough"])
    await t.reset(); #expect(await t.prefillEnabled)
}
@Test(.enabled(if: FoundationModelsAnswerModel().isAvailable))
func realModelTidiesSyntheticJane() async throws {
    let m = FoundationModelsAnswerModel()
    #expect(try await m.tidy("um my name is Jane Demo", for: KioskQuestions.fullName).contains("Jane Demo"))
    #expect(try await m.tidy("the first of May nineteen eighty", for: KioskQuestions.dateOfBirth) == "1980-05-01")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter AnswerTidier`
Expected: FAIL to compile.

- [ ] **Step 3: Implement `withTimeout`, `AnswerTidier` and `FoundationModelsAnswerModel`**

`isAvailable` is `SystemLanguageModel.default.availability == .available`. Use a fresh `LanguageModelSession(instructions:)` per call, so nothing carries over between patients. Use these exact instructions:

> You tidy a patient's spoken answer to one clinic intake question. Remove filler words, false starts and repetitions. Keep the patient's own words. Never add information, never guess, and never give medical advice or a diagnosis. If the answer is unclear, return it unchanged.

`@Generable` types:
- `TidiedText { var answer: String }` for `fullName`, `identifier` (guide: spell the ID as letters and digits) and `freeText`.
- `TidiedDate { var year: Int; var month: Int; var day: Int }`, formatted as `%04d-%02d-%02d`.
- `PrefillResult { var candidates: [PrefillCandidate] }`, with `PrefillCandidate { var questionNumber: Int; var answer: String }`. The prompt lists the remaining questions numbered by `id + 1` and says to answer only questions the transcript explicitly addresses. Map back by `questionNumber - 1`, and drop numbers not in `remaining`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all tests pass. `realModelTidiesSyntheticJane` runs only if Apple Intelligence is available on this Mac and is skipped otherwise.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: tidy kiosk answers on device with raw-transcript fallback"
```

---

### Task 6: Submitter, network transport and clinic discovery

**Files:**
- Create: `Sources/KioskKit/Submitter.swift`, `Sources/KioskKit/NetworkTransport.swift`, `Sources/KioskKit/ClinicDiscovery.swift`
- Test: `Tests/KioskKitTests/SubmitterTests.swift`, `Tests/KioskKitTests/ClinicDiscoveryTests.swift`

**Interfaces:**
- Consumes: Task 1 framing and messages. Task 5 `withTimeout`.
- Produces:
  - `public protocol KioskTransport: Sendable { func send(_ request: KioskRequest) async throws -> KioskResponse }`
  - `public enum SubmitOutcome: Equatable, Sendable { case accepted, rejected(String), unreachable }`
  - `public struct Submitter: Sendable { init(transport: any KioskTransport, backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)], deadline: Duration = .seconds(30)); func submit(_ request: KioskRequest) async -> SubmitOutcome }`
    - `.ok` → `.accepted`. `.error(m)` → `.rejected(m)` with no retry. A thrown error retries after the next backoff, repeating the last value once the list runs out. When the deadline passes, including partway through an attempt, the result is `.unreachable`.
  - `public struct NetworkTransport: KioskTransport { init(endpoint: NWEndpoint, attemptTimeout: Duration = .seconds(10)) }`. One `NWConnection` per send: frame, send, read with `KioskFrameDecoder`, decode, cancel.
  - `public enum ClinicChoice: Equatable, Sendable { case none, connected(String), needsPicker([String]) }`
  - `public enum ClinicSelection { static func choose(available: [String], remembered: String?) -> ClinicChoice }`
  - `@MainActor @Observable public final class ClinicBrowser { private(set) var services: [String: NWEndpoint]; func start(); func stop() }`. Wraps `NWBrowser(for: .bonjour(type: KioskService.type, domain: nil), using: .tcp)` and keys services by name.
  - `FakeTransport(results: [Result<KioskResponse, Error>])`, which records the requests it receives, goes in `Fakes.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
let req = KioskRequest(submissionID: UUID(), answers: [.init(q: "Full name", a: "Jane Demo")])
@Test func retriesReuseSubmissionIDUntilOk() async {
    let t = FakeTransport(results: [.failure(FakeError()), .failure(FakeError()), .success(.ok)])
    let outcome = await Submitter(transport: t, backoff: [.milliseconds(1)], deadline: .seconds(2)).submit(req)
    #expect(outcome == .accepted)
    #expect(await t.requests == [req, req, req])
}
@Test func errorAckIsNotRetried() async {
    let t = FakeTransport(results: [.success(.error(message: "Enter a valid date of birth.")), .success(.ok)])
    #expect(await Submitter(transport: t, backoff: [.milliseconds(1)]).submit(req) == .rejected("Enter a valid date of birth."))
    #expect(await t.requests.count == 1)
}
@Test func deadlineGivesUnreachable() async {
    let t = FakeTransport(results: Array(repeating: .failure(FakeError()), count: 100))
    #expect(await Submitter(transport: t, backoff: [.milliseconds(20)], deadline: .milliseconds(100)).submit(req) == .unreachable)
}
@Test func clinicSelection() {
    #expect(ClinicSelection.choose(available: [], remembered: "A") == .none)
    #expect(ClinicSelection.choose(available: ["Front Desk"], remembered: nil) == .connected("Front Desk"))
    #expect(ClinicSelection.choose(available: ["B", "A"], remembered: "A") == .connected("A"))
    #expect(ClinicSelection.choose(available: ["B", "A"], remembered: "Gone") == .needsPicker(["A", "B"]))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter "Submitter|Clinic"`
Expected: FAIL to compile.

- [ ] **Step 3: Implement `Submitter`, `NetworkTransport`, `ClinicSelection` and `ClinicBrowser`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all tests pass.

- [ ] **Step 5: Check the transport against the real Mac listener**

Launch the Mac app from Task 3. Add a temporary `@Test(.disabled())` in `SubmitterTests` (delete it afterwards) or use a scratch script that sends a synthetic Jane `KioskRequest` through `NetworkTransport(endpoint: .hostPort(host: "127.0.0.1", port: <port from dns-sd -L>))`.
Expected: `.ok`, and Jane appears as a new patient in the Mac queue.

- [ ] **Step 6: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: submit kiosk payloads with retry and discover the clinic Mac"
```

---

### Task 7: Speech adapters

**Files:**
- Create: `Sources/KioskKit/Speech.swift`, `Sources/KioskKit/SystemQuestionSpeaker.swift`, `Sources/KioskKit/SpeechAnalyzerListener.swift`
- Test: `Tests/KioskKitTests/SpeechSetupTests.swift`

**Interfaces:**
- Produces:
  - `public enum ListenEvent: Equatable, Sendable { case partial(String), final(String) }`. `partial` is the finalized text plus the volatile text, used for captions. `final` is the cumulative finalized text.
  - `public protocol AnswerListener: Sendable { func listen() -> AsyncThrowingStream<ListenEvent, Error>; func stop() async }`. `stop()` finalizes the input, emits the last `.final` and finishes the stream.
  - `public protocol QuestionSpeaker: Sendable { func speak(_ text: String) async; func stop() async }`. `speak` returns when playback ends or is stopped.
  - `public enum SpeechReadiness: Equatable, Sendable { case ready(localeID: String, isFallback: Bool), needsDownload, unavailable(String) }`
  - `public enum SpeechSetup { static func readiness() async -> SpeechReadiness; static func downloadAssets() async throws; static func locale() async -> (Locale, isFallback: Bool)? }`
  - `public final class SystemQuestionSpeaker: QuestionSpeaker`, which uses an `AVSpeechSynthesizer` with `AVSpeechSynthesisVoice(language: "en-AU")`
  - `public final class SpeechAnalyzerListener: AnswerListener { init(locale: Locale) }`
  - `FakeSpeaker` (records the spoken strings) and `FakeListener(script: [[ListenEvent]])` go in `Fakes.swift`. Each `listen()` pops the next script, yields its events, then waits for `stop()` before finishing. An empty queue yields nothing and waits.

- [ ] **Step 1: Write the failing test**

```swift
@Test func setupPrefersAustralianEnglish() async {
    guard let (locale, isFallback) = await SpeechSetup.locale() else { return }   // no transcriber on this host
    #expect(isFallback ? locale.identifier.hasPrefix("en_US") || locale.identifier.hasPrefix("en-US") : locale.identifier.hasPrefix("en_AU") || locale.identifier.hasPrefix("en-AU"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter SpeechSetup`
Expected: FAIL to compile.

- [ ] **Step 3: Implement the adapters**

`SpeechSetup.locale()`:
- Return `SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_AU"))` with `isFallback: false`.
- Failing that, return `en_US` with `isFallback: true`.
- Otherwise return nil.

`readiness()`:
- Check microphone and speech permission first. If either is denied, return `.unavailable(reason)`.
- Then check `AssetInventory.status(forModules:)`: `.installed` means `.ready`, anything else means `.needsDownload`.

`downloadAssets()`: `try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()`.

`SpeechAnalyzerListener`:
- Create `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])` and a `SpeechAnalyzer(modules:)`.
- Feed it buffers from an `AVAudioEngine` input tap, converted to `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` with `AVAudioConverter`.
- `stop()` removes the tap, stops the engine and calls `finalizeAndFinishThroughEndOfInput()`.

Audio session (`#if os(iOS)`): `.playAndRecord`, mode `.spokenAudio`, options `[.defaultToSpeaker, .duckOthers]`. The speaker activates it before speaking. The listener opens the mic only after `speak` has returned (the controller enforces this order).

- [ ] **Step 4: Run the tests and build for iOS**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit` and then `xcodebuild -scheme KioskKit -destination 'generic/platform=iOS Simulator' build` from `GPinTheBoxiOS/KioskKit`
Expected: tests pass, and `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: add on-device speech synthesis and SpeechAnalyzer transcription adapters"
```

---

### Task 8: `KioskController`, the question loop

**Files:**
- Create: `Sources/KioskKit/KioskController.swift`
- Test: `Tests/KioskKitTests/KioskControllerQuestionTests.swift`

**Interfaces:**
- Consumes: Tasks 4–7 (`IntakeFlow`, `AnswerTidier`, `Submitter`, `QuestionSpeaker`, `AnswerListener`, `ListenEvent`, and the fakes).
- Produces:
  - `public struct KioskTimings: Sendable { var silence, idle, idleGrace, doneReset: Duration; static let standard = KioskTimings(silence: .milliseconds(1500), idle: .seconds(120), idleGrace: .seconds(20), doneReset: .seconds(5)) }`. The model timeout and the send deadline live in `AnswerTidier` and `Submitter`.
  - `public enum InputMode: Sendable { case voice, typing }`
  - `@MainActor @Observable public final class KioskController`
    - `init(speaker: any QuestionSpeaker, listener: (any AnswerListener)?, tidier: AnswerTidier, timings: KioskTimings = .standard)`. A nil listener means typing mode.
    - `var submitter: Submitter?`. Set by the app once a clinic resolves. `start()` is a no-op while it's nil.
    - `private(set) var flow: IntakeFlow`, `caption: String`, `isListening: Bool`, `isAskingStillThere: Bool`, `transcript: String`
    - `var inputMode: InputMode`
    - Actions (synchronous; each cancels or replaces the current `sessionTask`): `start()`, `finishAnswer()` (the **Done** button), `repeatQuestion()`, `skip()`, `submitTyped(_ text: String)`, `confirmCandidate()`, `addToCandidate()`, `replaceCandidate()`
  - Test helper `func eventually(_ condition: @MainActor () -> Bool) async`, which polls every 10 ms and fails after 2 s, goes in `Fakes.swift`.

Loop for the current question:
1. Speak `question.text`, or `IntakeFlow.readback(candidate)` when confirming a candidate.
2. In voice mode, listen. Each event updates `caption`, counts as activity, and restarts the silence timer. The timer starts only after the first event, and when it fires it calls `listener.stop()`.
3. When the stream ends, take the last `.final` text, append it to `transcript`, and run `tidier.tidy`.
4. Call `flow.answer` (or `appendToCandidate` after `addToCandidate()`). If it returns false, ask the same question again.
5. Then call `tidier.prefill(transcript:remaining:)` with `flow.addCandidates`, and loop until the phase is `review`.

`submitTyped` uses the typed text as-is, with no model call, and applies it synchronously, so consecutive calls answer consecutive questions. `confirmCandidate()` answers without listening. `addToCandidate()` and `replaceCandidate()` listen without speaking.

- [ ] **Step 1: Write the failing tests**

```swift
func makeController(_ script: [[ListenEvent]], model: FakeAnswerModel = FakeAnswerModel()) -> (KioskController, FakeSpeaker) {
    let speaker = FakeSpeaker()
    let c = KioskController(speaker: speaker, listener: FakeListener(script: script), tidier: AnswerTidier(model: model, timeout: .milliseconds(100)),
                            timings: KioskTimings(silence: .milliseconds(30), idle: .seconds(60), idleGrace: .seconds(60), doneReset: .seconds(60)))
    c.submitter = Submitter(transport: FakeTransport(results: [.success(.ok)]))
    return (c, speaker)
}
@MainActor @Test func silenceEndsAnswerAndAdvances() async {
    let (c, speaker) = makeController([[.partial("Jane"), .final("Jane Demo")]])
    c.start()
    await eventually { c.flow.phase == .asking(1) }
    #expect(c.flow.answers[0] == "Jane Demo")
    #expect(speaker.spoken.prefix(2) == ["Full name", "Medicare or insurance ID"])
}
@MainActor @Test func noSpeechKeepsListening() async throws {
    let (c, _) = makeController([])
    c.start(); await eventually { c.isListening }
    try await Task.sleep(for: .milliseconds(200))
    #expect(c.isListening && c.flow.phase == .asking(0))
}
@MainActor @Test func emptyRequiredAnswerIsAskedAgain() async {
    let (c, speaker) = makeController([[.final("")], [.final("Jane Demo")]])
    c.start(); await eventually { c.flow.phase == .asking(1) }
    #expect(speaker.spoken.prefix(2) == ["Full name", "Full name"])
}
@MainActor @Test func prefillIsReadBackAndConfirmed() async {
    let (c, speaker) = makeController([[.final("Jane Demo, my ID is DEMO001")]], model: FakeAnswerModel(prefill: [1: "DEMO001"]))
    c.start(); await eventually { c.flow.phase == .confirmingCandidate(1) }
    #expect(speaker.spoken.last == "You mentioned DEMO001. Is that right, or would you like to add anything?")
    c.confirmCandidate(); await eventually { c.flow.phase == .asking(2) }
    #expect(c.flow.answers[1] == "DEMO001")
}
@MainActor @Test func skipAndRepeatAndTyping() async {
    let typing = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)))
    typing.submitter = Submitter(transport: FakeTransport(results: []))
    #expect(typing.inputMode == .typing)
    typing.start(); typing.submitTyped("Jane Demo"); typing.submitTyped("DEMO001"); typing.submitTyped("1980-05-01")
    await eventually { typing.flow.phase == .asking(3) }
    typing.skip(); await eventually { typing.flow.phase == .asking(4) }
    let (c, speaker) = makeController([])
    c.start(); await eventually { c.isListening }; c.repeatQuestion()
    await eventually { speaker.spoken == ["Full name", "Full name"] }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter KioskControllerQuestion`
Expected: FAIL to compile.

- [ ] **Step 3: Implement the question loop in `KioskController`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit`
Expected: all tests pass. Run it 3 times to check that the timing-based tests are stable.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: drive spoken intake questions with silence detection and pre-fill readback"
```

---

### Task 9: `KioskController` — review, send, done, idle, reset

**Files:**
- Modify: `Sources/KioskKit/KioskController.swift`
- Test: `Tests/KioskKitTests/KioskControllerSessionTests.swift`

**Interfaces:**
- Consumes: Task 8 `KioskController`, `makeController` (move it into `Fakes.swift` and add a `transport:` parameter).
- Produces (on `KioskController`):
  - `func edit(_ index: Int, to text: String)`, `func respeak(_ index: Int)` (listen, tidy, then `edit`), `func send()`, `func noteActivity()`, `func stillHere()`, `func reset()`
  - `send()` creates one `submissionID` per session, reused across retries and **Send to clinic** taps. `.accepted` leads to `flow.sendSucceeded()`, then a reset after `doneReset`. `.rejected(m)` leads to `flow.sendFailed(m)` then `flow.returnToReview()`, and `lastError = m`. `.unreachable` leads to `flow.sendFailed("Couldn't reach the clinic — ask reception")`.
  - `private(set) var lastError: String?`
  - Idle: any action or `ListenEvent` counts as activity. After `idle` with no activity in any phase except `welcome`, `sending` and `done`, `isAskingStillThere` becomes true. After a further `idleGrace`, the controller resets. `stillHere()` clears the prompt.
  - `reset()` cancels the session, idle and done tasks, calls `speaker.stop()`, `listener.stop()` and `tidier.reset()`, then sets `flow = IntakeFlow()` and clears `caption`, `transcript`, `lastError`, `isAskingStillThere` and the `submissionID`. A late result from a cancelled task must not write state. Guard on a session generation counter.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor func controllerAtReview(_ transport: FakeTransport, timings: KioskTimings = .test) async -> KioskController {
    let c = KioskController(speaker: FakeSpeaker(), listener: nil, tidier: AnswerTidier(model: FakeAnswerModel(isAvailable: false)), timings: timings)
    c.submitter = Submitter(transport: transport, backoff: [.milliseconds(1)], deadline: .milliseconds(200))
    c.start(); for text in ["Jane Demo", "DEMO001", "1980-05-01"] { c.submitTyped(text) }
    for _ in 3..<10 { await eventually { c.flow.currentIndex != nil }; c.skip() }
    await eventually { c.flow.phase == .review }
    return c
}
@MainActor @Test func acceptedSendShowsDoneThenWipes() async {
    let t = FakeTransport(results: [.success(.ok)])
    let c = await controllerAtReview(t, timings: .test.with(doneReset: .milliseconds(50)))
    c.send(); await eventually { c.flow.phase == .done }
    await eventually { c.flow == IntakeFlow() && c.transcript.isEmpty }
}
@MainActor @Test func retriedSendKeepsSubmissionID() async {
    let t = FakeTransport(results: Array(repeating: .failure(FakeError()), count: 500))
    let c = await controllerAtReview(t)
    c.send(); await eventually { c.flow.phase == .sendFailed("Couldn't reach the clinic — ask reception") }
    #expect(c.flow.answers[0] == "Jane Demo")
    c.send(); await eventually { if case .sendFailed = c.flow.phase { true } else { false } }
    #expect(Set(await t.requests.map(\.submissionID)).count == 1)
}
@MainActor @Test func rejectedSendReturnsToReview() async {
    let c = await controllerAtReview(FakeTransport(results: [.success(.error(message: "Enter a valid date of birth."))]))
    c.send(); await eventually { c.lastError == "Enter a valid date of birth." }
    #expect(c.flow.phase == .review && c.flow.answers[2] == "1980-05-01")
}
@MainActor @Test func idlePromptThenReset() async {
    let c = await controllerAtReview(FakeTransport(results: []), timings: .test.with(idle: .milliseconds(50), idleGrace: .milliseconds(50)))
    await eventually { c.isAskingStillThere }
    c.stillHere(); #expect(!c.isAskingStillThere && c.flow.phase == .review)
    await eventually { c.flow.phase == .welcome && c.flow.answers.allSatisfy(\.isEmpty) }
}
@MainActor @Test func idleResetWipesAfterSendFailure() async {
    let c = await controllerAtReview(FakeTransport(results: Array(repeating: .failure(FakeError()), count: 500)),
                                     timings: .test.with(idle: .milliseconds(400), idleGrace: .milliseconds(50)))
    c.send(); await eventually { if case .sendFailed = c.flow.phase { true } else { false } }
    await eventually { c.flow.phase == .welcome && c.flow.answers.allSatisfy(\.isEmpty) }
}
@MainActor @Test func resetDuringTidyDiscardsLateResult() async throws {
    let (c, _) = makeController([[.final("Jane Demo")]], model: FakeAnswerModel(delay: .milliseconds(80)))
    c.start(); await eventually { c.transcript == "Jane Demo" }
    c.reset(); try await Task.sleep(for: .milliseconds(200))
    #expect(c.flow == IntakeFlow() && c.transcript.isEmpty)
}
```

`KioskTimings.test` (silence 30 ms; the others 60 s) and `with(idle:idleGrace:doneReset:)` are test-only extensions in `Fakes.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit --filter KioskControllerSession`
Expected: FAIL to compile.

- [ ] **Step 3: Implement review, send, idle and reset**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path GPinTheBoxiOS/KioskKit` (3 times)
Expected: all tests pass on every run.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBoxiOS/KioskKit
git commit -m "feat: review, send, idle timeout and wipe for kiosk sessions"
```

---

### Task 10: iOS app target and screens

**Files:**
- Create: `GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj`, using Xcode's iOS App template through the Xcode MCP `XcodeNewProject` tool or File › New › Project. Product name `GPInTheBoxKiosk`, display name `SteadyCare Kiosk`, bundle ID `com.gpinthebox.kiosk`, SwiftUI, iOS 26.0, iPhone + iPad. Add the local package `GPinTheBoxiOS/KioskKit`.
- Create: `GPinTheBoxiOS/GPInTheBoxKiosk/{KioskApp,WelcomeView,QuestionView,ReviewView,StaffSetupView}.swift`, and Info.plist keys

**Interfaces:**
- Consumes: Task 6 `ClinicBrowser`, `ClinicSelection`, `NetworkTransport`, `Submitter`. Task 7 `SpeechSetup`, `SystemQuestionSpeaker`, `SpeechAnalyzerListener`. Tasks 8–9 `KioskController`.

- [ ] **Step 1: Create the project and Info.plist keys**

- `NSMicrophoneUsageDescription`: `The kiosk listens to your spoken answers to the intake questions.`
- `NSSpeechRecognitionUsageDescription`: `Your answers are transcribed on this device.`
- `NSLocalNetworkUsageDescription`: `The kiosk sends your answers to the clinic's Mac on this network.`
- `NSBonjourServices`: `["_steadycare._tcp"]`

- [ ] **Step 2: Implement `KioskApp`**

At launch:
- Set `UIApplication.shared.isIdleTimerDisabled = true`.
- Start `ClinicBrowser`.
- Compute `SpeechSetup.readiness()`. `.ready` builds `SpeechAnalyzerListener(locale:)`. Anything else passes `listener: nil` (typing mode).
- Build `KioskController(speaker: SystemQuestionSpeaker(), listener:, tidier: AnswerTidier(model: FoundationModelsAnswerModel()))`.

When `browser.services` changes, apply `ClinicSelection.choose(available:remembered: UserDefaults.standard.string(forKey: "kiosk.clinicServiceName"))`. `.connected(name)` sets `controller.submitter = Submitter(transport: NetworkTransport(endpoint: services[name]!))`. Anything else sets it to nil.

A root `.simultaneousGesture(TapGesture().onEnded { controller.noteActivity() })` covers activity, and an alert bound to `isAskingStillThere` titled `Are you still there?` calls `stillHere()`. Route screens by `controller.flow.phase`.

- [ ] **Step 3: Implement the screens**

- **WelcomeView:** a large `Tap to start.` button. If `submitter == nil`, show `Clinic not found — ask reception` with the button disabled. A long-press of 2 s opens `StaffSetupView`. If the locale is a fallback, show a small `Speech: English (US) — en-AU unavailable` badge.
- **StaffSetupView:** a picker over the service names that writes `kiosk.clinicServiceName`, the speech readiness, and a **Download speech assets** button that calls `SpeechSetup.downloadAssets()`.
- **QuestionView:** the question text (large), the live `caption`, and `Done`, `Repeat question` and `Skip` buttons, with Skip hidden when `isRequired`. In typing mode, or behind a "Type instead" button, show a text field that calls `submitTyped`. When confirming a candidate, show the readback text with **That's right** / **Add more** / **Replace** buttons.
- **ReviewView:** list all 10 questions. Show DOB through `AnswerFormatting.readableDOB`, falling back to the raw text. Tapping a row opens a sheet with a text field (`edit`) and **Speak again** (`respeak`). Show `lastError` above the list. `Send to clinic` is disabled unless `flow.canSend`.
- **Sending / failed / done:** a spinner while sending. On failure, the message plus a **Try again** button (`send()`). On done, `Thanks, please take a seat.`

- [ ] **Step 4: Build**

Run: `xcodebuild -project GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj -scheme GPInTheBoxKiosk -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath DerivedData build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke-test in the Simulator alongside the Mac app**

Run the Mac app, then the kiosk on the iPhone 17 Pro simulator. The Simulator shares the Mac's network, so Bonjour resolves. Use typing mode if the Simulator has no speech assets, and enter the synthetic Jane Demo answers.
Expected: Welcome becomes enabled, all 10 questions are asked, review shows `1 May 1980`, Send gives `Thanks, please take a seat.` then a reset to Welcome after about 5 s, and Jane appears in the Mac queue as a new patient.

- [ ] **Step 6: Commit**

```bash
git add GPinTheBoxiOS/GPInTheBoxKiosk.xcodeproj GPinTheBoxiOS/GPInTheBoxKiosk
git commit -m "feat: add SteadyCare voice intake kiosk iOS app"
```

---

### Task 11: Documentation and on-device verification

**Files:**
- Modify: `README.md` (new section **Voice intake kiosk (iOS)**), `GPinTheBoxiOS/docs/superpowers/specs/2026-10-24-voice-intake-kiosk-design.md` (status line)

- [ ] **Step 1: Write the README section**

Cover:
- Requirements: an Apple Intelligence–capable iPhone/iPad on iOS 26, on the same Wi-Fi as the Mac.
- Build command, and the staff setup steps: long-press the welcome screen to pick the Mac and download speech assets, then enable Guided Access.
- Test commands: `swift test --package-path Packages/KioskProtocol` and `swift test --package-path GPinTheBoxiOS/KioskKit`.
- The Known consequences from the spec, word for word in substance: duplicate patients, no "Patient history recovered" for kiosk visits, a possible `identityCollision` on **Correct identity**, no transport security, and shared-kiosk privacy.

- [ ] **Step 2: Manual checklist on a real device** (record the results in the README section)

1. First launch: Local Network and microphone prompts appear on the kiosk, and the Local Network prompt appears on the Mac.
2. Speak the synthetic Jane Demo script ("Jane Demo", "D E M O zero zero one", "first of May nineteen eighty", "I've had a cough since Monday"). The ID is tidied to `DEMO001`, the DOB shows as `1 May 1980`, and "When did it start?" is read back as a pre-fill.
3. Turn off Wi-Fi during Send. After about 30 s, `Couldn't reach the clinic — ask reception` appears. Turn Wi-Fi back on and tap Try again: exactly one new patient appears on the Mac.
4. Run two Macs advertising the service: the staff picker appears and the choice is remembered across relaunch.
5. Leave the kiosk for 2 min mid-question: `Are you still there?` appears, then after 20 s the kiosk is back at Welcome with nothing left on screen.
6. Note whether `en_AU` was available on the device. If not, record the fallback.

- [ ] **Step 3: Update the spec status and commit**

Change `Status: Draft for review` to `Status: Implemented (v1)`.

```bash
git add README.md GPinTheBoxiOS/docs/superpowers/specs/2026-10-24-voice-intake-kiosk-design.md
git commit -m "doc: document the voice intake kiosk and its on-device checks"
```
