import Foundation

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct CasualLines: Sendable {
    private var rng: SplitMix64
    private var lastUsed: [Int: String] = [:]
    private var lastAck: String?

    public init(seed: UInt64) { rng = SplitMix64(state: seed) }

    public mutating func ask(_ q: KioskQuestion, attempt: Int, name: String?, opening: Bool) -> String {
        let bank = attempt == 0 ? Self.firstAsk : Self.reAsk
        let key = q.id * 2 + (attempt == 0 ? 0 : 1)
        let line = Self.pick(bank[q.id], name: name, rng: &rng, last: &lastUsed[key])
        return (opening ? Self.openingPrefix : "") + line
    }

    public mutating func acknowledgement(name: String?) -> String {
        Self.pick(Self.acknowledgements, name: name, rng: &rng, last: &lastAck)
    }

    private static func pick(_ variants: [String], name: String?, rng: inout SplitMix64, last: inout String?) -> String {
        let eligible = variants.filter { name != nil || !$0.contains("{name}") }
        let fresh = eligible.filter { $0 != last }
        let chosen = (fresh.isEmpty ? eligible : fresh).randomElement(using: &rng) ?? ""
        last = chosen
        return chosen.replacingOccurrences(of: "{name}", with: name ?? "")
    }

    public static func cantProceed(_ q: KioskQuestion) -> String {
        let field = switch q.kind {
        case .fullName: "name"
        case .identifier: "Medicare or insurance ID"
        case .dateOfBirth: "date of birth"
        case .freeText: q.text
        }
        return "Sorry, we can't proceed without your \(field). Please see reception — they can help."
    }

    public static func spoken(_ line: String) -> String {
        var s = String.UnicodeScalarView()
        for u in line.unicodeScalars where !(u.properties.isEmojiPresentation || (u.properties.isEmoji && !u.isASCII)) { s.append(u) }
        var out = String(s)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    public static func firstName(from fullName: String) -> String? {
        fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    static let openingPrefix = "Hey! 👋 Thanks for coming in. "

    static let acknowledgements = [
        "Got it.", "Perfect.", "Thanks, {name}.", "Great, thanks.", "Lovely, thanks.", "Cheers, {name}.", "No worries, thanks.",
    ]

    static let firstAsk: [[String]] = [
        ["What's your full name?", "First up, can I grab your full name?", "Let's start with your full name. What is it?"],
        ["What's your Medicare or insurance ID?", "Could you give me your Medicare or insurance ID?", "Next, {name}, what's your Medicare or insurance ID?", "Can I get your Medicare or insurance ID?"],
        ["What's your date of birth? Any format is fine.", "And your date of birth? Just say it however you like.", "Thanks, {name}. When were you born? Any format works."],
        ["What brings you in today?", "So {name}, what's the main reason for your visit?", "What's the main reason you're here today?"],
        ["When did it start?", "Roughly when did this begin?", "How long ago did it start, {name}?"],
        ["Can you describe your symptoms?", "What symptoms have you noticed?", "Tell me about your symptoms, {name}, in your own words."],
        ["Are you taking any medications at the moment? Feel free to list them.", "Any medications you're on right now?", "{name}, are you currently taking any medications?"],
        ["Do you have any allergies?", "Any allergies I can note down for the doctor?", "Have you got any allergies, {name}?"],
        ["Do you have any ongoing medical conditions?", "Any ongoing conditions you live with?", "{name}, do you have any long-term medical conditions?"],
        ["Anything else you'd like the doctor to know?", "Is there anything else to pass on to the doctor?", "Last one, {name}. Anything else you'd like the doctor to know?"],
    ]

    static let reAsk: [[String]] = [
        ["No worries, I just need your full name to find your file. What is it?", "Sorry, could I get your full name again? It helps us match you up."],
        ["No worries, I just need your Medicare or insurance ID to find your record. What is it?", "Could you give me your Medicare or insurance ID once more? It's how we check you in."],
        ["No worries, I just need your date of birth to find your file. What is it?", "Sorry, {name}, could you give me your date of birth again? Any format is fine."],
        ["Just so I've got it right, what's the main reason for your visit?", "No stress. In a few words, what brings you in today?"],
        ["No worries, roughly when did it start? A rough guess is fine.", "Could you tell me again when it began? Days, weeks, whenever it was."],
        ["No stress, what symptoms have you noticed? Just in your own words.", "Could you describe your symptoms once more, {name}? A few words is fine."],
        ["Just checking, are you taking any medications right now?", "Could you let me know about any medications again? Even just a name helps."],
        ["Just to be sure, do you have any allergies?", "Sorry, {name}, could you tell me about any allergies once more?"],
        ["Just checking, do you have any ongoing medical conditions?", "Could you let me know about any long-term conditions again?"],
        ["Is there anything else you'd like the doctor to know? Totally fine if not.", "No worries, anything else to pass on to the doctor?"],
    ]
}

public enum ChipLabel {
    private static let labels = ["Name", "ID", "Born", "Reason", "Started", "Symptoms", "Medications", "Allergies", "Conditions", "Other"]
    public static func text(for q: KioskQuestion) -> String { labels[q.id] }
}
