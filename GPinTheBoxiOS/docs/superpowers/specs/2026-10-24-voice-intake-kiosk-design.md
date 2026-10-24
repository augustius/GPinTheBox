# SteadyCare Voice Intake Kiosk (iOS) — Design

Date: 2026-10-24
Status: Draft for review
Source: `idea.md`, grilling session 2026-10-24

## Summary

A clinic-owned iPhone/iPad kiosk in the waiting room that runs patient intake by voice. It asks each intake question aloud, transcribes the patient's spoken answer on device with `SpeechAnalyzer`, tidies the answer with Apple Foundation Models, shows the patient everything for review, then sends a JSON array of `{ "q", "a" }` pairs to the SteadyCare Mac app over Bonjour. The Mac creates a **new patient record** for every payload it receives.

This uses the same demo rules as the Mac app: synthetic data only, local network only, no authentication. It is not a clinical system.

## Decisions

| # | Decision | Source |
|---|----------|--------|
| D1 | The device is a clinic-owned kiosk, shared by consecutive patients. | User (Q1) |
| D2 | The payload is a JSON array of `{ "q": "", "a": "" }`, sent to the Mac over Bonjour. | User (Q2) |
| D3 | Every payload the Mac receives creates a **new patient record**. There is no matching against existing patients. | User (Q2, restated) |
| D4 | The questions are hardcoded in the iOS app. The Mac's versioned questionnaire is not used. | User (Q3) |
| D5 | The conversation is guided, one question at a time. The model may also pre-fill later answers from what the patient already said. | User (Q4 c) |
| D6 | Each question is spoken aloud and shown on screen, with live captions of the patient's speech. | User (Q5) |
| D7 | There is a mandatory review screen. Nothing is sent without an explicit "Send to clinic". | User (Q6) |
| D8 | en-AU only for v1. | **Assumed** (Q7 recommendation) |
| D9 | Synthetic data only. The kiosk deletes everything after the Mac confirms receipt, and resets after 2 minutes idle. | **Assumed** (Q8) |
| D10 | If the model is unavailable or refuses, the raw transcript is used as the answer, editable on the review screen. | **Assumed** (Q9) |
| D11 | The Mac sends an ack after it saves the record, and payloads carry a `submissionID` so retries are idempotent. | **Assumed** (Q13) |
| D12 | The kiosk connects automatically to a single Mac and shows a staff picker if it finds several. | **Assumed** (Q14) |
| D13 | Pre-filled answers are read back for confirmation, never skipped silently. | **Assumed** (Q15) |

The **Assumed** rows were recommended answers that weren't explicitly confirmed. Revisit them during review.

## Questions (hardcoded, in order)

1. Full name
2. Medicare or insurance ID
3. Date of birth
4. What is the main reason for your visit today?
5. When did it start?
6. Describe your symptoms
7. Are you currently taking any medications? Please list them
8. Do you have any allergies?
9. Do you have any ongoing medical conditions?
10. Is there anything else you'd like the doctor to know?

These strings are the `q` values in the payload, byte for byte. Questions 1–3 are required. 4–10 may be answered "none" or skipped by the patient, and are sent with an empty `a`.

## iOS app

