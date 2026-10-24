# GPInTheBox — Demo v1 Design

macOS application that lets a GP pull patient records, summarise them and ask questions about them using on-device AI. The same app acts as a local clinic server: patients fill in an intake form in a browser on the clinic LAN and the form is POSTed to GPInTheBox.

## Platform

- macOS 26+, Apple Silicon, Apple Intelligence enabled (required by Foundation Models)
- One Mac per GP (demo: single GP, single Mac)
- SwiftUI app, SwiftData storage
- Embedded HTTP server (Hummingbird) running inside the app process

## Patient intake

- Patient opens a plain HTTP URL on the LAN (e.g. `http://<mac-ip>:8080`) on a clinic iPad or their own phone
- No QR code, no check-in token
- Server-rendered HTML form, no JS framework
- Fixed questionnaire, editable in the Mac app
- Every patient fills the full form every time (typing only, no voice)
- Form includes Medicare / insurance ID and date of birth
- Form is submitted via POST to GPInTheBox
- On submission the server matches Medicare ID + DOB:
  - match → attach as a new visit to the existing patient
  - no match → create a new patient

## GP workflow

- **Today's queue** sidebar, sorted by arrival, with status: Waiting → In consult → Done
- Quiet macOS notification on each new submission
- Opening a patient shows:
  - today's raw intake answers
  - past visits and GP notes
  - optional **Summarise** button
  - optional **Q&A** box (works without a summary)
- Nothing is generated in the background; the GP decides whether to summarise
- During consultation the GP adds **free-text remarks** (e.g. prescriptions, what to look for next session)

## AI (Apple Foundation Models only, fully local)

- Summarises and answers questions **only from what is in the record** — never diagnoses
- Every claim cites its source text, labelled **Patient-reported** or **GP-entered**, with date
- **Summary**
  - Opens with follow-up items extracted from the previous visit's free-text note (guided generation via `@Generable`), each linked to the sentence it came from
  - Each follow-up item is matched against today's intake, with a citation or flagged "not mentioned"
  - Records exceeding the context window are summarised with local map-reduce (summarise chunks, then summarise the summaries)
- **Q&A**
  - Retrieval-based: record split into chunks with IDs, retrieved via keyword search + on-device `NLContextualEmbedding`
  - Answers cite chunk IDs that link back to the original text
  - Chat is ephemeral; anything worth keeping, the GP copies into their note
- **Errors** (guardrail violation, unsupported language, model unavailable): show a clear message and the raw record. Model availability is checked at app launch.
- No cloud fallback

## Known demo limitations (out of scope for v1)

- Plain HTTP, no HTTPS
- No access control on the intake form (anyone on the Wi-Fi can submit)
- No encryption at rest, no user login, no audit log
- Single Mac; no record sync across multiple GPs' Macs
- No EHR / practice-management integration (GPInTheBox is the system of record)
- No voice input
- No jurisdiction-specific retention or consent rules
