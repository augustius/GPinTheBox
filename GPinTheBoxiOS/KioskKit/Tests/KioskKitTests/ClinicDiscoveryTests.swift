import Testing
@testable import KioskKit

@Test func clinicSelection() {
    #expect(ClinicSelection.choose(available: [], remembered: "A") == .none)
    #expect(ClinicSelection.choose(available: ["Front Desk"], remembered: nil) == .connected("Front Desk"))
    #expect(ClinicSelection.choose(available: ["B", "A"], remembered: "A") == .connected("A"))
    #expect(ClinicSelection.choose(available: ["B", "A"], remembered: "Gone") == .needsPicker(["A", "B"]))
}
