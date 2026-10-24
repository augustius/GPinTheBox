import Foundation
import Testing
@testable import ConsultationAudio

private struct ExpectedVoiceTurn: Decodable {
    let role: String
    let startSeconds: Double
    let endSeconds: Double
}

private struct VoiceTurnMeasurement: Codable {
    let expectedRole: String
    let startSeconds: Double
    let endSeconds: Double
    let dominantSpeaker: String?
    let speechCoverage: Double
    let dominantFraction: Double
}

/// This is a synthetic turn-stability check, not a clinical accuracy benchmark or formal DER.
private func measure(turns: [ExpectedVoiceTurn], intervals: [SpeakerInterval]) -> [VoiceTurnMeasurement] {
    turns.map { turn in
        var seconds: [String: Double] = [:]
        for segment in intervals {
            let overlap = max(0, min(turn.endSeconds, segment.endSeconds) - max(turn.startSeconds, segment.startSeconds))
            seconds[segment.speakerID, default: 0] += overlap
        }
        let dominant = seconds.filter { $0.value > 0 }.max { $0.value < $1.value }
        let total = seconds.values.reduce(0, +)
        return VoiceTurnMeasurement(expectedRole: turn.role, startSeconds: turn.startSeconds, endSeconds: turn.endSeconds,
                                    dominantSpeaker: dominant?.key, speechCoverage: total / (turn.endSeconds - turn.startSeconds),
                                    dominantFraction: total > 0 ? (dominant?.value ?? 0) / total : 0)
    }
}

@Test func syntheticTurnMeasurementRecognizesStableAnonymousSpeakers() throws {
    let turns = [ExpectedVoiceTurn(role: "Doctor", startSeconds: 0, endSeconds: 5),
                 ExpectedVoiceTurn(role: "Patient", startSeconds: 6, endSeconds: 10)]
    let intervals = [SpeakerInterval(startSeconds: 1, endSeconds: 4, speakerID: "speaker_a"),
                     SpeakerInterval(startSeconds: 6, endSeconds: 10, speakerID: "speaker_b")]
    let result = measure(turns: turns, intervals: intervals)
    #expect(result.map(\.dominantSpeaker) == ["speaker_a", "speaker_b"])
    #expect(result[0].speechCoverage == 0.6 && result[0].dominantFraction == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GP_RUN_NATIVE_SPEAKER_PROBE"] == "1"))
func actualNativeTwoVoiceConversationProbe() async throws {
    let environment = ProcessInfo.processInfo.environment
    let fixturePath = try #require(environment["GP_NATIVE_FIXTURE_DIR"])
    let cachePath = try #require(environment["GP_NATIVE_MODEL_DIR"])
    let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
    let audio = fixture.appendingPathComponent("conversation.caf")
    let expected = try JSONDecoder().decode([ExpectedVoiceTurn].self, from: Data(contentsOf: fixture.appendingPathComponent("expected-turns.json")))
    let diarizer = NativeSpeakerDiarizer(modelDirectory: URL(fileURLWithPath: cachePath, isDirectory: true))
    let downloadStarted = Date()
    try await diarizer.prepareModels()
    print("Native speaker model preparation seconds: \(Date().timeIntervalSince(downloadStarted))")
    #expect(diarizer.isModelInstalled)
    let inferenceStarted = Date()
    let intervals = try await diarizer.diarize(audioURL: audio)
    print("Native diarization inference seconds: \(Date().timeIntervalSince(inferenceStarted))")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print("Native intervals: \(String(decoding: try encoder.encode(intervals), as: UTF8.self))")
    let measurements = measure(turns: expected, intervals: intervals)
    print("Synthetic turn measurements: \(String(decoding: try encoder.encode(measurements), as: UTF8.self))")
    #expect(!intervals.isEmpty)
    #expect(measurements.count == 4)
    let labels = measurements.map(\.dominantSpeaker)
    #expect(labels.allSatisfy { $0 != nil })
    #expect(labels[0] == labels[2])
    #expect(labels[1] == labels[3])
    #expect(labels[0] != labels[1])
    #expect(measurements.allSatisfy { $0.speechCoverage >= 0.5 && $0.dominantFraction >= 0.8 })
    let transcript = try await OnDeviceTranscriber().transcribeDetailed(url: audio, localeIdentifier: "en-AU", glossary: ["metformin", "penicillin", "blood pressure"])
    var assigned = 0, evaluable = 0, correct = 0
    var report: [String] = []
    for segment in transcript.segments {
        let speaker = SpeakerAlignment.speakerID(startSeconds: segment.startSeconds, endSeconds: segment.endSeconds, intervals: intervals)
        if speaker != nil { assigned += 1 }
        if let index = expected.firstIndex(where: { segment.startSeconds >= $0.startSeconds && segment.endSeconds <= $0.endSeconds }), let speaker {
            evaluable += 1
            if speaker == measurements[index].dominantSpeaker { correct += 1 }
        }
        report.append("\(segment.startSeconds)-\(segment.endSeconds) [\(speaker ?? "Unassigned")]: \(segment.text)")
    }
    print("Native+glossary transcript: \(transcript.text)")
    print("Native+glossary timed segments: \(transcript.segments.count), assigned: \(assigned), uncertain: \(transcript.segments.count - assigned)")
    #expect(!transcript.text.isEmpty && !transcript.segments.isEmpty)
    #expect(transcript.text.lowercased().contains("metformin") && transcript.text.lowercased().contains("penicillin"))
    print("Native+glossary aligned speaker agreement: \(correct)/\(evaluable) evaluable timed segments")
    try report.joined(separator: "\n").write(to: fixture.appendingPathComponent("native-probe-conversation.txt"), atomically: true, encoding: .utf8)
    try encoder.encode(measurements).write(to: fixture.appendingPathComponent("native-probe-measurements.json"), options: .atomic)
    #expect(assigned > 0 && evaluable > 0)
    #expect(Double(correct) / Double(max(1, evaluable)) >= 0.8)
}
