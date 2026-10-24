import Foundation
import Speech
import CoreMedia
import Testing
@testable import ConsultationAudio

@Test func glossaryNormalizesAndLimitsHints() throws {
    #expect(try SpeechGlossaryStore.normalize([" metformin ", "METFORMIN", "", "blood   pressure"]) == ["metformin", "blood pressure"])
    #expect(throws: SpeechGlossaryError.self) { try SpeechGlossaryStore.normalize((0...100).map { "term \($0)" }) }
    #expect(throws: SpeechGlossaryError.self) { try SpeechGlossaryStore.normalize([String(repeating: "a", count: 101)]) }
}

@Test func glossaryPersistsWithoutOverwritingOnInvalidInput() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("glossary.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SpeechGlossaryStore(url: url)
    #expect(try store.load().isEmpty)
    try store.save(["metformin", "penicillin"])
    #expect(try SpeechGlossaryStore(url: url).load() == ["metformin", "penicillin"])
    #expect(throws: SpeechGlossaryError.self) { try store.save([String(repeating: "a", count: 101)]) }
    #expect(try store.load().count == 2)
}

@Test func preservesWordTimestampsAndResultFallback() {
    var first = AttributedString("Hello")
    first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 100), duration: CMTime(seconds: 0.5, preferredTimescale: 100))
    var second = AttributedString(" world")
    second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 100), duration: CMTime(seconds: 0.7, preferredTimescale: 100))
    let fallback = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 100))
    let result = timedSegments(text: first + second, fallback: fallback)
    #expect(result.map(\.text) == ["Hello", "world"])
    #expect(result.map(\.startSeconds) == [1, 2])
    #expect(result.map(\.endSeconds) == [1.5, 2.7])
    let partialTiming = timedSegments(text: AttributedString("Important prefix ") + first, fallback: fallback)
    #expect(partialTiming.count == 1 && partialTiming[0].text == "Important prefix Hello")
    let untimed = timedSegments(text: AttributedString("Hello world"), fallback: fallback)
    #expect(untimed.count == 1 && untimed[0].endSeconds == 4)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GP_RUN_GLOSSARY_PROBE"] == "1"))
func actualDeviceGlossarySyntheticAudio() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "The patient reports taking metformin. The patient has a penicillin allergy."]
    try say.run(); say.waitUntilExit()
    #expect(say.terminationStatus == 0)
    for locale in ["en-AU", "en-US"] {
        let output = try await OnDeviceTranscriber().transcribeDetailed(url: url, localeIdentifier: locale, glossary: ["metformin", "penicillin"])
        print("Glossary probe \(locale): \(output.text), segments=\(output.segments.count), engine=\(output.engine)")
        #expect(!output.text.isEmpty && !output.segments.isEmpty)
        #expect(output.engine.contains("DictationTranscriber"))
        #expect(output.segments.allSatisfy { $0.startSeconds.isFinite && $0.endSeconds >= $0.startSeconds })
    }
}