### Platform
- iOS/iPadOS 26+, on an Apple Intelligence–capable device.
- Frameworks: `Speech` (`SpeechAnalyzer` + `SpeechTranscriber`), `FoundationModels`, `AVFoundation` (`AVSpeechSynthesizer`, audio session), `Network` (`NWBrowser`, `NWConnection`), SwiftUI.
- Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices = ["_steadycare._tcp"]`.

### Session flow
1. **Welcome:** "Tap to start." The app checks that a Mac is connected (D12). If none is found, it shows "Clinic not found — ask reception" and doesn't start.
2. **For each question:**
   - The question is spoken (en-AU voice) and shown on screen.
   - The mic opens once speech playback ends, so the app doesn't transcribe itself. Live captions come from volatile results. The answer ends after about 1.5 s of silence or a "Done" tap. "Repeat question" and "Skip" (questions 4–10 only) buttons are available.
   - The final transcript goes to the model for that question (see Model use).
   - If an answer was pre-filled, the app reads it back instead: "You mentioned *X*. Is that right, or would you like to add anything?" The patient confirms, adds to it, or replaces it (D13).
3. **Review:** all 10 q/a pairs on one screen. Tapping a field lets the patient re-speak or type it. DOB is shown in a readable format but stored as `yyyy-MM-dd`. "Send to clinic" is disabled until questions 1–3 are non-empty and DOB parses to a valid past date.
4. **Sending:** the app sends the payload and waits for the ack (D11). It retries with backoff using the same `submissionID`. After 30 s it shows "Couldn't reach the clinic — ask reception", keeps the data, and offers retry.
5. **Done:** "Thanks, please take a seat." After about 5 s the kiosk resets, deleting the transcript, answers and session.

At any point, 2 minutes idle shows "Are you still there?". With no response 20 s later, the kiosk resets and deletes the session (D9).

### Model use (on device, Foundation Models)
- **Per-answer normalisation:** a guided-generation `@Generable` struct per question type returns a cleaned `a`. Fillers are removed and the patient's words kept. Nothing is invented and no diagnosis is given. DOB → `yyyy-MM-dd`, and the ID is spelled out without spaces.
- **Pre-fill (D5):** after each answer, one extra call takes the cumulative transcript and the remaining questions. It returns candidate answers only for questions that are explicitly addressed, with an empty value otherwise. Candidates are tentative until the patient confirms them.
- **Fallback (D10):** if `SystemLanguageModel.default` is unavailable, the model refuses or errors, or generation exceeds a timeout of about 5 s, the raw transcript becomes `a`. Pre-fill is disabled in that case. DOB still needs a valid date before sending, so the patient types it if parsing fails.
- Instructions tell the model to transcribe and tidy only, never to advise. Instructions aren't guarantees, which is why the review screen (D7) is required.

### Speech
- `SpeechTranscriber` with locale `en_AU` (D8). At launch the app checks `SpeechTranscriber.supportedLocales` and installs assets through `AssetInventory`. Asset download is a staff setup step on first launch, not something the patient sees.
- If speech is unavailable (permission denied, no assets), the app falls back to typing every answer.

### Mac discovery (D12)
- `NWBrowser` for `_steadycare._tcp`.
- One result: connect automatically.
- More than one: show a staff-only picker behind a long-press on the welcome screen, and remember the service name in `UserDefaults`.
- No result: welcome screen in a blocked state.

## Wire protocol

Transport: TCP over a Bonjour-advertised service `_steadycare._tcp`. Each message is a 4-byte big-endian length prefix followed by UTF-8 JSON, with one request and one response per patient.

**Request** (kiosk → Mac):
```json
{
  "submissionID": "6F1C…UUID",
  "answers": [
    { "q": "Full name", "a": "Jane Demo" },
    { "q": "Medicare or insurance ID", "a": "DEMO001" },
    { "q": "Date of birth", "a": "1980-05-01" },
    { "q": "What is the main reason for your visit today?", "a": "Cough" }
  ]
}
```
`answers` is exactly the user-specified `[{q, a}]` array. The wrapper only carries `submissionID` for idempotency (D11).

**Response** (Mac → kiosk):
```json
{ "status": "ok" }
{ "status": "error", "message": "…" }
```
The kiosk shows "Done" only after `ok`.

## Mac app changes (GPInTheBoxKit + app)

1. **Listener:** a new `KioskListener` (in the `Intake` module) using `NWListener` that advertises `_steadycare._tcp`. It runs alongside the existing HTTP `IntakeServer` and starts and stops with it in `GPInTheBoxApp`. The connection handler applies the length-prefix framing, has a 256 KB cap and a read timeout, and processes one request per connection.
2. **Store:** a new `RecordStore.recordKioskSubmission(submissionID:answers:)`:
   - Replay: if `submissionID` exists with an identical payload, it returns the previous receipt. A different payload throws `submissionConflict`.
   - Identity: it finds the entries whose `q` exactly matches "Full name", "Medicare or insurance ID" and "Date of birth", then applies the existing `IdentityValidation` (non-empty name and ID, valid `yyyy-MM-dd` DOB in the past). If that fails, the Mac returns an `error` ack.
   - **It always inserts a new `Patient`** (D3) and a `Visit` with `answers` mapped to `Answer(questionID:prompt:value:)`. `questionID` is derived deterministically from the question index, so replays compare equal. It doesn't touch the versioned questionnaire (D4).
   - It records a `StoredSubmission` and calls the same `onSubmission` hook, so the queue and notifications behave like web intake.
3. **Display:** kiosk visits render their stored `Answer.prompt`/`value` pairs as they arrive. This already works because `Visit.answers` carries the prompts.

## Known consequences and risks

- **Duplicate patients (consequence of D3):** a returning kiosk patient gets a second `Patient` with the same Medicare ID and DOB. **Patient history recovered** won't appear for kiosk visits. Later web submissions match whichever duplicate the fetch returns first, and **Correct identity** may reject edits as `identityCollision`. Staff need to know this, and we should reconsider before anything beyond the demo.
- **Identity found by question text:** if the iOS question strings change, the Mac must change in lockstep. One shared constant (or a small shared Swift package) is recommended.
- **en-AU support:** `SpeechTranscriber` en-AU availability on the target OS needs checking on the actual device. If it's missing, use en-US temporarily and flag it in the UI.
- **No transport security:** plain TCP and no pairing. Any device on the Wi-Fi can submit, the same as the existing HTTP form.
- **Shared kiosk privacy:** answers are visible on screen until reset, so the idle timeout and post-send wipe are the only protection.

## Testing

- **iOS unit:** question flow state machine (next, skip, repeat, pre-fill confirm, idle reset), DOB/ID normalisation, payload encoding, framing encoder/decoder, retry/ack handling with a fake transport. Model and speech go behind protocols with fakes.
- **Mac package tests** (`swift test --package-path Packages/GPInTheBoxKit`): `recordKioskSubmission` always creates a new patient (even with an identical ID and DOB), replay idempotency, conflict on a different payload, identity validation errors. A `KioskListener` loopback test sends a framed request and checks the ack.
- **Manual:** kiosk + Mac on the same Wi-Fi with the synthetic Jane Demo script. Check the Local Network permission prompts on both sides, the multiple-Mac picker, and Wi-Fi drop during send.

## Out of scope (v1)

Languages other than en-AU, patients' own phones, reading the Mac's questionnaire, patient matching for kiosk intakes, encryption/pairing, accessibility beyond captions plus typing fallback (to revisit), and persistent kiosk history.
