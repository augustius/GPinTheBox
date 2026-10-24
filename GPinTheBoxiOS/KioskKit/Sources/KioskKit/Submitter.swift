
public protocol KioskTransport: Sendable {
    func send(_ request: KioskRequest) async throws -> KioskResponse
}

public enum SubmitOutcome: Equatable, Sendable { case accepted, rejected(String), unreachable }

public struct Submitter: Sendable {
    let transport: any KioskTransport
    let backoff: [Duration]
    let deadline: Duration

    public init(transport: any KioskTransport, backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)], deadline: Duration = .seconds(30)) {
        self.transport = transport; self.backoff = backoff; self.deadline = deadline
    }

    /// Resends the same request (same submission ID) until it is acknowledged, rejected, or the deadline passes.
    public func submit(_ request: KioskRequest) async -> SubmitOutcome {
        let clock = ContinuousClock(), end = clock.now.advanced(by: deadline)
        let transport = transport
        for attempt in 0... {
            let remaining = clock.now.duration(to: end)
            guard remaining > .zero else { return .unreachable }
            do {
                switch try await withTimeout(remaining, { try await transport.send(request) }) {
                case .ok: return .accepted
                case .error(let message): return .rejected(message)
                }
            } catch is CancellationError {
                return .unreachable
            } catch {
                // A TimeoutError may be the transport's own attempt timeout; the loop guard handles the overall deadline.
                let wait = backoff.isEmpty ? .zero : backoff[min(attempt, backoff.count - 1)]
                let left = clock.now.duration(to: end)
                guard left > .zero else { return .unreachable }
                do { try await Task.sleep(for: min(wait, left)) } catch { return .unreachable }
            }
        }
        return .unreachable
    }
}
