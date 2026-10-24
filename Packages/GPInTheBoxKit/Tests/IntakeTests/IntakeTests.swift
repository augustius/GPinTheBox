import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import Records
@testable import Intake

let q = QuestionnaireSnapshot(questions: [.init(prompt: "Reason <script>?", kind: .longText, isRequired: true)])
func fields(_ questionnaire: QuestionnaireSnapshot = q, id: UUID = UUID()) -> [String: String] {
    ["submissionID": id.uuidString, "questionnaireID": questionnaire.id.uuidString, "fullName": "Nguyễn Hoa", "medicareID": " ab-12/3 ", "dateOfBirth": "1980-05-01"].merging(Dictionary(uniqueKeysWithValues: questionnaire.questions.map { (IntakeForm.fieldName(for: $0.id), "Synthetic cough") })) { $1 }
}
func encode(_ fields: [String: String]) -> String {
    let allowed = CharacterSet.alphanumerics
    return fields.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
}
@Test func escapesEveryAttributeAndPrompt() {
    let html = IntakeForm.render(questionnaire: q, values: ["fullName": "\"><script>alert('x')</script>"])
    #expect(!html.contains("<script>")); #expect(html.contains("&lt;script&gt;")); #expect(html.contains("&#39;"))
    #expect(HTML.escape("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;")
}
@Test func validationUnicodeAndRequiredFields() throws {
    let parsed = try IntakeForm.parse(fields: fields(), questionnaire: q).get()
    #expect(parsed.fullName == "Nguyễn Hoa" && parsed.medicareID == "AB123")
    var missing = fields(); missing["fullName"] = " "; missing["dateOfBirth"] = "2999-01-01"; missing[IntakeForm.fieldName(for: q.questions[0].id)] = ""
    guard case .failure(let error) = IntakeForm.parse(fields: missing, questionnaire: q) else { Issue.record("Expected validation failure"); return }
    #expect(error.messages["fullName"] != nil && error.messages["dateOfBirth"] != nil && error.messages[IntakeForm.fieldName(for: q.questions[0].id)] != nil)
    #expect(try IntakeForm.decode("name=Nguy%E1%BB%85n+Hoa")["name"] == "Nguyễn Hoa")
}
actor Receipts { var all: [SubmissionReceipt] = []; func append(_ r: SubmissionReceipt) { all.append(r) } }
@Test func routesReplayConflictAndOldVersion() async throws {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true))
    let old = try await store.publishQuestionnaire(q.questions)
    _ = try await store.publishQuestionnaire([.init(prompt: "Brand new", kind: .shortText, isRequired: true)])
    let receipts = Receipts()
    let app = Application(router: IntakeServer(store: store, onSubmission: { await receipts.append($0) }).buildRouter())
    let submitted = fields(old)
    try await app.test(.router) { client in
        try await client.execute(uri: "/", method: .get) { response in
            #expect(response.status == .ok); #expect(String(buffer: response.body).contains("Brand new")); #expect(response.headers[.cacheControl] == "no-store")
        }
        for _ in 0..<2 {
            try await client.execute(uri: "/submit", method: .post, headers: [.contentType: "application/x-www-form-urlencoded"], body: .init(string: encode(submitted))) { response in
                #expect(response.status == .seeOther); #expect(response.headers[.location] == "/thanks")
            }
        }
        var changed = submitted; changed["fullName"] = "Different"
        try await client.execute(uri: "/submit", method: .post, body: .init(string: encode(changed))) { response in #expect(response.status == .conflict) }
        var invalid = fields(old); invalid["fullName"] = ""
        try await client.execute(uri: "/submit", method: .post, body: .init(string: encode(invalid))) { response in
            #expect(response.status == .badRequest); #expect(String(buffer: response.body).contains("Please enter your full name."))
        }
        try await client.execute(uri: "/thanks", method: .get) { response in #expect(response.status == .ok) }
    }
    #expect(await receipts.all.count == 1)
    let receipt = try #require(await receipts.all.first)
    #expect(try await store.snapshot(patientID: receipt.patientID).visits.count == 1)
}
@Test func localAddressIsNotLoopback() { #expect(LocalAddress.primaryIPv4()?.hasPrefix("127.") != true) }

@Test func acceptsUUIDCaseAndPreservesValidationValues() throws {
    var values = fields()
    values["questionnaireID"] = q.id.uuidString.lowercased()
    values["fullName"] = "  Nguyễn Hoa  "
    let answerKey = IntakeForm.fieldName(for: q.questions[0].id)
    values[answerKey] = "  头痛 & cough  "
    let parsed = try IntakeForm.parse(fields: values, questionnaire: q).get()
    #expect(parsed.fullName == "Nguyễn Hoa")
    #expect(parsed.answers[0].value == "头痛 & cough")
    let html = IntakeForm.render(questionnaire: q, values: values, errors: ["form": "Invalid <form>", "fullName": "Please enter your full name."])
    #expect(html.contains("Invalid &lt;form&gt;"))
    #expect(html.contains("Please enter your full name."))
    #expect(html.contains("头痛 &amp; cough"))
    #expect(html.contains("value=\" ab-12/3 \""))
}
@Test func lengthAndInvalidCalendarDatesAreRejected() {
    for badDOB in ["1980-02-31", "1980-13-01", "01-05-1980", "2999-01-01"] {
        var values = fields(); values["dateOfBirth"] = badDOB
        guard case .failure(let errors) = IntakeForm.parse(fields: values, questionnaire: q) else { Issue.record("Accepted invalid DOB \(badDOB)"); continue }
        #expect(errors.messages["dateOfBirth"] != nil)
    }
    var values = fields()
    values["fullName"] = String(repeating: "a", count: 12001)
    values["medicareID"] = String(repeating: "1", count: 12001)
    values[IntakeForm.fieldName(for: q.questions[0].id)] = String(repeating: "a", count: 12001)
    guard case .failure(let errors) = IntakeForm.parse(fields: values, questionnaire: q) else { Issue.record("Accepted oversized fields"); return }
    #expect(errors.messages.count == 3)
}
@Test func duplicateFormKeysAreRejected() throws {
    #expect(throws: (any Error).self) { try IntakeForm.decode("fullName=First&fullName=Second") }
    #expect(try IntakeForm.decode("fullName=Jane+Demo&answer=one%3Dtwo%26three")["answer"] == "one=two&three")
}
@Test func invalidMetadataAndEmptySubmissionNeverNotify() async throws {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true))
    let version = try await store.publishQuestionnaire(q.questions), receipts = Receipts()
    let app = Application(router: IntakeServer(store: store, onSubmission: { await receipts.append($0) }).buildRouter())
    try await app.test(.router) { client in
        try await client.execute(uri: "/submit", method: .post, body: .init(string: "")) { response in
            #expect(response.status == .badRequest)
            #expect(response.headers[.contentType] == "text/html; charset=utf-8")
            let html = String(buffer: response.body)
            #expect(html.contains("Please enter your full name."))
            #expect(html.contains("Please open a new form."))
        }
        var invalid = fields(version); invalid["questionnaireID"] = UUID().uuidString
        try await client.execute(uri: "/submit", method: .post, body: .init(string: encode(invalid))) { response in
            #expect(response.status == .badRequest)
            #expect(String(buffer: response.body).contains("questionnaire is unavailable"))
        }
        let ambiguous = encode(fields(version)) + "&fullName=Other"
        try await client.execute(uri: "/submit", method: .post, body: .init(string: ambiguous)) { response in
            #expect(response.status == .badRequest)
        }
    }
    #expect(await receipts.all.isEmpty)
}
@Test func freshFormsHaveIndependentSubmissionIDs() async throws {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true))
    _ = try await store.publishQuestionnaire(q.questions)
    let app = Application(router: IntakeServer(store: store).buildRouter())
    try await app.test(.router) { client in
        let first = try await client.execute(uri: "/", method: .get) { String(buffer: $0.body) }
        let second = try await client.execute(uri: "/", method: .get) { String(buffer: $0.body) }
        #expect(first != second)
    }
}
