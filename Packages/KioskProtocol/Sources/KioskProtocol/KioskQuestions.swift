import Foundation

public enum KioskQuestionKind: String, Sendable { case fullName, identifier, dateOfBirth, freeText }

public struct KioskQuestion: Sendable, Hashable, Identifiable {
    public let id: Int
    public let text: String
    public let kind: KioskQuestionKind
    public let isRequired: Bool
}

public enum KioskQuestions {
    private static let table: [(String, KioskQuestionKind, Bool)] = [
        ("Full name", .fullName, true),
        ("Medicare or insurance ID", .identifier, true),
        ("Date of birth", .dateOfBirth, true),
        ("What is the main reason for your visit today?", .freeText, false),
        ("When did it start?", .freeText, false),
        ("Describe your symptoms", .freeText, false),
        ("Are you currently taking any medications? Please list them", .freeText, false),
        ("Do you have any allergies?", .freeText, false),
        ("Do you have any ongoing medical conditions?", .freeText, false),
        ("Is there anything else you'd like the doctor to know?", .freeText, false),
    ]
    public static let all: [KioskQuestion] = table.enumerated().map {
        KioskQuestion(id: $0.offset, text: $0.element.0, kind: $0.element.1, isRequired: $0.element.2)
    }

    public static var fullName: KioskQuestion { all[0] }
    public static var identifier: KioskQuestion { all[1] }
    public static var dateOfBirth: KioskQuestion { all[2] }
}
