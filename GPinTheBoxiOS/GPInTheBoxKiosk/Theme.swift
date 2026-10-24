import SwiftUI
import KioskKit

enum Theme {
    static let background = Color.black
    static let patientBubble = Color(hex: 0x2f2f2f)
    static let composer = Color(hex: 0x1f1f1f)
    static let voiceBlue = Color(hex: 0x3d6fd8)
    static let secondary = Color(hex: 0x8e8e8e)
    static let chip = Color(hex: 0x1c2e4f)
    static let chipText = Color(hex: 0x9ec3ff)

    /// How an answer reads on a chip or in review: a readable DOB, and "none" for answered-empty.
    static func display(_ answer: String, for q: KioskQuestion) -> String {
        if answer.isEmpty { return "none" }
        return q.kind == .dateOfBirth ? AnswerFormatting.readableDOB(answer) ?? answer : answer
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

struct EditTarget: Identifiable { let id: Int }
