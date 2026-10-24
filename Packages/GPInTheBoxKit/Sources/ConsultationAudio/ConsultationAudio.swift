import AVFoundation
import Foundation
import Observation
import Speech

public enum ConsultationAudioError: Error, LocalizedError, Equatable {
    case microphoneDenied, recordingAlreadyStarted, recordingFailed, recordingInterrupted
    case unsupportedLocale(String), onDeviceSpeechUnavailable, assetsUnavailable, emptyTranscript
    case invalidFileName, fileAlreadyExists, emptyAudio, transcriptionAlreadyRunning
    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is required to record this consultation. Enable it in System Settings → Privacy & Security → Microphone."
        case .recordingAlreadyStarted: "A recording is already starting or in progress."
        case .recordingFailed: "The microphone recording could not start. Check the selected audio input and available storage."
        case .recordingInterrupted: "Recording stopped unexpectedly. The recorded audio is preserved for transcription or retry."
        case .unsupportedLocale(let locale): "On-device transcription is not available for \(locale) on this Mac."
        case .onDeviceSpeechUnavailable: "Apple’s on-device speech transcriber is unavailable on this Mac. Audio is retained; no cloud transcription is used."
        case .assetsUnavailable: "The on-device speech language assets could not be installed. Audio is retained for retry."
        case .emptyTranscript: "No speech was recognised. Audio is retained; check the microphone and retry or discard the recording."
        case .invalidFileName: "The recording file name is invalid."
        case .fileAlreadyExists: "This recording file already exists and will not be overwritten."
        case .emptyAudio: "The recording contains no audio frames."
        case .transcriptionAlreadyRunning: "A transcription is already running."
        }
    }
}

public enum ConsultationLanguage: String, CaseIterable, Sendable, Identifiable {
    case englishAustralia = "en-AU"
    case englishUS = "en-US"
    public var id: String { rawValue }
    public var label: String { self == .englishAustralia ? "English (Australia)" : "English (US)" }
}

/// Audio stays in Application Support until its transcript has been committed to the record.
/// This helper never deletes audio automatically; deletion is explicitly controlled by the caller.
public enum ConsultationAudioFiles {
    public static func directory() throws -> URL {
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = applicationSupport.appendingPathComponent("GPInTheBox/ConsultationAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    public static func url(fileName: String) throws -> URL {
        try url(fileName: fileName, directory: directory())
    }
    public static func url(fileName: String, directory: URL) throws -> URL {
        guard !fileName.isEmpty, !fileName.hasPrefix("."), !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["caf", "m4a", "wav", "aiff"].contains((fileName as NSString).pathExtension.lowercased()) else {
            throw ConsultationAudioError.invalidFileName
        }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let result = base.appendingPathComponent(fileName).standardizedFileURL
        guard result.deletingLastPathComponent().path == base.path,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: result.path)) == nil else {
            throw ConsultationAudioError.invalidFileName
        }
        return result
    }
}

@MainActor @Observable public final class ConsultationRecorder: NSObject, AVAudioRecorderDelegate {
    public private(set) var isRecording = false
    public private(set) var isStarting = false
    public private(set) var duration: TimeInterval = 0
    public private(set) var lastError: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var startID = UUID()

    public override init() { super.init() }

    /// Called only after the doctor explicitly starts the consented recording.
    public func start(url: URL) async throws {
        try Task.checkCancellation()
        guard !isRecording && !isStarting else { throw ConsultationAudioError.recordingAlreadyStarted }
        let operation = UUID(); startID = operation; isStarting = true; lastError = nil
        defer { if startID == operation { isStarting = false } }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard startID == operation else { throw CancellationError() }
        guard granted else { throw ConsultationAudioError.microphoneDenied }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ConsultationAudioError.fileAlreadyExists }
        let value = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        value.delegate = self
        guard value.prepareToRecord(), value.record() else { throw ConsultationAudioError.recordingFailed }
        // No suspension between the cancellation check and recording start.
        recorder = value; duration = 0; isRecording = true
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.isRecording, let value = self.recorder else { return }
                self.duration = value.currentTime
                if !value.isRecording {
                    self.isRecording = false
                    self.lastError = ConsultationAudioError.recordingInterrupted.localizedDescription
                    return
                }
            }
        }
    }

    /// Also invalidates an outstanding microphone-permission request so it cannot start later.
    @discardableResult public func stop() throws -> TimeInterval {
        startID = UUID(); isStarting = false
        timerTask?.cancel(); timerTask = nil
        if let recorder {
            if recorder.isRecording { duration = recorder.currentTime }
            isRecording = false
            recorder.stop()
            self.recorder = nil
        }
        isRecording = false
        return duration
    }

    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identifier else { return }
            if !flag { self.lastError = ConsultationAudioError.recordingInterrupted.localizedDescription }
            self.isRecording = false; self.timerTask?.cancel()
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let identifier = ObjectIdentifier(recorder), detail = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identifier else { return }
            self.duration = current.currentTime
            self.lastError = detail ?? ConsultationAudioError.recordingInterrupted.localizedDescription
            self.isRecording = false; self.timerTask?.cancel(); current.stop()
        }
    }
}

public actor OnDeviceTranscriber {
    private var busy = false
    public init() {}

    /// SpeechTranscriber performs recognition on device. Only language-asset installation may
    /// use the network; no SFSpeechRecognizer/server recognition fallback exists here.
    public func transcribe(url: URL, localeIdentifier: String) async throws -> String {
        guard !busy else { throw ConsultationAudioError.transcriptionAlreadyRunning }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        guard ConsultationLanguage(rawValue: localeIdentifier) != nil else { throw ConsultationAudioError.unsupportedLocale(localeIdentifier) }
        guard SpeechTranscriber.isAvailable else { throw ConsultationAudioError.onDeviceSpeechUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw ConsultationAudioError.unsupportedLocale(localeIdentifier)
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: modules) == .installed else { throw ConsultationAudioError.assetsUnavailable }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw ConsultationAudioError.emptyAudio }
        let analyzer = SpeechAnalyzer(modules: modules)
        let resultTask = Task {
            var portions: [String] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                // The transcription preset emits final results, never volatile hypotheses.
                guard result.isFinal else { continue }
                let portion = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !portion.isEmpty { portions.append(portion) }
            }
            return portions.joined(separator: " ")
        }
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let transcript = try await resultTask.value
                try Task.checkCancellation()
                guard !transcript.isEmpty else { throw ConsultationAudioError.emptyTranscript }
                return transcript
            } catch {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            resultTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
