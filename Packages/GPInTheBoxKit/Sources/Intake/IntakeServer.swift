import Foundation
import Hummingbird
import Records
import Darwin

public struct IntakeServer: Sendable {
    let store: RecordStore
    let host: String
    let port: Int
    let onSubmission: @Sendable (SubmissionReceipt) async -> Void
    public init(store: RecordStore, host: String = "0.0.0.0", port: Int = 8080, onSubmission: @escaping @Sendable (SubmissionReceipt) async -> Void = { _ in }) {
        self.store = store; self.host = host; self.port = port; self.onSubmission = onSubmission
    }
    public func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/") { _, _ -> Response in Self.html(IntakeForm.landingPage()) }
        router.get("/gp") { _, _ -> Response in Self.html(IntakeForm.gpPage()) }
        router.get("/intake") { _, _ -> Response in
            let q = try await store.questionnaire()
            return Self.html(IntakeForm.render(questionnaire: q))
        }
        router.get("/thanks") { _, _ -> Response in Self.html(IntakeForm.thanksPage()) }
        router.post("/submit") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 256 * 1024)
            let fields: [String: String]
            do { fields = try IntakeForm.decode(String(buffer: buffer)) }
            catch {
                return Self.html(IntakeForm.page(title: "Invalid form", body: "<p>The form could not be decoded. Please <a href=\"/intake\">open a new form</a>.</p>"), status: .badRequest)
            }
            guard let qid = fields["questionnaireID"].flatMap(UUID.init(uuidString:)), let sid = fields["submissionID"].flatMap(UUID.init(uuidString:)) else {
                let questionnaire = try await store.questionnaire()
                let errors: [String: String]
                switch IntakeForm.parse(fields: fields, questionnaire: questionnaire) {
                case .failure(let validation): errors = validation.messages
                case .success: errors = ["form": "Please open a new form."]
                }
                return Self.html(IntakeForm.render(questionnaire: questionnaire, values: fields, errors: errors), status: .badRequest)
            }
            do {
                let q = try await store.questionnaire(id: qid)
                switch IntakeForm.parse(fields: fields, questionnaire: q) {
                case .failure(let error): return Self.html(IntakeForm.render(questionnaire: q, submissionID: sid, values: fields, errors: error.messages), status: .badRequest)
                case .success(let submission):
                    let receipt = try await store.recordSubmission(submission)
                    if !receipt.isReplay { await onSubmission(receipt) }
                    return Response(status: .seeOther, headers: [.location: "/thanks", .cacheControl: "no-store"])
                }
            } catch let error as RecordError {
                let status: HTTPResponse.Status = if case .submissionConflict = error { .conflict } else { .badRequest }
                return Self.html(IntakeForm.page(title: "Unable to submit", body: "<p>\(HTML.escape(error.localizedDescription))</p><a href=\"/intake\">Open a new form</a>"), status: status)
            }
        }
        return router
    }
    private static func html(_ value: String, status: HTTPResponse.Status = .ok) -> Response {
        Response(status: status, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"], body: .init(byteBuffer: .init(string: value)))
    }
    public func run() async throws {
        let app = Application(router: buildRouter(), configuration: .init(address: .hostname(host, port: port), serverName: "GPInTheBox"))
        try await app.runService()
    }
}
public enum LocalAddress {
    public static func primaryIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        var cursor = pointer
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  p.pointee.ifa_flags & UInt32(IFF_UP) != 0, p.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: p.pointee.ifa_name), String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
            }
        }
        return candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1
    }
}
