# SteadyCare

Previously GPInTheBox. The app’s display name is SteadyCare; existing project identifiers and local storage locations are retained for compatibility.

A native macOS synthetic-data demo for patient intake over the local network, a GP visit queue, local records, and cited on-device assistance.

## Requirements

- Apple Silicon Mac, macOS 26 or later.
- Xcode 27.1 / Swift 6.4 (validated toolchain).
- Apple Intelligence enabled and its model downloaded for summaries and Q&A. Intake and raw records remain usable without it.
- An initial internet connection for Swift package dependencies and, if unavailable locally, NaturalLanguage embedding assets. Patient records are never sent to an AI service. Embedding failure falls back to keyword retrieval.

## Build and run

Open `GPInTheBox/GPInTheBox.xcodeproj`, select the **GPInTheBox** scheme and **My Mac**, then Run. Alternatively:

```sh
xcodebuild -project GPInTheBox/GPInTheBox.xcodeproj \
  -scheme GPInTheBox -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build
open DerivedData/Build/Products/Debug/GPInTheBox.app
```

This is a local ad-hoc signed build, not a notarized distribution. For distribution or signing on another Mac, select your development team in Xcode.

The toolbar shows `http://<Mac LAN address>:8080`. Open it on a phone or tablet on the same Wi-Fi. Local Network permission and network/firewall policy must allow the connection. Notification permission is optional and must not block intake startup. Port conflicts appear in the toolbar. Closing the application stops the intake server.

## Demo walkthrough

1. Submit **Jane Demo — Synthetic Patient**, ID `DEMO-001`, DOB `1980-05-01`, with fictional cough symptoms.
2. Open Jane in the queue. The visit changes from **Waiting** to **In consult**. Review the raw intake and enter a fictional GP note, such as “Ask about cough next visit. Recheck blood pressure next visit.”
3. Choose **Finish visit**. Submit a fresh form using `demo 001` and the same DOB. It matches Jane and creates a separate visit.
4. Open the return visit. The workspace searches the local patient database and shows **Patient history recovered**, the previous visit count, and **Review history**. First visits show **No previous history found**; failed lookups offer a retry. Review past notes, choose **Summarise**, and ask a record question. Each generated claim shows its original source and date. Follow-ups use **Mentioned in today’s intake**, which does not mean completed.
5. Change patients or edit a note to clear previous assistant output. Use **Correct identity** for corrections; collisions are rejected rather than merged.
6. Open Settings to edit/reorder questions and publish a new questionnaire version. Previously opened forms remain valid against their original version.

No demo data is automatically inserted. The local store persists across app launches in the app's sandbox. Q&A and generated summaries are not persisted. Copies deliberately entered into a GP note are persisted.

## Consultation recording, transcription, and reviewed summaries

The GP workspace opens each visit on **Intake**, followed by separate **Recording**, **GP Notes**, **History**, and **Assistant** sections. The patient browser remains intake-only. Switching sections within the same visit preserves drafts and keeps recording active; the header shows recording status and a link back to its controls. Switching patients or leaving the visit stops recording.

During an active visit, the **Recording** section lets the doctor confirm patient agreement, choose **English (Australia)** or **English (US)**, and explicitly start microphone recording. Recording never starts automatically. macOS requests microphone access on the first start.

Choose **Stop & transcribe** to run Apple's on-device `SpeechTranscriber` and then create an Apple Foundation Models draft. Language assets may need a one-time download; the conversation itself is not uploaded and there is no cloud fallback. The transcript is a combined conversation, not speaker diarization: it does not automatically distinguish the doctor from the patient.

The app commits a non-empty transcript to SwiftData before deleting the audio. Failed or cancelled transcription retains the audio with the original patient/visit for retry or explicit discard. Switching visits or quitting stops recording; interrupted recordings are labelled as potentially partial. If the app exits after saving a transcript but before audio cleanup, opening that consultation retries cleanup.

Review and correct the saved transcript, edit the draft summary, confirm review, then choose **Approve & save to patient record**. A model refusal does not prevent manual summary entry. Transcript corrections invalidate the previous draft/approval. Only approved summaries enter future visit summaries, Q&A, and follow-up checks; raw transcripts and unapproved drafts stay out of those record searches. Transcript and approved summary remain accessible in **Past visits**. No new diagnosis or treatment advice is generated by design; review all outputs.

The draft is not silently added to the GP note. Recording does not require Apple Intelligence, but AI summary generation does. The patient intake browser still only submits the intake form; the Mac records the consultation after the patient sits down with the doctor.

## Verification

```sh
swift test --package-path Packages/GPInTheBoxKit
swift run --package-path Packages/GPInTheBoxKit ModelProbe
```

Package tests use temporary or in-memory stores and fake models. `ModelProbe` explicitly runs synthetic examples against the real on-device model; it reports skipped checks when unavailable and exits unsuccessfully if a real-model check fails. It does not write patient records.

See `GPinTheBox/docs/implementation-status.md` for verified behavior and remaining manual checks.

## Boundaries

This demo is for synthetic records only. It uses plain HTTP, has no intake authentication, and intentionally omits production access control, audit logging, backup/recovery, multi-Mac sync, and EHR integration. Do not use it as a clinical system of record.

The assistant rejects absent/unknown citations and quotes that are not present in the exact supplied excerpts. These structural checks do not prove that a claim logically follows from its source. Review displayed evidence. Generated responses can be incomplete or wrong; the raw record remains available. The model is instructed not to diagnose or recommend treatment, but instructions are not a guarantee of model behavior.

