import Foundation
import Network
import Synchronization
import KioskProtocol
import Records

/// Accepts framed `KioskRequest`s from the waiting-room kiosk over TCP, advertised over Bonjour.
public final class KioskListener: Sendable {
    let store: RecordStore
    let port: NWEndpoint.Port
    let service: NWListener.Service?
    let readTimeout: Duration
    let onSubmission: @Sendable (SubmissionReceipt) async -> Void
    private let listener = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "steadycare.kiosk.listener")
    public init(store: RecordStore, port: NWEndpoint.Port = .any, service: NWListener.Service? = NWListener.Service(type: KioskService.type), readTimeout: Duration = .seconds(10), onSubmission: @escaping @Sendable (SubmissionReceipt) async -> Void = { _ in }) {
        self.store = store; self.port = port; self.service = service; self.readTimeout = readTimeout; self.onSubmission = onSubmission
    }
    /// Starts listening and returns the bound port once the listener is ready.
    public func start() async throws -> NWEndpoint.Port {
        let listener = try NWListener(using: .tcp, on: port)
        listener.service = service
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        self.listener.withLock { $0?.cancel(); $0 = listener }
        let pending = Pending()
        return try await withCheckedThrowingContinuation { continuation in
            pending.set(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.resume(with: listener.port.map { .success($0) } ?? .failure(NWError.posix(.EADDRNOTAVAIL)))
                case .failed(let error): pending.resume(with: .failure(error)); listener.cancel()
                case .cancelled: pending.resume(with: .failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    public func stop() { listener.withLock { $0?.cancel(); $0 = nil } }
    func respond(to body: Data) async -> KioskResponse {
        guard let request = try? JSONDecoder().decode(KioskRequest.self, from: body) else { return .error(message: "The request could not be read.") }
        do {
            let receipt = try await store.recordKioskSubmission(submissionID: request.submissionID, answers: request.answers)
            if !receipt.isReplay { await onSubmission(receipt) }
            return .ok
        } catch let error as RecordError {
            return .error(message: error.localizedDescription)
        } catch {
            return .error(message: "The clinic couldn't save this intake. Please ask reception.")
        }
    }
    private func serve(_ connection: NWConnection) async {
        connection.start(queue: queue)
        let response: KioskResponse
        do {
            guard let body = try await readBody(connection) else { connection.cancel(); return }
            response = await respond(to: body)
        } catch KioskFramingError.tooLarge {
            response = .error(message: "The request is too large.")
        } catch { connection.cancel(); return }
        guard let reply = try? KioskFraming.frame(JSONEncoder().encode(response)) else { connection.cancel(); return }
        await withCheckedContinuation { continuation in
            connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }
    /// Reads one frame body; returns nil if the peer closes or `readTimeout` elapses first.
    private func readBody(_ connection: NWConnection) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var decoder = KioskFrameDecoder()
                while let chunk = try await Self.receive(connection) {
                    if let body = try decoder.append(chunk) { return body }
                }
                return nil
            }
            group.addTask { [readTimeout] in
                try await Task.sleep(for: readTimeout)
                connection.cancel() // Unblocks the pending receive.
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
}
/// Resumes the `start()` continuation at most once, whichever listener state arrives first.
private final class Pending: Sendable {
    private let continuation = Mutex<CheckedContinuation<NWEndpoint.Port, any Error>?>(nil)
    func set(_ value: CheckedContinuation<NWEndpoint.Port, any Error>) { continuation.withLock { $0 = value } }
    func resume(with result: Result<NWEndpoint.Port, any Error>) { continuation.withLock { $0.take() }?.resume(with: result) }
}
