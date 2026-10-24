import Foundation
import Testing
@testable import ConsultationAudio

@Test func supportsBothRequestedEnglishVariants() {
    #expect(ConsultationLanguage.allCases.map(\.rawValue) == ["en-AU", "en-US"])
    #expect(ConsultationLanguage.englishAustralia.label == "English (Australia)")
}
@Test func rejectsPathsOutsideAudioDirectory() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for fileName in ["", "../recording.caf", "/tmp/recording.caf", "nested/recording.caf", "nested\\recording.caf", ".hidden.caf", "recording.txt", "audio\n.caf"] {
        #expect(throws: ConsultationAudioError.invalidFileName) { try ConsultationAudioFiles.url(fileName: fileName, directory: base) }
    }
    let url = try ConsultationAudioFiles.url(fileName: "recording-123.caf", directory: base)
    #expect(url.lastPathComponent == "recording-123.caf")
    #expect(!FileManager.default.fileExists(atPath: base.path))
}
@Test func rejectsAudioSymlinkOutsideDirectory() throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    try manager.createSymbolicLink(at: base.appendingPathComponent("escape.caf"), withDestinationURL: base.deletingLastPathComponent().appendingPathComponent("outside.caf"))
    #expect(throws: ConsultationAudioError.invalidFileName) { try ConsultationAudioFiles.url(fileName: "escape.caf", directory: base) }
}
@Test @MainActor func stopBeforeStartDoesNotRequestMicrophoneOrDeleteFiles() throws {
    let recorder = ConsultationRecorder()
    #expect(!recorder.isRecording && !recorder.isStarting && recorder.duration == 0)
    #expect(try recorder.stop() == 0)
    #expect(recorder.lastError == nil)
}
@Test func unsupportedLocaleFailsBeforeAccessingAudio() async {
    let transcriber = OnDeviceTranscriber()
    await #expect(throws: ConsultationAudioError.unsupportedLocale("fr-FR")) {
        try await transcriber.transcribe(url: URL(fileURLWithPath: "/nonexistent.caf"), localeIdentifier: "fr-FR")
    }
}
@Test func cancelledTranscriptionDoesNotReadOrDeleteAudio() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    try Data("preserve me".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let task = Task {
        try Task.checkCancellation()
        return try await OnDeviceTranscriber().transcribe(url: url, localeIdentifier: "en-AU")
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(try Data(contentsOf: url) == Data("preserve me".utf8))
}
@Test @MainActor func cancelledRecordingStartDoesNotRequestMicrophone() async {
    let recorder = ConsultationRecorder()
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        try await recorder.start(url: URL(fileURLWithPath: "/nonexistent.caf"))
    }
    do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(!recorder.isRecording && !recorder.isStarting)
}
