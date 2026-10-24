import Foundation
import Speech
import CoreMedia

public struct TranscriptionSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public init(id: UUID = UUID(), text: String, startSeconds: Double, endSeconds: Double) {
        self.id = id; self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
}

public struct TranscriptionOutput: Codable, Sendable, Equatable {
    public var segments: [TranscriptionSegment]
    public var engine: String
    public var text: String { segments.map(\.text).joined(separator: " ") }
    public init(segments: [TranscriptionSegment], engine: String) { self.segments = segments; self.engine = engine }
}

/// Preserve Apple's word/run timing rather than estimating timing from text length.
func timedSegments(text: AttributedString, fallback: CMTimeRange) -> [TranscriptionSegment] {
    var segments: [TranscriptionSegment] = []
    var needsResultTiming = false
    for run in text.runs {
        let value = String(text[run.range].characters)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        if let range = run.audioTimeRange {
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite, start >= 0, end >= start else { needsResultTiming = true; continue }
            segments.append(.init(text: value.trimmingCharacters(in: .whitespacesAndNewlines), startSeconds: start, endSeconds: end))
        } else if !segments.isEmpty && value.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) {
            segments[segments.count - 1].text += value
        } else {
            // Never lose words that Apple emitted without individual timing. Retain the
            // complete result with its coarser interval; downstream alignment can flag it.
            needsResultTiming = true
        }
    }
    if segments.isEmpty || needsResultTiming {
        segments = []
        let value = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = fallback.start.seconds, end = fallback.end.seconds
        if !value.isEmpty, start.isFinite, end.isFinite, start >= 0, end >= start {
            segments.append(.init(text: value, startSeconds: start, endSeconds: end))
        }
    }
    return segments
}

public enum SpeechGlossaryError: Error, LocalizedError {
    case tooManyTerms, termTooLong
    public var errorDescription: String? {
        switch self {
        case .tooManyTerms: "Use no more than 100 glossary terms."
        case .termTooLong: "Keep each glossary term under 100 characters; use short words or phrases."
        }
    }
}

/// Local vocabulary hints only. Saving corrections never silently adds terms.
public struct SpeechGlossaryStore: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appendingPathComponent("GPInTheBox", isDirectory: true).appendingPathComponent("speech-glossary.json")
    }
    public static func normalize(_ terms: [String]) throws -> [String] {
        var seen = Set<String>()
        let normalized = try terms.compactMap { value -> String? in
            let term = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty else { return nil }
            guard term.count <= 100 else { throw SpeechGlossaryError.termTooLong }
            guard seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
        guard normalized.count <= 100 else { throw SpeechGlossaryError.tooManyTerms }
        return normalized
    }
    public func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.normalize(JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }
    public func save(_ terms: [String]) throws {
        let normalized = try Self.normalize(terms)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(normalized).write(to: url, options: .atomic)
    }
}
