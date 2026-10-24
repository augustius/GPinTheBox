import Testing
import Foundation
@testable import Records

@Test func questionsMatchSpecByteForByte() {
    #expect(KioskQuestions.all.map(\.text) == [
        "Full name", "Medicare or insurance ID", "Date of birth",
        "What is the main reason for your visit today?", "When did it start?", "Describe your symptoms",
        "Are you currently taking any medications? Please list them", "Do you have any allergies?",
        "Do you have any ongoing medical conditions?", "Is there anything else you'd like the doctor to know?"])
    #expect(KioskQuestions.all.map(\.isRequired) == [true, true, true] + Array(repeating: false, count: 7))
    #expect(KioskQuestions.all.map(\.id) == Array(0..<10))
    #expect(KioskQuestions.dateOfBirth.kind == .dateOfBirth && KioskQuestions.identifier.id == 1)
}
@Test func responseWireFormat() throws {
    let e = JSONEncoder(); e.outputFormatting = .sortedKeys
    #expect(String(decoding: try e.encode(KioskResponse.ok), as: UTF8.self) == #"{"status":"ok"}"#)
    #expect(String(decoding: try e.encode(KioskResponse.error(message: "No")), as: UTF8.self) == #"{"message":"No","status":"error"}"#)
    #expect(try JSONDecoder().decode(KioskResponse.self, from: Data(#"{"status":"error","message":"x"}"#.utf8)) == .error(message: "x"))
}
@Test func requestRoundTripsWithQAKeys() throws {
    let r = KioskRequest(submissionID: UUID(), answers: [.init(q: "Full name", a: "Jane Demo")])
    let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
    #expect(json.contains(#""q":"Full name""#) && json.contains(#""a":"Jane Demo""#))
    #expect(try JSONDecoder().decode(KioskRequest.self, from: Data(json.utf8)) == r)
}
@Test func framingRoundTripsAcrossChunks() throws {
    let body = Data("{\"status\":\"ok\"}".utf8)
    let framed = try KioskFraming.frame(body)
    #expect(framed.prefix(4) == Data([0, 0, 0, UInt8(body.count)]))
    var decoder = KioskFrameDecoder()
    #expect(try decoder.append(framed.prefix(3)) == nil)
    #expect(try decoder.append(framed.dropFirst(3).prefix(5)) == nil)
    #expect(try decoder.append(framed.dropFirst(8)) == body)
}
@Test func framingRejectsOversizeFromHeaderAlone() throws {
    var decoder = KioskFrameDecoder(maxBytes: 10)
    #expect(throws: KioskFramingError.tooLarge(11)) { try decoder.append(Data([0, 0, 0, 11])) }
    #expect(throws: KioskFramingError.tooLarge(KioskService.maxMessageBytes + 1)) {
        try KioskFraming.frame(Data(count: KioskService.maxMessageBytes + 1))
    }
}
@Test func dobValidation() {
    let now = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
    #expect(KioskDate.isValidPastDOB("1980-05-01", now: now))
    for bad in ["1980-02-30", "2999-01-01", "1980-5-1", "01/05/1980", ""] { #expect(!KioskDate.isValidPastDOB(bad, now: now)) }
}
