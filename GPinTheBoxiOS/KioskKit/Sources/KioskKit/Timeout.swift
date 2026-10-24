struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw TimeoutError() }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
