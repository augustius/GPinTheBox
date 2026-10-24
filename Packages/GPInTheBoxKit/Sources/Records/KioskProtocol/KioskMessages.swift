// Kiosk wire contract. Duplicated in GPinTheBoxiOS/KioskKit/Sources/KioskKit/Protocol and Packages/GPInTheBoxKit/Sources/Records/KioskProtocol — keep both copies identical.
import Foundation

public struct KioskAnswer: Codable, Hashable, Sendable {
    public var q: String
    public var a: String
    public init(q: String, a: String) { self.q = q; self.a = a }
}

public struct KioskRequest: Codable, Hashable, Sendable {
    public var submissionID: UUID
    public var answers: [KioskAnswer]
    public init(submissionID: UUID, answers: [KioskAnswer]) { self.submissionID = submissionID; self.answers = answers }
}

public enum KioskResponse: Codable, Equatable, Sendable {
    case ok
    case error(message: String)

    private enum CodingKeys: String, CodingKey { case status, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .status) {
        case "ok": self = .ok
        case "error": self = .error(message: try c.decode(String.self, forKey: .message))
        case let other: throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unknown status \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok: try c.encode("ok", forKey: .status)
        case .error(let message): try c.encode("error", forKey: .status); try c.encode(message, forKey: .message)
        }
    }
}

public enum KioskService {
    public static let type = "_steadycare._tcp"
    public static let maxMessageBytes = 256 * 1024
}
