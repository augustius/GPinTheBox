# SteadyCare Kiosk: Casual Chat Intake — Design

Date: 2026-10-25
Status: Draft for review
Builds on: `2026-10-24-voice-intake-kiosk-design.md` (v1, implemented on `main` + `chore/fold-kiosk-protocol`)

## Why

The v1 kiosk reads the ten intake questions one by one, like a form read aloud. The user wants it to feel like chatting with ChatGPT: a casual conversation in a dark, ChatGPT-style screen, where whatever the patient says is picked apart into the intake answers, and the kiosk keeps chatting until the gaps are filled.

## Goals

- The screen looks and feels like the ChatGPT reference: dark, kiosk text unboxed, patient replies in bubbles, a rounded pill composer.
- The kiosk talks casually. Every patient reply is digested and mapped to any of the ten questions it answers, not just the one being asked.
- Unanswered questions are nudged with casual follow-ups until the required three are filled and every optional one has had a fair ask.
- The patient can see and fix what was picked up, right in the chat.
- Voice conversation by default; the patient can switch to quiet text.

## Non-goals

- No change to the Mac app, the wire format, or the ten question strings sent as `q` (byte for byte as today).
- No generated chat replies from the model (see Approaches — user chose hand-written lines).
- No new languages; en-AU only, as v1.
- No light theme.

## Anti-goals (would be a failure even if it works)

- The kiosk gives health advice, reassurance about symptoms, or anything that sounds like a diagnosis.
- An answer the patient never gave lands in the record (invented by the model).
- The conversation never gets around to asking for name, Medicare/insurance ID or date of birth, asks for any personal detail beyond the ten questions, or loops forever on any question.
- The patient waits on a spinner after every reply.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| A | One model call per reply: extract answers **and** write the next casual message; the model picks what to ask next. | Fastest and most natural, but the model may never ask for DOB/ID, and can ask for something just answered. |
| B | Two calls per reply: extract, then code picks the next gap and the model phrases it; pre-written lines as fallback. | Natural and guarantees required fields, but ~2–4 s per turn. |
| **C (chosen)** | **Model extracts answers; code picks the next gap; hand-written casual lines (several variants per question) do the asking.** | Instant follow-ups, fully predictable, can't drift into advice. Less adaptive; may feel repetitive across many patients. |

The user chose **C**.

## What the user decided

1. **Casual conversation**, ChatGPT-style dark screen (reference screenshot: unboxed assistant text with small action icons, rounded pill composer, mic, blue voice button, disclaimer line).
2. **Every reply is mapped** to any of the ten questions; unanswered ones are nudged casually.
3. **Re-check by tappable chips (option B of the mockup):** what was picked up appears as chips under the patient's message (e.g. `Name: Jane Demo ✎`); tapping a chip opens an editor. The kiosk keeps chatting without waiting for confirmation.
4. **Voice by default:** the kiosk talks out loud and listens hands-free. The patient can switch to staying quiet as a text chat.
5. Approach **C**.
6. **Required details get 3 tries.** If one is still missing after the third ask, the kiosk says "Sorry, we can't proceed without your …", sends the patient to reception, and sends nothing.

## Design

### Conversation engine (KioskKit)

**Turn.** The kiosk posts a casual line aimed at one *target* question → the patient replies (spoken or typed) → the reply is digested → chips appear under the reply → the next line is posted immediately.

**Target choice (code, not model).** The next target is:
1. the first unanswered **required** question (Full name, Medicare or insurance ID, Date of birth), in that order; else
2. the first unanswered **optional** question (4–10, in order) that has been asked fewer than **2** times; else
3. none → the conversation ends and the review screen opens.

An optional question asked twice without an answer is treated as skipped (`a = ""`).

**Required questions are asked at most 3 times** (user decision). If one is still unanswered after its third ask, the kiosk says "Sorry, we can't proceed without your {date of birth / Medicare or insurance ID / name}. Please see reception — they can help." and shows a dark **"Please see reception"** screen. Nothing is sent. The session is wiped as on reset, after about 10 s or a tap on **Start over**.

