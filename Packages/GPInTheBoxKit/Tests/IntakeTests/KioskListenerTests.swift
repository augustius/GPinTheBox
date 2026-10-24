import Testing
import Foundation
import Network
import Records
@testable import Intake

func kioskBody(_ id: UUID = UUID(), dob: String = "1980-05-01") throws -> Data {
    try JSONEncoder().encode(KioskRequest(submissionID: id, answers: [
        .init(q: "Full name", a: "Jane Demo"), .init(q: "Medicare or insurance ID", a: "DEMO001"), .init(q: "Date of birth", a: dob)]))
}
@Test func respondSavesOnceAndAcksReplays() async throws {
    let store = RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)); let receipts = Receipts()
    let listener = KioskListener(store: store, service: nil, onSubmission: { await receipts.append($0) })
    let body = try kioskBody()
    #expect(await listener.respond(to: body) == .ok)
    #expect(await listener.respond(to: body) == .ok)
    #expect(await receipts.all.count == 1)
}
@Test func respondReportsErrors() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    #expect(await listener.respond(to: Data("nope".utf8)) == .error(message: "The request could not be read."))
    #expect(await listener.respond(to: try kioskBody(dob: "2999-01-01")) == .error(message: RecordError.invalidIdentity.errorDescription!))
}
@Test func loopbackFramedRequestGetsAck() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    let port = try await listener.start(); defer { listener.stop() }
    let reply = try await exchange(try KioskFraming.frame(try kioskBody()), port: port)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: reply) == .ok)
}
@Test func loopbackOversizeHeaderGetsError() async throws {
    let listener = KioskListener(store: RecordStore(modelContainer: try GPInTheBoxSchema.makeContainer(inMemory: true)), service: nil)
    let port = try await listener.start(); defer { listener.stop() }
    let reply = try await exchange(Data([0x00, 0x04, 0x93, 0xE0]) /* 300_000 */, port: port)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: reply) == .error(message: "The request is too large."))
}

enum ExchangeError: Error { case closed, timedOut }
/// Sends `bytes` to the listener on loopback and returns the body of the first reply frame; fails after 5 s.
func exchange(_ bytes: Data, port: NWEndpoint.Port) async throws -> Data {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    connection.start(queue: DispatchQueue(label: "kiosk.test.client"))
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                })
            }
            var decoder = KioskFrameDecoder()
            while true {
                let chunk: Data = try await withCheckedThrowingContinuation { c in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                        if let error { c.resume(throwing: error) }
                        else if let data, !data.isEmpty { c.resume(returning: data) }
                        else if isComplete { c.resume(throwing: ExchangeError.closed) }
                        else { c.resume(returning: Data()) }
                    }
                }
                if let body = try decoder.append(chunk) { return body }
            }
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw ExchangeError.timedOut }
        // Cancelling the connection completes any pending receive, so the group can finish.
        defer { group.cancelAll(); connection.cancel() }
        return try await group.next()!
    }
}
