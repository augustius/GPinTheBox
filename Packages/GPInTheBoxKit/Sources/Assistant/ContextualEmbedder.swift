import Foundation
import NaturalLanguage

public actor ContextualEmbedder: Embedder {
    private let embedding: NLContextualEmbedding
    private init(embedding: NLContextualEmbedding) { self.embedding = embedding }
    public static func make() async -> ContextualEmbedder? {
        // Keep the non-Sendable model confined to the actor throughout loading and use.
        let value = ContextualEmbedder()
        return await value?.prepare() == true ? value : nil
    }
    private init?() {
        guard let model = NLContextualEmbedding(language: .english) else { return nil }
        embedding = model
    }
    private func prepare() async -> Bool {
        do {
            if !embedding.hasAvailableAssets {
                let result = try await embedding.requestAssets()
                guard result == .available else { return false }
            }
            try embedding.load()
            return true
        } catch { return false }
    }
    public func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let result = try embedding.embeddingResult(for: text, language: .english)
        var sum: [Double] = [], count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            if sum.isEmpty { sum = Array(repeating: 0, count: vector.count) }
            for index in vector.indices { sum[index] += vector[index] }
            count += 1
            return true
        }
        return sum.map { Float($0 / Double(max(1, count))) }
    }
}
