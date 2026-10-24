import Foundation

public enum KioskFramingError: Error, Equatable { case tooLarge(Int) }

public enum KioskFraming {
    public static func frame(_ body: Data) throws -> Data {
        guard body.count <= KioskService.maxMessageBytes else { throw KioskFramingError.tooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }
}

public struct KioskFrameDecoder: Sendable {
    private let maxBytes: Int
    private var buffer = Data()

    public init(maxBytes: Int = KioskService.maxMessageBytes) { self.maxBytes = maxBytes }

    public mutating func append(_ data: Data) throws -> Data? {
        buffer.append(data)
        guard buffer.count >= 4 else { return nil }
        let header = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard header <= maxBytes else { throw KioskFramingError.tooLarge(header) }
        guard buffer.count >= 4 + header else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(header))
        buffer = Data(buffer.dropFirst(4 + header))
        return body
    }
}
