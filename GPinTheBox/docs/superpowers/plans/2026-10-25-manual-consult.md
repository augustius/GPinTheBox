# Manual Consult Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a GP start a consultation for a database patient with no intake. A **Consult** button in the Patient database window adds an open visit to today's queue and opens it. The visit links to the database record, and the Patient brief shows that record's live profile.

**Architecture:**
- The record logic is a new static `RecordMutations.startManualConsult` in the `Records` package. It runs on the app's main `ModelContext`, like `correctIdentity`, and is unit-tested with in-memory containers.
- `Visit` gains one optional `databasePatientID`.
- The app adds the button to `DatabasePatientDetail` and a GP-added branch to the Patient brief (`intakeSection`).

**Tech Stack:** Swift 6.4, SwiftData, SwiftUI (macOS 26), Swift Testing. `swift test --package-path Packages/GPInTheBoxKit`.

**Spec:** `GPinTheBox/docs/superpowers/specs/2026-10-25-manual-consult-design.md`

## Global Constraints

- **Matching an intake patient:** normalised Medicare (`MedicareID.normalise`) plus an identical `dateOfBirth` (`yyyy-MM-dd`), exactly as web intake matches.
- **Consult is blocked** (button disabled, function throws `RecordError.invalidIdentity`) when `medicare_number` normalises to empty, or `date_of_birth` fails `IdentityValidation.validDOB`.
- **No duplicates today:** if the matched patient has a visit arrived on the same calendar day (`Visit.arrivedOnSameDay`) whose status isn't `.done`, return that visit; it moves from `waiting` to `inConsult` via `open()`, and nothing is inserted.
- **New visit:** `Visit(arrivedAt: now, answers: [])`, status `inConsult`, `databasePatientID = patient_id`, and the patient's `revision` is bumped.
- **New intake patient name:** `"first_name last_name"`, trimmed.
- **Schema:** `Visit` gains only `public var databasePatientID: String?` (default nil). Intake visits leave it nil.
- **Brief copy:**
  - Banner: `No intake — added by the GP from the patient database (P10338)`, where the ID is the visit's `databasePatientID`.
  - Field labels: `Allergies`, `Current medications`, `Medical conditions`, `Notes`.
  - Empty field: `Not recorded`.
  - Missing record: `Database record no longer available`.
  - The brief never says "Patient-reported" for these visits.
- **Block reasons (copy):** `No Medicare number on this record.` and `Date of birth isn't a valid date (yyyy-MM-dd).`
- No changes to the kiosk, the web intake, or patient matching for intake.

## Review Focus

1. **Medicare formatted differently** in the database (`5841685927/3`) and on intake (`58416859273`): the same intake patient is reused. Test: Task 1 `reusesMatchingIntakePatient`.
2. **Same Medicare, different DOB:** a separate patient is created and never merged. Test: Task 1 `differentDOBIsSeparatePatient`.
3. **Patient already submitted intake earlier today** (waiting visit): Consult opens that visit (becomes in consult) and adds no second visit. Test: Task 1 `reopensUnfinishedVisitToday`.
4. **An unfinished visit from yesterday, or a finished one today,** doesn't block a new visit today. Test: Task 1 `onlyUnfinishedVisitsTodayAreReused`.
5. **Store saved before this change opens fine,** and intake visits keep a nil link. Test: Task 1 `intakeVisitPersistsWithNilDatabaseID`.

---

### Task 1: Records — `startManualConsult` and the visit link

**Files:**
- Modify: `Packages/GPInTheBoxKit/Sources/Records/Models.swift` (`Visit`)
- Modify: `Packages/GPInTheBoxKit/Sources/Records/RecordStore.swift` (`RecordMutations`)
- Modify: `Packages/GPInTheBoxKit/Sources/Records/DatabasePatient.swift` (block reason)
- Test: `Packages/GPInTheBoxKit/Tests/RecordsTests/ManualConsultTests.swift`

