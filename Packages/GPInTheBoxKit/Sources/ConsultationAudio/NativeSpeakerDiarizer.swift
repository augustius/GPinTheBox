import Foundation
import AVFoundation
import CoreML
@preconcurrency import FluidAudio

public enum NativeDiarizationError: Error, LocalizedError, Equatable {
    case modelNotInstalled, operationInProgress, unsupportedAudio, audioTooLong, noSpeakers, invalidOutput
    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "Download the native speaker model in Speech settings first. No login is required."
        case .operationInProgress: "A native speaker-model operation is already running. Wait or cancel it before retrying."
        case .unsupportedAudio: "Speaker separation requires a readable local audio file with at most two channels and a sample rate up to 96 kHz."
        case .audioTooLong: "This demo supports speaker separation for recordings up to 30 minutes and 512 MB. Keep the transcript only or use a shorter recording."
        case .noSpeakers: "No usable speaker segments were detected. Audio is retained for retry or transcript-only completion."
        case .invalidOutput: "The native speaker model returned invalid timings. Audio is retained."
        }
    }
}

/// Native Core ML Sortformer adapter. All inference loads only the installed local model.
/// Model assets are downloaded only by the explicit prepareModels action.
public struct NativeSpeakerDiarizer: Sendable {
    public static let maximumDurationSeconds: Double = 30 * 60
    public static let modelVariant = "v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc"
    public static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPInTheBox/NativeSpeakerModels", isDirectory: true)
    }
    public let directory: URL
    public init(modelDirectory: URL? = nil) { directory = modelDirectory ?? Self.modelDirectory }
    private var modelURL: URL { directory.appendingPathComponent(Repo.sortformer.folderName).appendingPathComponent(Self.modelVariant) }
    private var readyURL: URL { directory.appendingPathComponent("balanced-v2.1-v3-fp16.ready") }
    public var isModelInstalled: Bool {
        FileManager.default.isReadableFile(atPath: readyURL.path)
            && FileManager.default.isReadableFile(atPath: modelURL.appendingPathComponent("coremldata.bin").path)
    }

    public func prepareModels() async throws {
        try await Self.runExclusive {
            try Task.checkCancellation()
            if isModelInstalled {
                _ = try Self.loadModels(at: modelURL)
                try Task.checkCancellation()
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await ModelHub.download(.sortformer, to: directory, variant: Self.modelVariant)
            try Task.checkCancellation()
            // Mark ready only after the downloaded model can actually be loaded on this Mac.
            _ = try Self.loadModels(at: modelURL)
            try Task.checkCancellation()
            try Data("FluidAudio 0.17.7; Sortformer balancedV2_1 v3/fp16\n".utf8).write(to: readyURL, options: .atomic)
        }
    }

    public func diarize(audioURL: URL) async throws -> [SpeakerInterval] {
        try await Self.runExclusive {
            try Task.checkCancellation()
            guard isModelInstalled else { throw NativeDiarizationError.modelNotInstalled }
            let duration = try Self.validateAudio(audioURL)
            let engine = SortformerDiarizer(config: .balancedV2_1)
            engine.initialize(models: try Self.loadModels(at: modelURL))
            try Task.checkCancellation()
            // FluidAudio checks Task cancellation before each Core ML inference chunk.
            let timeline = try engine.processComplete(audioFileURL: audioURL, keepingEnrolledSpeakers: false)
            try Task.checkCancellation()
            let intervals = timeline.speakers.values.flatMap(\.finalizedSegments).map { segment in
                SpeakerInterval(startSeconds: Double(segment.startTime), endSeconds: min(duration, Double(segment.endTime)), speakerID: "SPEAKER_\(segment.speakerIndex)")
            }.filter { $0.endSeconds > $0.startSeconds }.sorted {
                if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                return $0.speakerID < $1.speakerID
            }
            guard !intervals.isEmpty else { throw NativeDiarizationError.noSpeakers }
            guard intervals.count <= 20_000, intervals.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.startSeconds >= 0 && $0.endSeconds <= duration }) else {
                throw NativeDiarizationError.invalidOutput
            }
            return intervals
        }
    }

    private static func loadModels(at url: URL) throws -> SortformerModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        // Direct Core ML loading has no model-hub or network fallback.
        let model = try MLModel(contentsOf: url, configuration: configuration)
        return try SortformerModels(config: .balancedV2_1, main: model)
    }

    static func validateAudio(_ url: URL) throws -> Double {
        guard url.isFileURL else { throw NativeDiarizationError.unsupportedAudio }
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes <= 512 * 1024 * 1024 else { throw NativeDiarizationError.audioTooLong }
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, rate <= 96_000, file.processingFormat.channelCount <= 2,
              file.processingFormat.channelCount > 0, file.length > 0 else { throw NativeDiarizationError.unsupportedAudio }
        let duration = Double(file.length) / rate
        guard duration <= maximumDurationSeconds else { throw NativeDiarizationError.audioTooLong }
        return duration
    }

    /// The detached task prevents synchronous Core ML prediction/audio conversion from occupying
    /// the main actor. Cancellation propagates to it; a single in-flight prediction must finish.
    private static func runExclusive<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        try await NativeSpeakerOperationGate.shared.acquire()
        let task = Task.detached(priority: .userInitiated, operation: operation)
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await NativeSpeakerOperationGate.shared.release()
            return result
        } catch {
            await NativeSpeakerOperationGate.shared.release()
            throw error
        }
    }
}

private actor NativeSpeakerOperationGate {
    static let shared = NativeSpeakerOperationGate()
    private var busy = false
    func acquire() throws {
        guard !busy else { throw NativeDiarizationError.operationInProgress }
        busy = true
    }
    func release() { busy = false }
}
