# Demo v1 implementation and validation

The original nine-task plan is implemented in the local Swift package and native SwiftUI app. Its task sequence is retained; reviewed reliability changes are documented below. No cloud model or fallback is used.

## Original task mapping

| Original tasks | Implementation |
| --- | --- |
| 1: Records | SwiftData patients/visits, matching, identity corrections, atomic receipts, immutable questionnaire versions |
| 2–3: Intake | Escaped mobile HTML, validation, Hummingbird routes, redirect-after-POST, LAN URL |
| 4–5: Assistant boundary and retrieval | Source chunks, structured claims, exact evidence validation, keyword/semantic retrieval |
| 6: Summarisation | Bounded reduction with source lineage, grounded follow-ups and incomplete-result notices |
| 7: Apple adapters | Foundation Models guided generation and token budgeting; NaturalLanguage embeddings with keyword fallback |
| 8: App shell | Native window, today’s queue, server startup/errors, quiet notifications |
| 9: Consultation UI | Raw records, saved notes/status, history, cited summary/Q&A, identity correction and questionnaire settings |

## Reliability changes

- Matching normalises IDs at the store boundary; DOB remains part of the key.
- Each form submission has an atomic receipt. Identical retries return it without creating another visit or notification; changed payloads conflict.
- Published questionnaires are immutable versions. Old open forms validate against their own version.
- AI claims require IDs and verbatim quotes from supplied excerpts. Evidence remains visible, with an explicit human-review notice.
- Follow-up mention is distinct from completion; incomplete searches never claim confidently that an item was not mentioned.
- Long inputs are budgeted, reduction must shrink, and retries/rounds are bounded.
- Generation is scoped to patient, visit, record revision, and request. Selection or record changes invalidate output.
- The native patient history is built from the live visit query, avoiding stale inverse relationships after returning-patient intake.

## Verification log

- Initial package regression suite: 30 tests passed (9 Records, 4 Intake, 17 Assistant).
- Initial native Xcode build: succeeded on Xcode 27.1 / Swift 6.4.
- Actual-device ModelProbe: cited summary, grounded follow-up, cited Q&A, and overflow handling passed.
- Browser/native workflow: synthetic first intake appeared in queue, opening changed status to In consult, GP note saved, native summary displayed cited evidence, finishing changed status to Done.
- Browser/native return visit with reformatted ID matched the patient and displayed previous history. Testing exposed stale snapshot construction; fixed before final validation.

## Final post-audit results — 24 October 2026

- **51 package tests passed:** 16 Records, 9 Intake, 26 Assistant.
- **Native app build succeeded** after integration using Xcode 27.1 / Swift 6.4, arm64, local ad-hoc signing.
- **Real on-device model checks passed:** current-visit cited summary, grounded follow-ups, cited Q&A, bounded context overflow, and full seven-question/two-visit Q&A citing V2-A7 for a negative blood-pressure statement.
- **Native workflow verified:** saved notes and statuses survive relaunch; returning-patient summary loads; cough and the negative BP statement appear as mentions with source links, not completed actions.
- **Questionnaire workflow verified:** adding and publishing an optional question made it appear on a fresh browser form. The standard questionnaire was restored by publishing another version.
- Native testing exposed an invalid-evidence Q&A response; it was correctly withheld. Exact-copy instructions were strengthened and the matching full-form real-model probe passed. Model outputs remain non-deterministic, and invalid evidence is still withheld.
- Native testing exposed an older-visit-biased summary. Summary requests now explicitly identify the selected visit, place its excerpts first, and withhold summaries without current-visit evidence. Regression tests and the real-model probe cover this behavior.

Validation logs on this development machine: `/tmp/gp-tests-final.log`, `/tmp/gp-xcodebuild-final.log`, `/tmp/gp-recency-model.log`.

## Remaining environmental checks

A physical iPhone connection on the same Wi-Fi, notification delivery when permission is granted, and the unavailable-model UI with Apple Intelligence switched off require device/user settings validation. Automated unavailable-model behavior is covered without changing system settings. No clinical accuracy claim is made by these tests.

## Consultation recording extension — 24 October 2026

Implemented with separate Records, Audio, and Assistant subagents and native UI integration:

- Explicit consent-confirmed Mac microphone start, visible recording state/timer, and Stop & transcribe.
- On-device Apple Speech transcription for English (Australia) and English (US), with no cloud fallback.
- Durable transcript-first save followed by audio deletion; retained recording recovery on failures/cancellation.
- Editable transcript and summary draft, explicit doctor approval, and transcript-revision checks against stale output.
- Approved summaries included in future visit retrieval/follow-ups with distinct GP-reviewed provenance; raw transcripts excluded from automatic record retrieval.
- Existing-store migration preserving prior patients/visits/notes tested.
- Interrupted recordings marked as potentially partial, including future approved-summary evidence.

Synthetic speech was transcribed successfully on this Mac in both English variants without using the microphone. A synthetic consultation passed actual Apple Foundation Models summarisation with strict evidence validation. Apple guardrails remain enabled; refusal leaves the transcript available for manual review/summary.

Actual microphone capture, microphone-denial UI, and a full spoken consultation remain manual checks. The implementation does not claim clinical transcription accuracy or automatic doctor/patient speaker identification.

Final consultation checks: **76 automated unit/regression tests passed** (26 Records, 9 Intake, 7 Audio, 34 Assistant). The gated real consultation model test also passed separately, for 77 verified tests across the runs. Native macOS build succeeded. Both synthetic on-device speech locale probes passed. The updated app opened against the existing demo database with both prior visits preserved, and its consent-gated recording controls plus both language choices were verified without starting the microphone.
