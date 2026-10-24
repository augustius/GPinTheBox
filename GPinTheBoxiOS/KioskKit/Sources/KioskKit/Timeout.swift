import Synchronization

struct TimeoutError: Error {}

/// Throws `TimeoutError` at the deadline even if `operation` ignores cancellation; the operation is cancelled, not awaited.
func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, tasks: [
                Task { do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) } },
                Task { if (try? await Task.sleep(for: duration)) != nil { race.finish(.failure(TimeoutError())) } },
            ])
        }
    } onCancel: { race.finish(.failure(CancellationError())) }
}

private final class Race<T: Sendable>: Sendable {
    private struct State { var continuation: CheckedContinuation<T, any Error>?; var outcome: Result<T, any Error>?; var tasks: [Task<Void, Never>] = [] }
    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<T, any Error>, tasks: [Task<Void, Never>]) {
        let early = state.withLock { s -> Result<T, any Error>? in
            if let outcome = s.outcome { return outcome }
            s.continuation = continuation; s.tasks = tasks; return nil
        }
        if let early { tasks.forEach { $0.cancel() }; continuation.resume(with: early) }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { s -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard s.outcome == nil else { return (nil, []) }
            s.outcome = result
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
