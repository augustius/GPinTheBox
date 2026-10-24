import Foundation

public enum AnswerFormatting {
    public static func readableDOB(_ iso: String) -> String? {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd"; parser.isLenient = false
        guard let date = parser.date(from: iso) else { return nil }
        let out = DateFormatter(); out.locale = Locale(identifier: "en_AU")
        out.timeZone = TimeZone(secondsFromGMT: 0); out.dateFormat = "d MMMM yyyy"
        return out.string(from: date)
    }

    public static func normaliseIdentifier(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "/" }
    }
}
