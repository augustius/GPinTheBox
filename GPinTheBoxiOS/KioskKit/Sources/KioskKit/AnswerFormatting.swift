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

    /// Day-first (en-AU) parse of a typed or spoken date into `yyyy-MM-dd`; 4-digit years and real dates only.
    public static func isoDOB(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacing(#/(\d{1,2})(?:st|nd|rd|th)\b/#) { String($0.1) }
            .replacing(#/\s+/#, with: " ").replacing(" of ", with: " ")
        let ymd: (Int, Int, Int)?
        if let r = s.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#) { ymd = (Int(r.1)!, Int(r.2)!, Int(r.3)!) }
        else if let r = s.wholeMatch(of: #/(\d{1,2})([\/.\- ])(\d{1,2})([\/.\- ])(\d{4})/#), r.2 == r.4 {
            ymd = (Int(r.5)!, Int(r.3)!, Int(r.1)!)
        } else if let r = s.wholeMatch(of: #/(\d{1,2}) ([a-z]+)\.?,? (\d{4})/#), let m = month(r.2) { ymd = (Int(r.3)!, m, Int(r.1)!) }
        else if let r = s.wholeMatch(of: #/([a-z]+)\.? (\d{1,2}),? (\d{4})/#), let m = month(r.1) { ymd = (Int(r.3)!, m, Int(r.2)!) }
        else { ymd = nil }
        guard let (y, m, d) = ymd else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard y >= 1, DateComponents(year: y, month: m, day: d).isValidDate(in: calendar) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func month(_ name: Substring) -> Int? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if name == "sept" { return 9 }
        return (f.monthSymbols.firstIndex { $0.lowercased() == name } ?? f.shortMonthSymbols.firstIndex { $0.lowercased() == name }).map { $0 + 1 }
    }

    public static func normaliseIdentifier(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "/" }
    }
}
