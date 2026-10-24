import Foundation
import Darwin

public struct SpeakerInterval: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var speakerID: String
    public init(startSeconds: Double, endSeconds: Double, speakerID: String) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.speakerID = speakerID
    }
}

public struct DiarizationConfiguration: Sendable {
    public var pythonExecutable: URL
    public var modelDirectory: URL
    public var workerScriptURL: URL
    public var timeoutSeconds: Double
    public init(pythonExecutable: URL, modelDirectory: URL, workerScriptURL: URL, timeoutSeconds: Double = 300) {
        self.pythonExecutable = pythonExecutable; self.modelDirectory = modelDirectory
        self.workerScriptURL = workerScriptURL; self.timeoutSeconds = timeoutSeconds
    }
}

public enum LocalDiarizationError: Error, LocalizedError, Equatable {
    case missingPython, missingWorker, missingModel, invalidConfiguration, launchFailed, timedOut, outputTooLarge, invalidOutput, workerFailed
    public var errorDescription: String? {
        switch self {
        case .missingPython: "Select the Python executable from your local pyannote environment."
        case .missingWorker: "Select the local diarize.py worker script."
        case .missingModel: "Install the Community-1 model locally and select its folder containing config.yaml. Model access must be accepted in Hugging Face first."
        case .invalidConfiguration: "Local speaker separation requires file URLs and a timeout between 1 and 1800 seconds."
        case .launchFailed: "The local Python worker could not start. Check executable access and macOS sandbox restrictions; transcription remains available."
        case .timedOut: "Local speaker separation timed out. Audio is retained so you can retry or keep the transcript only."
        case .outputTooLarge: "The local speaker worker exceeded its output limit."
        case .invalidOutput: "The local speaker worker returned invalid speaker timing data."
        case .workerFailed: "Local speaker separation failed. Check the local Python dependencies and complete model download. Audio is retained for retry."
        }
    }
}

/// Runs only a caller-selected local Python executable and local model. No hosted API or shell.
public struct LocalSpeakerDiarizer: Sendable {
    public init() {}
    public func diarize(audioURL: URL, configuration: DiarizationConfiguration) async throws -> [SpeakerInterval] {
        try Task.checkCancellation()
        let files = FileManager.default
        guard [audioURL, configuration.pythonExecutable, configuration.modelDirectory, configuration.workerScriptURL].allSatisfy(\.isFileURL),
              configuration.timeoutSeconds.isFinite, (1...1800).contains(configuration.timeoutSeconds) else { throw LocalDiarizationError.invalidConfiguration }
        guard files.isExecutableFile(atPath: configuration.pythonExecutable.path) else { throw LocalDiarizationError.missingPython }
        guard files.isReadableFile(atPath: configuration.workerScriptURL.path) else { throw LocalDiarizationError.missingWorker }
        guard files.isReadableFile(atPath: configuration.modelDirectory.appendingPathComponent("config.yaml").path) else { throw LocalDiarizationError.missingModel }
        let directory = files.temporaryDirectory.appendingPathComponent("gp-diarization-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("result.json"), errorURL = directory.appendingPathComponent("worker.log")
        files.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        files.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = configuration.pythonExecutable
        process.arguments = ["-I", configuration.workerScriptURL.path, "--audio", audioURL.path, "--model", configuration.modelDirectory.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "PYTHONPATH", "PYTHONHOME"] { environment.removeValue(forKey: key) }
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"; environment["PYANNOTE_METRICS_ENABLED"] = "0"
        environment["MPLCONFIGDIR"] = directory.appendingPathComponent("matplotlib").path
        environment["HF_HOME"] = directory.appendingPathComponent("huggingface").path
        process.environment = environment
        do { try process.run() } catch { throw LocalDiarizationError.launchFailed }
        // No detached task or blocking wait: cancellation is checked at most every 100 ms.
        defer {
            if process.isRunning { process.terminate(); _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LocalDiarizationError.timedOut }
            for url in [outputURL, errorURL] {
                let bytes = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard bytes <= 2_000_000 else { throw LocalDiarizationError.outputTooLarge }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw LocalDiarizationError.workerFailed }
        let bytes = (try files.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= 2_000_000 else { throw LocalDiarizationError.outputTooLarge }
        return try Self.decodeIntervals(Data(contentsOf: outputURL))
    }

    public static func decodeIntervals(_ data: Data) throws -> [SpeakerInterval] {
        guard data.count <= 2_000_000 else { throw LocalDiarizationError.outputTooLarge }
        struct Response: Decodable { let schemaVersion: Int; let intervals: [SpeakerInterval] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.schemaVersion == 1,
              !response.intervals.isEmpty, response.intervals.count <= 20_000 else { throw LocalDiarizationError.invalidOutput }
        var lastStart = -Double.infinity
        for segment in response.intervals {
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                  segment.startSeconds >= 0, segment.endSeconds > segment.startSeconds,
                  segment.endSeconds <= 86_400, segment.startSeconds >= lastStart,
                  !segment.speakerID.isEmpty, segment.speakerID.count <= 64,
                  segment.speakerID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else {
                throw LocalDiarizationError.invalidOutput
            }
            lastStart = segment.startSeconds
        }
        return response.intervals
    }
}

/// Conservative timestamp matching. Unknown/overlapping voices remain unassigned for GP review.
public enum SpeakerAlignment {
    public static func speakerID(startSeconds: Double, endSeconds: Double, intervals: [SpeakerInterval]) -> String? {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds else { return nil }
        let matches = intervals.filter { $0.startSeconds < endSeconds && $0.endSeconds > startSeconds }
        let speakers = Set(matches.map(\.speakerID))
        guard speakers.count == 1, let speaker = speakers.first else { return nil }
        // Union intervals to avoid double-counting overlapping segments from the same speaker.
        let ranges = matches.map { (max(startSeconds, $0.startSeconds), min(endSeconds, $0.endSeconds)) }.sorted { $0.0 < $1.0 }
        var covered = 0.0, previousEnd = startSeconds
        for (start, end) in ranges {
            covered += max(0, end - max(start, previousEnd)); previousEnd = max(previousEnd, end)
        }
        return covered / (endSeconds - startSeconds) >= 0.6 ? speaker : nil
    }
}
