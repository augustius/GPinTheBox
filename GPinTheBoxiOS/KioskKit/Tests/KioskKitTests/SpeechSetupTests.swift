import Testing
import Foundation
@testable import KioskKit

@Test func setupPrefersAustralianEnglish() async {
    guard let (locale, isFallback) = await SpeechSetup.locale() else { return }   // no transcriber on this host
    #expect(isFallback ? locale.identifier.hasPrefix("en_US") || locale.identifier.hasPrefix("en-US") : locale.identifier.hasPrefix("en_AU") || locale.identifier.hasPrefix("en-AU"))
}

@Test func fakeListenerYieldsScriptThenWaitsForStop() async throws {
    let listener = FakeListener(script: [[.partial("chest"), .final("chest pain")]])
    var events: [ListenEvent] = []
    let collect = Task { for try await event in listener.listen() { events.append(event) }; return events }
    try await Task.sleep(for: .milliseconds(50))
    await listener.stop()
    #expect(try await collect.value == [.partial("chest"), .final("chest pain")])
    let empty = Task { var count = 0; for try await _ in listener.listen() { count += 1 }; return count }
    try await Task.sleep(for: .milliseconds(50))
    await listener.stop()
    #expect(try await empty.value == 0)
}

@MainActor @Test func fakeSpeakerRecordsSpokenText() async {
    let speaker = FakeSpeaker()
    await speaker.speak("Hello")
    #expect(speaker.spoken == ["Hello"])
}

@Test func transcriptSegmentsJoinWithOneSpace() {
    #expect(SpeechAnalyzerListener.joinTranscript("chest pain.", "It started Monday") == "chest pain. It started Monday")
    #expect(SpeechAnalyzerListener.joinTranscript("chest pain. ", "It") == "chest pain. It")
    #expect(SpeechAnalyzerListener.joinTranscript("chest", " pain") == "chest pain")
    #expect(SpeechAnalyzerListener.joinTranscript("", "Jane") == "Jane")
    #expect(SpeechAnalyzerListener.joinTranscript("Jane", "") == "Jane")
}