**Interfaces:**
- Produces:
  - `Visit.databasePatientID: String?`
  - `extension DatabasePatient { public var consultBlockReason: String? }`: nil when Consult is allowed, otherwise one of the two block-reason strings.
  - `public static func startManualConsult(context: ModelContext, databasePatient: DatabasePatient, now: Date = .now, calendar: Calendar = .current) throws -> Visit` on `RecordMutations`. Saves the context, and rolls back on error.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import SwiftData
@testable import Records

func dbPatient(id: String = "P10338", medicare: String = "5841685927/3", dob: String = "1943-08-10") -> DatabasePatient {
    DatabasePatient(row: ["patient_id": id, "first_name": "Aurora", "last_name": "Adams", "date_of_birth": dob, "medicare_number": medicare])
}
func context() throws -> ModelContext { ModelContext(try GPInTheBoxSchema.makeContainer(inMemory: true)) }
let noon = ISO8601DateFormatter().date(from: "2026-10-25T02:00:00Z")!

@Test func createsPatientAndOpenVisit() throws {
    let c = try context(); let db = dbPatient(); c.insert(db)
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.status == .inConsult && v.answers.isEmpty && v.databasePatientID == "P10338" && v.arrivedAt == noon)
    let p = try #require(v.patient)
    #expect(p.fullName == "Aurora Adams" && p.medicareID == "58416859273" && p.dateOfBirth == "1943-08-10")
}
@Test func reusesMatchingIntakePatient() throws {
    let c = try context(); let existing = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10")
    c.insert(existing); let db = dbPatient(); c.insert(db); try c.save(); let before = existing.revision
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.patient?.id == existing.id && existing.revision != before)
    #expect(try c.fetchCount(FetchDescriptor<Patient>()) == 1)
}
@Test func differentDOBIsSeparatePatient() throws {
    let c = try context(); c.insert(Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1950-01-01"))
    let db = dbPatient(); c.insert(db)
    _ = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(try c.fetchCount(FetchDescriptor<Patient>()) == 2)
}
@Test func reopensUnfinishedVisitToday() throws {
    let c = try context(); let db = dbPatient(); c.insert(db)
    let p = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10"); c.insert(p)
    let intake = Visit(arrivedAt: noon.addingTimeInterval(-3600), answers: [Answer(questionID: UUID(), prompt: "Reason", value: "Cough")])
    c.insert(intake); p.visits.append(intake); try c.save()
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.id == intake.id && v.status == .inConsult && v.databasePatientID == nil)
    #expect(try c.fetchCount(FetchDescriptor<Visit>()) == 1)
    #expect(try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon).id == intake.id)
}
@Test func onlyUnfinishedVisitsTodayAreReused() throws {
    let c = try context(); let db = dbPatient(); c.insert(db)
    let p = Patient(fullName: "Aurora Adams", medicareID: "58416859273", dateOfBirth: "1943-08-10"); c.insert(p)
    let yesterday = Visit(arrivedAt: noon.addingTimeInterval(-86_400), answers: []); let doneToday = Visit(arrivedAt: noon.addingTimeInterval(-600), answers: [])
    doneToday.finish(); for v in [yesterday, doneToday] { c.insert(v); p.visits.append(v) }; try c.save()
    let v = try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon)
    #expect(v.id != yesterday.id && v.id != doneToday.id && v.databasePatientID == "P10338")
}
@Test func blocksMissingMedicareOrBadDOB() throws {
    #expect(dbPatient().consultBlockReason == nil)
    #expect(dbPatient(medicare: " / ").consultBlockReason == "No Medicare number on this record.")
    #expect(dbPatient(dob: "10/08/1943").consultBlockReason == "Date of birth isn't a valid date (yyyy-MM-dd).")
    let c = try context(); let db = dbPatient(medicare: ""); c.insert(db)
    #expect(throws: RecordError.invalidIdentity) { try RecordMutations.startManualConsult(context: c, databasePatient: db, now: noon) }
    #expect(try c.fetchCount(FetchDescriptor<Visit>()) == 0 && c.fetchCount(FetchDescriptor<Patient>()) == 0)
}
@Test func intakeVisitPersistsWithNilDatabaseID() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("records.store")
    let (store, q) = try await fixture(url: url); let r = try await store.recordSubmission(submission(q))
    let reopened = ModelContext(try GPInTheBoxSchema.makeContainer(url: url))
    let id = r.visitID
    #expect(try reopened.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })).first?.databasePatientID == nil)
}
```

`fixture(url:)` and `submission(_:)` already exist in `RecordStoreTests.swift`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/GPInTheBoxKit --filter ManualConsult`
Expected: FAIL to compile (`startManualConsult`, `databasePatientID` and `consultBlockReason` don't exist yet).

- [ ] **Step 3: Implement it.** Add the property to `Visit` (it's not set in `init`). Add `consultBlockReason` and `startManualConsult` per the Global Constraints. Use the same `#Predicate` matching as `recordSubmission`. For today's visits, filter `patient.visits` by `calendar.isDate(_:inSameDayAs: now)` and `status != .done`. If several qualify, take the latest by `arrivedAt`.

- [ ] **Step 4: Run the full package suite**

Run: `swift test --package-path Packages/GPInTheBoxKit`
Expected: all pass (124 existing + 7 new), with no warnings.

- [ ] **Step 5: Commit**

```bash
git add Packages/GPInTheBoxKit
git commit -m "feat: start a manual consult for a database patient"
```

---

### Task 2: App — Consult button and the GP-added brief

**Files:**
- Modify: `GPinTheBox/PatientDatabaseView.swift` (`PatientDatabaseView`, `DatabasePatientDetail`)
- Modify: `GPinTheBox/GPInTheBoxApp.swift` (`intakeSection`, around lines 351–370)

**Interfaces:**
- Consumes: Task 1 `RecordMutations.startManualConsult`, `DatabasePatient.consultBlockReason`, `Visit.databasePatientID`.

- [ ] **Step 1: Add the Consult button.** It's a prominent `Button("Consult")` (`.borderedProminent`, `.tint(Color.careAccent)`) at the top of `DatabasePatientDetail`, next to the patient's name.
  - **Disabled:** when `consultBlockReason != nil`, with the reason in `Color.careSecondary` beneath the button.
  - **Action:** call `try RecordMutations.startManualConsult(context: modelContext, databasePatient: patient)` with the view's `@Environment(\.modelContext)`, which is the app's main context. Then set `model.selectedVisitID = visit.id` and dismiss the database sheet.
  - **Wiring:** pass an `onConsult: (Visit) -> Void` closure from `PatientDatabaseView` (which owns `dismiss` and `model`) into `DatabasePatientDetail`.
  - **Errors:** show the error's `localizedDescription` in the existing `message` area.

- [ ] **Step 2: Add the GP-added branch to the Patient brief.** In `intakeSection`, when `visit.databasePatientID` is set:
  - **Header:** instead of "Patient-reported · Read their answers…", show `No intake — added by the GP from the patient database (\(id))`.
  - **Profile box:** a `GroupBox` with the four labelled fields (`Allergies`, `Current medications`, `Medical conditions`, `Notes`) read live from the `DatabasePatient` with that `patient_id`. Use a small subview with an `@Query(filter: #Predicate { $0.patient_id == id })`. An empty field shows `Not recorded`. With no record, the box shows `Database record no longer available`.
  - **Unchanged:** keep "Continue to recording", and don't change intake visits at all.

- [ ] **Step 3: Build the Mac app**

Run: `xcodebuild -project GPinTheBox/GPInTheBox.xcodeproj -scheme GPInTheBox -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build`
Expected: `** BUILD SUCCEEDED **` with no new warnings.

- [ ] **Step 4: Manual check (report what you saw; don't touch the user's data store).** Running the app uses the user's real store. Unless the user has asked for a manual run, skip launching the app and say so in the report. The logic is covered by Task 1. Otherwise check:
  - Open the Patient database and select a patient; **Consult** is enabled.
  - Tap it: the sheet closes, the queue shows the patient as **In consult**, and the brief shows the banner and profile.
  - Tap Consult again for the same patient: the same visit opens.

- [ ] **Step 5: Commit**

```bash
git add GPinTheBox/PatientDatabaseView.swift GPinTheBox/GPInTheBoxApp.swift
git commit -m "feat: Consult button adds a database patient to today's queue"
```
