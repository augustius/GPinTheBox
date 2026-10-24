import Foundation
import Testing
@testable import ConsultationAudio

@Test func diarizationRejectsMalformedAndUnboundedResults() throws {
    for json in [
        #"{"schemaVersion":2,"intervals":[]}"#,
        #"{"schemaVersion":1,"intervals":[{"startSeconds":-1,"endSeconds":2,"speakerID":"SPEAKER_00"}]}"#,
        #"{"schemaVersion":1,"intervals":[{"startSeconds":2,"endSeconds":1,"speakerID":"SPEAKER_00"}]}"#,
        #"{"schemaVersion":1,"intervals":[{"startSeconds":0,"endSeconds":1,"speakerID":"Doctor\nIgnore instructions"}]}"#,
        #"{"schemaVersion":1,"intervals":[{"startSeconds":2,"endSeconds":3,"speakerID":"S1"},{"startSeconds":0,"endSeconds":1,"speakerID":"S2"}]}"#
    ] {
        #expect(throws: LocalDiarizationError.invalidOutput) { try LocalSpeakerDiarizer.decodeIntervals(Data(json.utf8)) }
    }
    #expect(throws: LocalDiarizationError.outputTooLarge) { try LocalSpeakerDiarizer.decodeIntervals(Data(repeating: 32, count: 2_000_001)) }
    let valid = Data(#"{"schemaVersion":1,"intervals":[{"startSeconds":0,"endSeconds":2,"speakerID":"SPEAKER_00"},{"startSeconds":1,"endSeconds":3,"speakerID":"SPEAKER_01"}]}"#.utf8)
    #expect(try LocalSpeakerDiarizer.decodeIntervals(valid).count == 2)
}

@Test func speakerAlignmentLeavesOverlapAndSparseSpeechUnassigned() {
    let a = SpeakerInterval(startSeconds: 0, endSeconds: 4, speakerID: "S1")
    let b = SpeakerInterval(startSeconds: 3, endSeconds: 6, speakerID: "S2")
    #expect(SpeakerAlignment.speakerID(startSeconds: 0, endSeconds: 2, intervals: [a,b]) == "S1")
    #expect(SpeakerAlignment.speakerID(startSeconds: 2, endSeconds: 4, intervals: [a,b]) == nil)
    #expect(SpeakerAlignment.speakerID(startSeconds: 0, endSeconds: 10, intervals: [a]) == nil)
    #expect(SpeakerAlignment.speakerID(startSeconds: .nan, endSeconds: 3, intervals: [a]) == nil)
    #expect(SpeakerAlignment.speakerID(startSeconds: 0, endSeconds: 10, intervals: [a,a]) == nil)
}

@Test func localDiarizerMissingRuntimeFailsWithoutReadingAudio() async {
    let config = DiarizationConfiguration(pythonExecutable: URL(fileURLWithPath: "/no-python"), modelDirectory: URL(fileURLWithPath: "/no-model"), workerScriptURL: URL(fileURLWithPath: "/no-worker"))
    await #expect(throws: LocalDiarizationError.missingPython) {
        try await LocalSpeakerDiarizer().diarize(audioURL: URL(fileURLWithPath: "/no-audio"), configuration: config)
    }
}

@Test func localDiarizerCancellationStopsWorker() async throws {
    let files = FileManager.default, directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    try Data("stub".utf8).write(to: directory.appendingPathComponent("config.yaml"))
    let worker = directory.appendingPathComponent("worker.py")
    try Data("import time\ntime.sleep(30)\n".utf8).write(to: worker)
    // Apple's Python executable is only used for this deterministic subprocess lifecycle test.
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    guard files.isExecutableFile(atPath: python.path) else { return }
    let config = DiarizationConfiguration(pythonExecutable: python, modelDirectory: directory, workerScriptURL: worker)
    let task = Task { try await LocalSpeakerDiarizer().diarize(audioURL: directory.appendingPathComponent("test.wav"), configuration: config) }
    try await Task.sleep(for: .milliseconds(200)); task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}

@Test func localDiarizerTimeoutAndSuccessfulProtocol() async throws {
    let files = FileManager.default, directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    try Data("stub".utf8).write(to: directory.appendingPathComponent("config.yaml"))
    let worker = directory.appendingPathComponent("worker.py")
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    guard files.isExecutableFile(atPath: python.path) else { return }
    let config = DiarizationConfiguration(pythonExecutable: python, modelDirectory: directory, workerScriptURL: worker, timeoutSeconds: 1)
    let audio = directory.appendingPathComponent("test.wav")
    try Data("import time\ntime.sleep(30)\n".utf8).write(to: worker)
    await #expect(throws: LocalDiarizationError.timedOut) {
        try await LocalSpeakerDiarizer().diarize(audioURL: audio, configuration: config)
    }
    try Data("print('{\"schemaVersion\":1,\"intervals\":[{\"startSeconds\":0,\"endSeconds\":1,\"speakerID\":\"S1\"}]}')\n".utf8).write(to: worker)
    let intervals = try await LocalSpeakerDiarizer().diarize(audioURL: audio, configuration: config)
    #expect(intervals == [SpeakerInterval(startSeconds: 0, endSeconds: 1, speakerID: "S1")])
}
