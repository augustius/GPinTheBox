import Testing
@testable import KioskKit

@Test func everyQuestionHasEnoughVariants() {
    for q in KioskQuestions.all {
        #expect(CasualLines.firstAsk[q.id].count >= 3); #expect(CasualLines.reAsk[q.id].count >= 2)
    }
}
@Test func linesGiveNoAdvice() {
    let deny = ["should", "recommend", "don't worry", "it's probably", "normal", "diagnos", "nothing serious"]
    for line in (CasualLines.firstAsk + CasualLines.reAsk).flatMap({ $0 }) {
        for word in deny { #expect(!line.lowercased().contains(word), "\(line)") }
    }
}
@Test func rotationNeverRepeatsBackToBack() {
    var lines = CasualLines(seed: 7); let q = KioskQuestions.all[3]
    var last = ""
    for _ in 0..<20 { let l = lines.ask(q, attempt: 0, name: "Jane", opening: false); #expect(l != last); last = l }
}
@Test func seededRotationIsDeterministic() {
    var a = CasualLines(seed: 42), b = CasualLines(seed: 42)
    for q in KioskQuestions.all { #expect(a.ask(q, attempt: 1, name: nil, opening: false) == b.ask(q, attempt: 1, name: nil, opening: false)) }
}
@Test func nameIsSubstitutedOnlyWhenKnown() {
    var lines = CasualLines(seed: 1)
    for _ in 0..<30 {
        #expect(!lines.ask(KioskQuestions.all[4], attempt: 0, name: nil, opening: false).contains("{name}"))
        #expect(!lines.acknowledgement(name: nil).contains("{name}"))
    }
    #expect(CasualLines.firstName(from: "  Jane Demo ") == "Jane"); #expect(CasualLines.firstName(from: " ") == nil)
}
@Test func openingAndCantProceedCopy() {
    var lines = CasualLines(seed: 3)
    #expect(lines.ask(KioskQuestions.fullName, attempt: 0, name: nil, opening: true).hasPrefix("Hey! 👋 Thanks for coming in. "))
    #expect(CasualLines.cantProceed(KioskQuestions.identifier) == "Sorry, we can't proceed without your Medicare or insurance ID. Please see reception — they can help.")
    #expect(CasualLines.cantProceed(KioskQuestions.dateOfBirth).contains("without your date of birth."))
    #expect(CasualLines.spoken("Hey! 👋 Thanks for coming in.") == "Hey! Thanks for coming in.")
    #expect(KioskQuestions.all.map(ChipLabel.text(for:)) == ["Name", "ID", "Born", "Reason", "Started", "Symptoms", "Medications", "Allergies", "Conditions", "Other"])
}
@Test func acknowledgementsAndReAsksAreNeutral() {
    let deny = ["should", "recommend", "don't worry", "it's probably", "normal", "diagnos", "nothing serious", "no worries", "lovely", "perfect", "great",
                "no stress", "don't stress"]
    for line in CasualLines.acknowledgements + CasualLines.reAsk.flatMap({ $0 }) {
        for word in deny { #expect(!line.lowercased().contains(word), "\(line)") }
    }
}
