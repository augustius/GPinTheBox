import Testing
@testable import KioskKit

private let acks = CasualLines.acknowledgements.map { $0.replacingOccurrences(of: "{name}", with: "Jane") }

@MainActor @Test func voiceRepliesAreLoggedRawWithChips() async {
    let (c, speaker) = makeController([[.final("Jane Demo")], [.final("demo 001")]])
    c.start(); await eventually { c.flow.phase == .asking(2) && c.messages.count == 5 }
    #expect(c.messages.map(\.role) == [.kiosk, .patient, .kiosk, .patient, .kiosk])
    #expect(c.messages[1].text == "Jane Demo" && c.messages[1].picked == [0: "Jane Demo"])
    #expect(c.messages[3].text == "demo 001" && c.messages[3].picked == [1: "DEMO001"])
    #expect(c.messages.filter { $0.role == .kiosk }.allSatisfy { $0.picked.isEmpty })
    #expect(c.messages.map(\.id) == c.messages.map(\.id).sorted() && Set(c.messages.map(\.id)).count == c.messages.count)
    await eventually { speaker.spoken.count == 3 }
    #expect(speaker.spoken == c.messages.filter { $0.role == .kiosk }.map { CasualLines.spoken($0.text) })
}
@MainActor @Test func acknowledgementOnlyWhenSomethingWasRecorded() async {
    let (c, _) = makeController([], model: FakeAnswerModel(isAvailable: false)); c.inputMode = .typing; c.start()
    #expect(!acks.contains { c.messages[0].text.hasPrefix($0) })
    c.submitTyped("Jane Demo"); await eventually { c.flow.phase == .asking(1) && c.messages.count == 3 }
    #expect(acks.contains { c.messages[2].text.hasPrefix($0 + " ") })
    c.submitTyped("pass"); await eventually { c.flow.askCounts[1] == 2 }
    #expect(c.messages[3].picked.isEmpty && !acks.contains { c.messages[4].text.hasPrefix($0) })
}
@MainActor @Test func latestKioskMessageIDTracksNewestLine() async {
    let (c, _) = makeController([], model: FakeAnswerModel(delay: .milliseconds(50))); c.inputMode = .typing
    #expect(c.latestKioskMessageID == nil)
    c.start(); let first = c.messages[0].id; #expect(c.latestKioskMessageID == first)
    c.submitTyped("Jane Demo"); #expect(c.latestKioskMessageID == first && c.messages.last?.role == .patient)
    await eventually { c.messages.count == 3 }
    #expect(c.latestKioskMessageID == c.messages[2].id)
}
@MainActor @Test func speakAgainLogsNothing() async {
    let (c, speaker) = makeController([]); c.start()
    await eventually { c.isListening }
    c.speakAgain(); await eventually { speaker.spoken.count == 2 && c.isListening }
    #expect(speaker.spoken[0] == speaker.spoken[1] && c.messages.count == 1 && c.flow.askCounts[0] == 1)
}
@MainActor @Test func resetClearsChat() async {
    let (c, _) = makeController([[.final("Jane Demo")]])
    c.start(); await eventually { c.messages.count >= 2 }
    c.reset()
    #expect(c.messages.isEmpty && c.latestKioskMessageID == nil)
}