**What counts as an ask** (builder's question, my call): posting a line that targets the question (first ask, nudge, or ↻ rephrase) increments its ask count; 🔊 replay does not. A question answered incidentally by an earlier reply is never asked.

**Digesting a reply.**
- One on-device model call maps the reply onto **all currently unanswered questions, including the target**. This reuses and generalises today's pre-fill extractor and its validation: per-kind rules (DOB must parse to a valid past date via `AnswerFormatting.isoDOB`, ID normalised, blanks dropped), and drop anything that echoes a question or ends with "?". Already-answered questions are not overwritten by extraction (the patient changes those by tapping a chip).
- **Extracted values are tidied by the same call** (my call): the extraction prompt asks for each value in the patient's own words with fillers removed, so there is one model call per reply, not one per field.
- **Target fallback** (narrowed, my call): only when the extractor returned **nothing at all** for the reply and the reply isn't a skip, the whole reply is tidied (existing `AnswerTidier.tidy`) and becomes the target's answer — except DOB (must parse) and ID (must normalise to non-empty), which stay unanswered and get re-asked. If the extractor filled other questions but not the target, nothing is dumped into the target; it is simply asked again next (that counts as an ask).
- **Skips and "none".** For an optional target, a whole reply like "none", "no", "nothing", "I'd rather not say", "skip", "pass" (case-insensitive, trimmed punctuation) records the target as answered-empty. Mixed replies ("none, but I'm on aspirin") go through the extractor as usual. Required targets ignore skip words and are re-asked.
- **Answered-empty** is sent as `a = ""` (v1 rule, wire format unchanged); its chip and review row read "none".
- **No auto-overwrite** (my call): extraction never changes an already-answered question, including corrections like "actually it's spelt Jon". The patient taps the chip (or edits on review). The edit sheet applies the same rules as review editing: DOB is normalised via `isoDOB`, and clearing a required answer makes it unanswered again, so it is targeted next with its ask count reset to 0.
- **Model unavailable / timeout (5 s, existing `AnswerTidier` timeout).** No extraction; the target fallback alone applies — this is effectively the v1 one-question-at-a-time flow, but with casual lines.
- **Name in lines.** Once Full name is answered, lines may address the patient by first name (first whitespace-separated token).

**Casual line bank (hand-written, in KioskKit).**
- An opening line (asks the first target), e.g. "Hey! 👋 Thanks for coming in. What should I call you?" Emoji in text only; speech skips it.
- For each of the ten questions: **3 casual variants** for a first ask and **2** for a re-ask/nudge ("No worries — just need your date of birth to find your file. What is it?").
- A short acknowledgement prefix pool used before the next line when something was picked up ("Got it.", "Thanks, {name}.", "Perfect.").
- Rotation: pick the variant not used most recently for that question in this session; deterministic given a session seed so tests can pin it.
- **Copy rules:** friendly, short, Australian English, no medical content beyond restating the question topic, no reassurance or advice, never mentions what another question's answer was except the patient's first name.
- The exact copy is the builder's to write within these rules; it must be reviewed by the user before release.

**Chips.** Each patient chat message carries the `{questionIndex: value}` pairs picked up from it. A chip shows a short label (e.g. "Name", "ID", "Born", "Reason", "Started", "Symptoms", "Medications", "Allergies", "Conditions", "Other") and the value (DOB shown as "1 May 1980"). Skips recorded from the reply show as "Allergies: none". Tapping a chip opens an edit sheet bound to that question (`edit(i, to:)`); editing changes the stored answer only, not the chat text, and the chip updates to the new value.

**Removed from v1.** The `confirmingCandidate` phase, read-back line ("You mentioned X…"), and the confirm / add more / replace actions. Pre-fill candidates are applied directly as answers (they are now the chips).

### Voice

- **Voice conversation on by default** for every new patient: each kiosk line is spoken (en-AU voice), then the mic opens and silence (1.5 s) or tapping the live caption's **Done** ends the reply — as v1.
- **Blue voice button** in the composer shows voice state and toggles it. Tapping it turns **quiet mode** on: no speech, no auto-listening; the patient types. Tapping again turns voice back on (speaks the current line, then listens). Quiet mode resets to voice for the next patient.
- **🎙 mic button** in the composer: one-shot dictation into the text field (listen once, put the transcript in the field for the patient to review and send). Available in both modes. In voice mode, tapping it first stops any auto-listen; after the dictated reply is sent, the next line is spoken and auto-listening resumes (my call).
- Type-and-talk from v1 stays: first keystroke stops listening; Return / send arrow submits.
- Turning voice back on with a draft in the field keeps the draft, speaks the current line, and doesn't auto-listen until the draft is sent or cleared (my call).
- If speech is unavailable (no permission/assets/listen error), the kiosk behaves as quiet mode and hides the voice and mic buttons. The send arrow still appears when the field has text.

### Screen (GPInTheBoxKiosk)

- **Always dark** (reference look), regardless of system appearance.
- **Kiosk messages:** plain text, left, no bubble. Under the latest kiosk message only: 🔊 (speak it again, works in quiet mode too) and ↻ (ask the same target with another variant).
- **Patient messages:** grey rounded bubbles on the right (≈ `#2f2f2f`), chips beneath, right-aligned.
- **Live caption:** while listening, an in-progress patient bubble with the caption and a small **Done**.
- **Disclaimer** above the composer: "Answers are checked by clinic staff. Synthetic data only."
- **Composer pill** (≈ `#1f1f1f`, fully rounded): text field "Type your answer", 🎙 mic, and the blue voice button (≈ `#3d6fd8`) on the right; while the field has text, the blue button becomes a send arrow (ChatGPT behaviour). No "+" or "Think".
- **No Repeat / Skip / Done row**: repeat is 🔊/↻, skip is said in the chat, Done lives on the live caption.
- Header: small, unobtrusive progress, defined as answered (including answered-empty) out of 10, e.g. "3 of 10" (my call). The builder may restyle it.
- **Welcome, review, sending, done, staff setup, the idle alert and the new "Please see reception" screen** are restyled to the same dark look. Review stays mandatory before **Send to clinic**, with the same rules (questions 1–3 non-empty, DOB a valid past date). There's no going back from review to the chat; edits happen on review, as in v1 (my call).

### Code shape (my calls)

- `IntakeFlow` is extended rather than replaced:
  - drop the `confirmingCandidate` phase and its read-back, confirm, add and replace APIs;
  - add per-question ask counts and an answered-empty marker;
  - add the target-choice rule and the "can't proceed" outcome;
  - `.asking(i)` now means "the current target is i".
- `AnswerTidier.prefill` becomes the reply extractor, with the same validation, over all unanswered questions including the target. `tidy` is kept for the target fallback.
- `KioskController` keeps its session and generation guard, chat log, type-and-talk, idle and reset behaviour. Each patient `ChatMessage` gains its picked-up `[Int: String]` for chips.
- Tests for removed v1 behaviour are rewritten to the new behaviour; all other v1 tests stay.
- Dynamic Type respected; works on iPhone and iPad.

### What stays the same

Payload `[{q, a}]` with the ten exact strings; Mac discovery, sending, retries, idle timeout (2 min + 20 s), wipe on reset/done, review rules, en-AU locale, typing fallback, staff setup behind long-press.

## Spec changes to v1 (supersede)

| v1 decision | Now |
|---|---|
| D5 guided one question at a time; model may pre-fill | Casual chat; model maps each reply to any unanswered question; code picks the next target |
| D6 each question spoken aloud and shown | Each casual line spoken (voice mode) and shown; quiet mode available |
| D13 pre-filled answers read back for confirmation | Picked-up answers shown as editable chips; no read-back; review screen remains the check |
| Copy: `Repeat question`, `Skip`, `Done`, read-back line | Removed (Done remains only on the live caption) |

## Testing

- **KioskKit unit tests (fakes, as v1):** target order (required first, optional at most twice then skipped); a required question unanswered after 3 asks leads to "can't proceed" (nothing sent, then wiped); multi-answer reply fills several questions and doesn't overwrite answered ones; target fallback incl. DOB/ID exceptions; skip words (optional vs required); variant rotation and re-ask variants; name substitution; chips attached to the right message; chip edit updates answer; model unavailable/timeout path; quiet-mode toggle (no speak/listen), mic dictation fills field; reset wipes chips, variant history and quiet mode; generation guard still drops late results.
- **Line bank test:** every question has ≥3 first-ask and ≥2 re-ask variants; no line contains advice words from a small deny-list ("should", "recommend", "don't worry", "it's probably", "normal").
- **Simulator walkthrough** (typing/quiet mode) with screenshots; on-device voice check added to the README checklist.

## Left to the builder

- Exact casual copy (within the copy rules; user reviews before release).
- Chip labels' exact wording and the progress indicator style.
- How extraction's prompt is phrased (reusing the existing `FoundationModelsAnswerModel` prefill prompt as a base).
- Animation and spacing details of the dark UI.
