import Foundation
import Network
import KioskProtocol

public struct NetworkTransport: KioskTransport {
    enum TransportError: Error { case closed }
    let endpoint: NWEndpoint
    let attemptTimeout: Duration

    public init(endpoint: NWEndpoint, attemptTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint; self.attemptTimeout = attemptTimeout
    }

    public func send(_ request: KioskRequest) async throws -> KioskResponse {
        let frame = try KioskFraming.frame(try JSONEncoder().encode(request))
        let connection = NWConnection(to: endpoint, using: .tcp)
        // Cancelling fails any pending send or receive, so a refused or stalled connection ends the attempt.
        connection.stateUpdateHandler = { state in
            switch state { case .waiting, .failed: connection.cancel(); default: break }
        }
        connection.start(queue: DispatchQueue(label: "kiosk.transport"))
        defer { connection.cancel() }
        let body = try await withTimeout(attemptTimeout) { try await Self.exchange(frame, on: connection) }
        return try JSONDecoder().decode(KioskResponse.self, from: body)
    }

    private static func exchange(_ frame: Data, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
        var decoder = KioskFrameDecoder()
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else if isComplete { c.resume(throwing: TransportError.closed) }
                    else { c.resume(returning: Data()) }
                }
            }
            if let body = try decoder.append(chunk) { return body }
        }
    }
}
