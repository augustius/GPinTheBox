import Foundation
import Hummingbird
import Records
public enum HTML {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
public struct IntakeValidationErrors: Error, Equatable, Sendable { public var messages: [String: String] }
public enum IntakeForm {
    public static func fieldName(for id: UUID) -> String { "q_\(id.uuidString)" }
    public static func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(HTML.escape(title))</title><style>
        :root{color-scheme:light;--bg:#F6F2EA;--surface:#FFFCF6;--text:#1F1D1A;--secondary:#66605A;--accent:#2E6A4A;--line:#E2DACB}
        *{box-sizing:border-box}body{font:17px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;margin:0;background:var(--bg);color:var(--text);-webkit-font-smoothing:antialiased}
        main{max-width:640px;margin:48px auto;padding:0 24px 48px}h1{font-size:34px;line-height:1.15;letter-spacing:-.02em;margin:16px 0}h2{font-size:22px;line-height:1.3}p{color:var(--secondary)}
        label{display:block;margin:0 0 6px;font-size:13px;font-weight:600;color:var(--secondary)}
        input,textarea,button{font:inherit;width:100%;color:var(--text)}input,textarea{border:1px solid var(--line);border-radius:8px;padding:12px;background:var(--surface);min-width:0}input{min-height:48px;font-variant-numeric:tabular-nums}textarea{min-height:112px;resize:vertical}
        button,.action{border:0;border-radius:14px;background:var(--accent);color:white;padding:14px 20px;min-height:52px;font-weight:600;cursor:pointer;text-align:center}
        button{margin-top:24px}button:hover,.action:hover{background:#24543B;color:white}a{color:var(--accent);text-underline-offset:3px}a:focus-visible,input:focus-visible,textarea:focus-visible,button:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
        fieldset{border:0;margin:28px 0 0;padding:0;min-width:0}legend{font-size:13px;font-weight:600;color:var(--secondary);padding:0 0 10px}.field{padding:16px;background:var(--surface);border-bottom:1px solid #ECE5D8}.field:first-of-type{border-radius:12px 12px 0 0}.field:last-child{border-radius:0 0 12px 12px;border-bottom:0}
        .error{color:#9F2219;font-size:15px}.error:empty{display:none}.error:not(:empty){margin-top:8px}small{color:var(--secondary)}.brand{font-size:13px;letter-spacing:.08em;font-weight:600}.path{border-top:1px solid var(--line);padding:24px 0;margin:24px 0}.path h2{margin-top:0}.action{display:inline-flex;align-items:center;justify-content:center;text-decoration:none}.secondary{background:#E4DCCC;color:var(--text)}nav{margin-bottom:32px;font-size:15px}.confirmation{padding:28px;background:var(--surface);border:1px solid var(--line);border-radius:12px}.check{color:var(--accent);font-size:36px}@media(max-width:680px){main{margin:28px auto;padding:0 20px 32px}.action{width:100%}}

        </style></head><body><main>\(body)</main></body></html>
        """
    }
    public static func landingPage() -> String {
        page(title: "Welcome to SteadyCare", body: """
        <p class="brand">STEADYCARE</p><h1>Welcome to your visit</h1>
        <p>Choose the pathway that fits you.</p>
        <section class="path"><h2>I’m a patient</h2><p>Complete your details and intake questions before seeing the doctor. Your answers will be sent to the clinic queue.</p><a class="action" href="/intake">Start patient intake</a></section>
        <section class="path"><h2>I’m a GP</h2><p>Manage the visit queue, search patient records, and open consultation tools on the clinic Mac.</p><a class="action secondary" href="/gp">Go to GP workspace</a></section>
        <small>Synthetic-data demo. Please do not enter real patient information.</small>
        """)
    }
    public static func gpPage() -> String {
        page(title: "GP workspace", body: """
        <nav><a href="/">Back to pathways</a></nav><p class="brand">STEADYCARE · GP</p><h1>Your clinic workspace</h1>
        <p>The queue and patient database are available in the SteadyCare app on the clinic Mac.</p>
        <section class="path"><h2>Queue and records</h2><p>Open today’s visits, search the patient database, review history, and record a consultation.</p><a class="action" href="gpinthebox://workspace">Open GP workspace on this Mac</a></section>
        <p>Using a phone? Continue on the clinic Mac. Patient records are not served through this intake website.</p>
        """)
    }
    public static func render(questionnaire: QuestionnaireSnapshot, submissionID: UUID = UUID(), values: [String: String] = [:], errors: [String: String] = [:]) -> String {
        func field(_ name: String, _ label: String, type: String = "text", multiline: Bool = false, required: Bool = false) -> String {
            let value = HTML.escape(values[name] ?? ""), safe = HTML.escape(name)
            let attributes = "id=\"\(safe)\" name=\"\(safe)\" maxlength=\"12000\" \(required ? "required" : "")"
            let control = multiline ? "<textarea \(attributes)>\(value)</textarea>" : "<input \(attributes) type=\"\(type)\" value=\"\(value)\">"
            return "<div class=\"field\"><label for=\"\(safe)\">\(HTML.escape(label))\(required ? " *" : "")</label>\(control)<div class=\"error\">\(HTML.escape(errors[name] ?? ""))</div></div>"
        }
        let body = """
        <nav><a href="/">Back to pathways</a></nav><p class="brand">STEADYCARE · PATIENT</p><h1>Check in</h1><p>Your answers go only to your doctor’s computer in this clinic.</p><p>Synthetic-data demo. Please do not enter real patient information.</p><small>Required fields are marked *.</small>
        <p class="error" role="alert">\(HTML.escape(errors["form"] ?? ""))</p>
        <form action="/submit" method="post" accept-charset="utf-8">
        <input type="hidden" name="submissionID" value="\(submissionID)"><input type="hidden" name="questionnaireID" value="\(questionnaire.id)">
        <fieldset><legend>About you</legend>\(field("fullName", "Full name", required: true))
        \(field("medicareID", "Medicare or insurance ID", required: true))
        \(field("dateOfBirth", "Date of birth", type: "date", required: true))
        </fieldset><fieldset><legend>Today’s visit</legend>\(questionnaire.questions.map { field(fieldName(for: $0.id), $0.prompt, multiline: $0.kind == .longText, required: $0.isRequired) }.joined())
        </fieldset><button type="submit">Send to doctor</button></form>
        """
        return page(title: "Patient intake", body: body)
    }
    public static func thanksPage() -> String { page(title: "Thank you", body: "<div class=\"confirmation\"><span class=\"check\" aria-hidden=\"true\">✓</span><h1>You’re checked in</h1><p>Your answers have been sent to the doctor. Please take a seat.</p><p>You’re in the clinic queue. Your doctor will call you when it’s your turn.</p></div><a href=\"/\">Return to welcome page</a>") }
    public static func parse(fields: [String: String], questionnaire: QuestionnaireSnapshot, now: Date = .now) -> Result<IntakeSubmission, IntakeValidationErrors> {
        let fields = fields.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var errors: [String: String] = [:]
        let name = fields["fullName"] ?? "", medicare = MedicareID.normalise(fields["medicareID"] ?? ""), dob = fields["dateOfBirth"] ?? ""
        if name.isEmpty { errors["fullName"] = "Please enter your full name." }
        else if name.count > 12000 { errors["fullName"] = "Please use at most 12,000 characters." }
        if medicare.isEmpty { errors["medicareID"] = "Please enter your Medicare or insurance ID." }
        else if medicare.count > 12000 { errors["medicareID"] = "Please use at most 12,000 characters." }
        if !IdentityValidation.validDOB(dob, now: now) { errors["dateOfBirth"] = "Please enter a valid date of birth." }
        let submissionID = fields["submissionID"].flatMap(UUID.init(uuidString:))
        if submissionID == nil || fields["questionnaireID"].flatMap(UUID.init(uuidString:)) != questionnaire.id { errors["form"] = "Please open a new form." }
        let answers = questionnaire.questions.map { q in
            let key = fieldName(for: q.id), value = fields[fieldName(for: q.id)] ?? ""
            if q.isRequired && value.isEmpty { errors[key] = "This question is required." }
            if value.count > 12000 { errors[key] = "Please use at most 12,000 characters." }
            return Answer(questionID: q.id, prompt: q.prompt, value: value)
        }
        if !errors.isEmpty { return .failure(IntakeValidationErrors(messages: errors)) }
        return .success(IntakeSubmission(submissionID: submissionID!, questionnaireID: questionnaire.id, fullName: name, medicareID: medicare, dateOfBirth: dob, answers: answers, receivedAt: now))
    }
    public static func decode(_ body: String) throws -> [String: String] {
        // The framework decoder rejects duplicate keys and malformed nested values,
        // avoiding ambiguous identity or idempotency fields.
        try URLEncodedFormDecoder().decode([String: String].self, from: body)
    }
}
