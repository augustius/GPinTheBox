import Testing
import Foundation
@testable import KioskKit

private let req = KioskRequest(submissionID: UUID(), answers: [.init(q: "Full name", a: "Jane Demo")])

@Test func retriesReuseSubmissionIDUntilOk() async {
    let t = FakeTransport(results: [.failure(FakeError()), .failure(FakeError()), .success(.ok)])
    let outcome = await Submitter(transport: t, backoff: [.milliseconds(1)], deadline: .seconds(2)).submit(req)
    #expect(outcome == .accepted)
    #expect(await t.requests == [req, req, req])
}
@Test func errorAckIsNotRetried() async {
    let t = FakeTransport(results: [.success(.error(message: "Enter a valid date of birth.")), .success(.ok)])
    #expect(await Submitter(transport: t, backoff: [.milliseconds(1)]).submit(req) == .rejected("Enter a valid date of birth."))
    #expect(await t.requests.count == 1)
}
@Test func deadlineGivesUnreachable() async {
    let t = FakeTransport(results: Array(repeating: .failure(FakeError()), count: 100))
    #expect(await Submitter(transport: t, backoff: [.milliseconds(20)], deadline: .milliseconds(100)).submit(req) == .unreachable)
}
@Test func deadlineCutsAHangingAttempt() async {
    struct Hanging: KioskTransport {
        func send(_ request: KioskRequest) async throws -> KioskResponse { try await Task.sleep(for: .seconds(60)); return .ok }
    }
    let start = ContinuousClock.now
    #expect(await Submitter(transport: Hanging(), deadline: .milliseconds(100)).submit(req) == .unreachable)
    #expect(ContinuousClock.now - start < .seconds(2))
}
@Test func attemptTimeoutIsRetried() async {
    let t = FakeTransport(results: [.failure(TimeoutError()), .success(.ok)])
    #expect(await Submitter(transport: t, backoff: [.milliseconds(1)], deadline: .seconds(2)).submit(req) == .accepted)
    #expect(await t.requests.count == 2)
}
