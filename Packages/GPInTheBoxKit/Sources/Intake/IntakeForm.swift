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
        body{font:17px -apple-system,system-ui;margin:0;background:#f1f5f4;color:#163b37}main{max-width:620px;margin:30px auto;padding:28px;background:white;border-radius:20px}label{display:block;margin:22px 0 8px;font-weight:600}input,textarea,button{font:inherit;box-sizing:border-box;width:100%;padding:12px;border:1px solid #9aadaa;border-radius:8px}textarea{min-height:110px}button{background:#17685c;color:white;margin-top:26px;cursor:pointer}.error{color:#a12828}small{color:#526b66}h1{font-size:30px}a{color:#17685c}.brand{font-size:14px;letter-spacing:.1em;font-weight:700}.path{border:1px solid #ccdeda;border-radius:16px;padding:22px;margin:20px 0}.path h2{margin-top:0}.action{display:inline-block;background:#17685c;color:white;padding:14px 20px;border-radius:9px;text-decoration:none;font-weight:600}.secondary{background:#e7f0ed;color:#163b37}nav{margin-bottom:24px}@media(max-width:680px){main{margin:12px;padding:22px}}
        </style></head><body><main>\(body)</main></body></html>
        """
    }
    public static func landingPage() -> String {
        page(title: "Welcome to GPInTheBox", body: """
        <p class="brand">GPINTHEBOX</p><h1>Welcome to your visit</h1>
        <p>Choose the pathway that fits you.</p>
        <section class="path"><h2>I’m a patient</h2><p>Complete your details and intake questions before seeing the doctor. Your answers will be sent to the clinic queue.</p><a class="action" href="/intake">Start patient intake</a></section>
        <section class="path"><h2>I’m a GP</h2><p>Manage the visit queue, search patient records, and open consultation tools on the clinic Mac.</p><a class="action secondary" href="/gp">Go to GP workspace</a></section>
        <small>Synthetic-data demo. Please do not enter real patient information.</small>
        """)
    }
    public static func gpPage() -> String {
        page(title: "GP workspace", body: """
        <nav><a href="/">Back to pathways</a></nav><p class="brand">GPINTHEBOX · GP</p><h1>Your clinic workspace</h1>
        <p>The queue and patient database are available in the GPInTheBox app on the clinic Mac.</p>
        <section class="path"><h2>Queue and records</h2><p>Open today’s visits, search the patient database, review history, and record a consultation.</p><a class="action" href="gpinthebox://workspace">Open GP workspace on this Mac</a></section>
        <p>Using a phone? Continue on the clinic Mac. Patient records are not served through this intake website.</p>
        """)
    }
    public static func render(questionnaire: QuestionnaireSnapshot, submissionID: UUID = UUID(), values: [String: String] = [:], errors: [String: String] = [:]) -> String {
        func field(_ name: String, _ label: String, type: String = "text", multiline: Bool = false, required: Bool = false) -> String {
            let value = HTML.escape(values[name] ?? ""), safe = HTML.escape(name)
            let attributes = "id=\"\(safe)\" name=\"\(safe)\" maxlength=\"12000\" \(required ? "required" : "")"
            let control = multiline ? "<textarea \(attributes)>\(value)</textarea>" : "<input \(attributes) type=\"\(type)\" value=\"\(value)\">"
            return "<label for=\"\(safe)\">\(HTML.escape(label))\(required ? " *" : "")</label>\(control)<div class=\"error\">\(HTML.escape(errors[name] ?? ""))</div>"
        }
        let body = """
        <nav><a href="/">Back to pathways</a></nav><p class="brand">GPINTHEBOX · PATIENT</p><h1>Patient intake</h1><p>Synthetic-data demo. Please do not enter real patient information.</p><small>Required fields are marked *.</small>
        <p class="error" role="alert">\(HTML.escape(errors["form"] ?? ""))</p>
        <form action="/submit" method="post" accept-charset="utf-8">
        <input type="hidden" name="submissionID" value="\(submissionID)"><input type="hidden" name="questionnaireID" value="\(questionnaire.id)">
        \(field("fullName", "Full name", required: true))
        \(field("medicareID", "Medicare or insurance ID", required: true))
        \(field("dateOfBirth", "Date of birth", type: "date", required: true))
        \(questionnaire.questions.map { field(fieldName(for: $0.id), $0.prompt, multiline: $0.kind == .longText, required: $0.isRequired) }.joined())
        <button type="submit">Send to doctor</button></form>
        """
        return page(title: "Patient intake", body: body)
    }
    public static func thanksPage() -> String { page(title: "Thank you", body: "<h1>Thank you</h1><p>Your answers have been sent to the doctor. Please take a seat.</p><a href=\"/\">Return to welcome page</a>") }
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
