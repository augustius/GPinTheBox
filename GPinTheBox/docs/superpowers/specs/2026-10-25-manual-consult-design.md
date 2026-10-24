# Manual Consult from the Patient Database — Design (short)

Date: 2026-10-25 · Status: Draft for review · Size: small change

## Intent

A GP can start a consultation for a patient who has done no intake at all, such as a phone booking or someone who didn't use the kiosk or web form. They do this straight from the **Patient database** window, which lists the CSV-imported patients.

## Goals

- A **Consult** button on the selected database patient.
- Tapping it adds a visit for today to the queue and opens it.
- The Patient brief says plainly that there was no intake.

## Non-goals

- No change to the kiosk, the web intake, or patient matching for intake.
- No editing of database patients.
- No placeholder visits for an intake that's filled in later.

## Anti-goals

- Two open visits for the same patient today.
- A visit filed under the wrong patient.

## Behaviour

**Tapping Consult** (user decided: the patient is seen with no intake):
1. Find the intake `Patient` with the same normalised Medicare number (`MedicareID.normalise(medicare_number)`) and the same DOB, matching the way web intake does. If there isn't one, create one from the database row: `"first_name last_name"`, the Medicare number and `date_of_birth`.
2. If that patient already has a visit today that isn't **done**, open it and add nothing.
3. Otherwise insert a `Visit` arriving now, with status **In consult** and the answers below, and bump the patient's `revision`.
4. Close the database window, select the visit, and show the GP workspace.

**Visit answers** (user chose approach A). These are ordinary `Answer` values on the visit, with deterministic `questionID`s so the visit renders and re-renders consistently:
1. `No intake` → `Added by the GP from the patient database (P10338).`
2. `Allergies (from patient database)` → the `allergies` field.
3. `Current medications (from patient database)` → the `current_medications` field.
4. `Medical conditions (from patient database)` → the `medical_conditions` field.
5. `Notes (from patient database)` → the `notes` field.

Empty fields show as "Not recorded".

**Button disabled, with a one-line reason,** when the row has no Medicare number or its DOB isn't a valid past `yyyy-MM-dd` date (`IdentityValidation.validDOB`).

**Everything after opening works as it does now:** recording, GP notes, history recovery for a matched patient, the assistant, and Finish visit.

## Approaches

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | Copy the database profile into the visit's answers. | No data-model change, and the brief, History and assistant pick it up automatically. But the assistant and summaries cite intake answers as **"Patient-reported"**, so database facts are labelled that way, and the copy is frozen at consult time. |
| B | Mark the visit as GP-added with a link to the database patient ID, and show the live profile in the brief. | Labels stay honest and the profile stays current, at the cost of one new optional field on `Visit`. |

The user picked **A**. To soften the labelling cost, every copied prompt says "(from patient database)" (my call).

## Constraints

- Mutations run on the app's main `ModelContext`, like `RecordMutations.correctIdentity`, so the `@Query` queue updates immediately. The logic lives in the `Records` package as `RecordMutations.startManualConsult(context:databasePatient:now:)` so it can be tested with in-memory containers.
- No schema change.
- Synthetic data only, as with the rest of the app.

## Left to the builder

- Button placement and style in the Patient database window. Suggested: a prominent **Consult** next to the patient's name in the detail pane, in the app's existing accent style.
- How the workspace is brought to the front when the database window closes.
- The exact wording of the disabled-button reason.
