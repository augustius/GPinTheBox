import AVFoundation
import Foundation
import Testing
@testable import ConsultationAudio

@Test func nativeDiarizationDoesNotDownloadMissingModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine = NativeSpeakerDiarizer(modelDirectory: directory)
    #expect(!engine.isModelInstalled)
    await #expect(throws: NativeDiarizationError.modelNotInstalled) {
        try await engine.diarize(audioURL: directory.appendingPathComponent("missing.caf"))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func nativeDiarizationHonoursPreCancelledRequest() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeSpeakerDiarizer().diarize(audioURL: URL(fileURLWithPath: "/not-read.caf"))
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected \(error)") }
}

@Test func nativeDiarizationInputValidationRejectsNetworkAndOversizedFiles() throws {
    #expect(throws: NativeDiarizationError.unsupportedAudio) {
        try NativeSpeakerDiarizer.validateAudio(URL(string: "https://example.invalid/audio.wav")!)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 512 * 1024 * 1024 + 1)
    try handle.close()
    #expect(throws: NativeDiarizationError.audioTooLong) { try NativeSpeakerDiarizer.validateAudio(url) }
}

@Test func nativeDiarizationInputValidationAcceptsShortMonoCAF() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 16_000)
        try file.write(from: buffer)
    }
    #expect(try NativeSpeakerDiarizer.validateAudio(url) == 1)
}
