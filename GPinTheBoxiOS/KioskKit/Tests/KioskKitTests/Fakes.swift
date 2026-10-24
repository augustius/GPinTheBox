import KioskProtocol
@testable import KioskKit

struct FakeError: Error {}

struct FakeAnswerModel: AnswerModel {
    var isAvailable = true
    var tidied: [String: String] = [:]
    var prefill: [Int: String] = [:]
    var delay: Duration? = nil
    var error: (any Error & Sendable)? = nil

    func tidy(_ transcript: String, for question: KioskQuestion) async throws -> String {
        try await perform { tidied[transcript] ?? transcript }
    }
    func prefill(transcript: String, remaining: [KioskQuestion]) async throws -> [Int: String] {
        try await perform { prefill }
    }
    private func perform<T>(_ result: () -> T) async throws -> T {
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return result()
    }
}

actor FakeTransport: KioskTransport {
    private var results: [Result<KioskResponse, any Error>]
    private(set) var requests: [KioskRequest] = []
    init(results: [Result<KioskResponse, any Error>]) { self.results = results }

    func send(_ request: KioskRequest) async throws -> KioskResponse {
        requests.append(request)
        guard !results.isEmpty else { throw FakeError() }
        return try results.removeFirst().get()
    }
}