The original implementation plan is in `GPinTheBox/docs/superpowers/plans/2026-10-24-gpinthebox-demo-v1.md`; the implementation retains the approved reliability fixes on top of that plan.

Recording attempts can be removed from the active view with **Delete (archive)** after stopping recording/processing. This preserves saved transcripts, summaries, and any audio awaiting transcription. Archived summaries are excluded from future AI context. Use **Show archived recordings → Restore recording** to recover an attempt, or **Start recording** (with patient agreement) to create a separate attempt. Audio already deleted after successful transcription cannot be restored.

### Glossary and local speaker separation

Open **Recording → Speech glossary & setup…** to save up to 100 short local vocabulary hints. A non-empty glossary selects Apple's on-device `DictationTranscriber`; an empty glossary uses `SpeechTranscriber`. Timed text is saved in either mode. Corrected conversation turns offer **Add term** to explicitly improve the glossary for future recordings. No automatic transcript substitutions are made.

Enable **Separate speakers locally (Core ML)** and open **Speech glossary & setup… → Download speaker model** once. The native Swift engine uses FluidAudio and a public Core ML Sortformer model; no Python environment, Hugging Face account, or access token is required. Downloads contain model files only. Processing uses the installed files locally, without uploading audio. This is a third-party speaker model; Apple handles transcription and summarisation.

The Python/Community-1 prototype remains in [the optional worker directory](scripts/local_diarization/README.md), but the app no longer launches it or needs its dependencies.
After processing, assign anonymous speakers to **Doctor / Patient / Other**, or use a turn's **Assign role** menu to correct an uncertain turn manually. Conversation text and role changes invalidate old summaries and approvals. History preserves the labelled conversation, while only approved summaries enter future AI context. Archived attempts stay excluded.

If separation fails, the saved transcript stays readable and audio remains available for **Retry speaker separation**. **Keep transcript only & delete audio** explicitly skips speaker analysis. Audio is automatically deleted only after the saved transcript and any requested speaker analysis finish successfully. Existing recordings whose audio was already deleted cannot be automatically re-analysed; record a new synthetic consultation to test the feature.

## CSV patient database

Open **Patient database** in the toolbar, choose **Import CSV files**, and select the patient CSV and consultation-note CSV together. All source columns are stored in `DatabasePatient` and `DatabaseConsultationNote`; `patient_id` links notes to patients. Repeat imports update matching `patient_id`/`note_id` records without duplicating them. Invalid headers, duplicate IDs, malformed CSV and orphan notes fail the batch without saving partial records. Importing notes alone is supported after their patients exist.

Search matches first name **or** last name (case-insensitive) **or** Medicare number (ignoring spaces, hyphens and slashes). Selecting a patient shows their profile and consultation history and converts their SwiftData record to JSON with `JSONSerialization`. **Selected patient JSON** exposes the exact snapshot. Source dates, identifiers, blank cells and other CSV values remain strings to preserve the supplied data faithfully; `age` is the source value, not recalculated.

**Ask on-device assistant** creates a fresh `LanguageModelSession` with `PatientDatabaseTool(json:)`. The immutable tool returns the selected patient's profile or a requested consultation note, newest first, avoiding dumping every note into the model context at once. Switching patients clears the previous response and cancels ongoing generation. AI answers need source review; citations are requested but are not programmatically verified in this database screen. Apple Intelligence must be available for answers; importing, searching and viewing records work independently.

Imported CSV records are available in this separate database screen. They are not automatically merged with the intake queue's existing `Patient`/`Visit` records. The CSV files and local SwiftData database are not bundled or committed to the repository.

To run the optional full-dataset round-trip test with local demo CSV files:

```sh
GP_DEMO_CSV_DIRECTORY=/path/to/csv-folder swift test --package-path Packages/GPInTheBoxKit
```

The native speaker adapter is pinned to FluidAudio 0.17.7 and the balanced v2.1 Core ML model. First setup validates the downloaded model with Core ML before marking it ready. It accepts local recordings up to 30 minutes / 512 MB, checks cancellation between inference chunks, and preserves audio if inference fails. See [speaker model attribution](ThirdPartyNotices/SpeakerModels.md).

Native speaker validation on the development Mac: the public model downloaded without authentication and passed Core ML loading in the sandboxed app. A 43.8-second synthetic two-voice consultation produced four stable alternating speaker intervals in about 5–6 seconds. The glossary test recognised metformin and penicillin; uncertain word assignments stayed unassigned. These checks are not a real microphone, overlap, or clinical-accuracy evaluation. The model cache is about 251 MB.

### Patient and GP pathways

The Mac app starts on a welcome screen with **Patient** and **GP workspace** cards. Patient opens the local browser intake form. GP workspace opens the native queue, with **Patient database** in its toolbar for record search/import and history. **Home** returns to the pathway chooser; stop an active recording first.

The shared clinic URL now opens a browser landing page:
- `/`: Patient / GP pathway chooser.
- `/intake`: patient details and questionnaire; submitting creates or matches the patient and adds their visit to the queue.
- `/gp`: handoff to `gpinthebox://workspace` on the clinic Mac. On a phone, it explains that the queue and records live in the Mac app.
- `/thanks`: submission confirmation.

This is workflow separation for the synthetic demo, not GP authentication. No queue or patient database API is exposed through the intake website.
