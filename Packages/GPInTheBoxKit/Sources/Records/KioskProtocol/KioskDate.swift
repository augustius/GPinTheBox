// Kiosk wire contract. Duplicated in GPinTheBoxiOS/KioskKit/Sources/KioskKit/Protocol and Packages/GPInTheBoxKit/Sources/Records/KioskProtocol — keep both copies identical.
import Foundation

public enum KioskDate {
    public static func isValidPastDOB(_ value: String, now: Date = .now) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return false }
        return date <= now
    }
}
