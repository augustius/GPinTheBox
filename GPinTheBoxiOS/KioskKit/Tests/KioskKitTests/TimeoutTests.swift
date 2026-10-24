import Testing
import Foundation
@testable import KioskKit

@Test func timeoutDoesNotWaitForUncooperativeOperation() async {
    let start = ContinuousClock.now
    await #expect(throws: TimeoutError.self) {
        try await withTimeout(.milliseconds(50)) { usleep(500_000); return 1 }
    }
    #expect(ContinuousClock.now - start < .milliseconds(300))
}
@Test func timeoutReturnsFastResult() async throws {
    #expect(try await withTimeout(.seconds(1)) { 42 } == 42)
}
@Test func timeoutPropagatesCallerCancellation() async {
    let task = Task { try await withTimeout(.seconds(5)) { usleep(500_000); return 1 } }
    task.cancel()
    let start = ContinuousClock.now
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - start < .milliseconds(300))
}
