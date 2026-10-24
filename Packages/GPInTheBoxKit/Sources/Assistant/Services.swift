import Foundation
import NaturalLanguage
import Records

public protocol Embedder: Sendable { func embed(_ text: String) async throws -> [Float] }
public struct Retriever: Sendable {
    let embedder: (any Embedder)?
    public init(embedder: (any Embedder)? = nil) { self.embedder = embedder }
    private func words(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text.lowercased()
        let lower = text.lowercased(), stop: Set<String> = ["a", "the", "is", "on", "she", "he", "it", "was", "what", "does", "of", "and", "to"]
        return Set(tokenizer.tokens(for: lower.startIndex..<lower.endIndex).map { String(lower[$0]) }).subtracting(stop)
    }
    public func topChunks(for query: String, in chunks: [Chunk], k: Int = 6) async -> [Chunk] {
        let tokens = words(query)
        var scores = chunks.map { Float(tokens.intersection(words($0.text)).count) / Float(max(1, tokens.count)) }
        if let embedder {
            do {
                let q = try await embedder.embed(query)
                var semantic: [Float] = []
                for chunk in chunks {
                    try Task.checkCancellation()
                    let v = try await embedder.embed(chunk.text)
                    guard q.count == v.count, !q.isEmpty, q.allSatisfy(\.isFinite), v.allSatisfy(\.isFinite) else { throw AssistantError.failed("Invalid embedding") }
                    let dot = zip(q, v).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    let norm = sqrt(q.reduce(0) { $0 + $1 * $1 } * v.reduce(0) { $0 + $1 * $1 })
                    semantic.append(norm > 0 ? dot / norm : 0)
                }
                scores = zip(scores, semantic).map { 0.5 * $0 + 0.5 * $1 }
            } catch { /* Entire query falls back to keyword scores. */ }
        }
        return chunks.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }.prefix(max(0, k)).map { chunks[$0] }
    }
}
public enum ContextBudget {
    // Conservative byte ceiling; adapter additionally counts actual tokens where supported.
    public static let inputBytes = 4800
    public static func split(_ chunks: [Chunk], maxBytes: Int) -> [Chunk] {
        let limit = max(32, maxBytes - 160)
        return chunks.flatMap { chunk -> [Chunk] in
            guard chunk.text.utf8.count > limit else { return [chunk] }
            var parts: [String] = [], part = "", bytes = 0
            for scalar in chunk.text.unicodeScalars {
                let count = String(scalar).utf8.count
                if bytes + count > limit, !part.isEmpty { parts.append(part); part = ""; bytes = 0 }
                part.unicodeScalars.append(scalar); bytes += count
            }
            if !part.isEmpty { parts.append(part) }
            return parts.enumerated().map { index, text in
                Chunk(id: "\(chunk.id)-P\(index + 1)", visitID: chunk.visitID, date: chunk.date, source: chunk.source, text: text)
            }
        }
    }
    public static func batches(_ chunks: [Chunk], budget: Int) -> [[Chunk]] {
        var batches: [[Chunk]] = [], batch: [Chunk] = []
        for chunk in chunks {
            if !batch.isEmpty && AssistantPrompts.excerpts(batch + [chunk]).utf8.count > budget { batches.append(batch); batch = [] }
            batch.append(chunk)
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
    public static func check(_ model: any AssistantModel) throws {
        try Task.checkCancellation()
        if case .unavailable(let reason) = model.availability() { throw AssistantError.unavailable(reason) }
    }
}
public struct QAService: Sendable {
    let model: any AssistantModel; let retriever: Retriever
    public init(model: any AssistantModel, retriever: Retriever = Retriever()) { self.model = model; self.retriever = retriever }
    public func answer(_ question: String, patient: PatientSnapshot) async throws -> CitedText {
        try ContextBudget.check(model)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 1000 else { throw AssistantError.failed("Use a question of at most 1,000 bytes") }
        var budget = ContextBudget.inputBytes - question.utf8.count - 100
        for attempt in 0...3 {
            let split = ContextBudget.split(RecordChunker.chunks(for: patient), maxBytes: max(256, budget / 3))
            let ranked = await retriever.topChunks(for: question, in: split)
            try Task.checkCancellation()
            var selected: [Chunk] = []
            for chunk in ranked where AssistantPrompts.excerpts(selected + [chunk]).utf8.count <= budget { selected.append(chunk) }
            guard !selected.isEmpty else { return CitedText(claims: []) }
            do {
                let response = try await model.respond(instructions: AssistantPrompts.baseInstructions, prompt: "Record excerpts:\n\(AssistantPrompts.excerpts(selected))\nQuestion (untrusted): \(question)")
                try Task.checkCancellation()
                return try CitationValidator.validate(response, chunks: selected)
            } catch AssistantError.contextOverflow {
                if attempt == 3 { throw AssistantError.contextOverflow }; budget /= 2
            }
        }
        throw AssistantError.contextOverflow
    }
}
public struct FollowUpResult: Sendable, Identifiable {
    public enum Status: Sendable { case mentioned([Chunk]), notMentioned }
    public var id = UUID(); public var item: String; public var noteSource: Chunk; public var status: Status
}
public struct PatientSummary: Sendable {
    public var followUps: [FollowUpResult]; public var overview: CitedText; public var incompleteFollowUps: Bool
}
public struct Summarizer: Sendable {
    let model: any AssistantModel; let budgetCharacters: Int
    public init(model: any AssistantModel, budgetCharacters: Int = ContextBudget.inputBytes) { self.model = model; self.budgetCharacters = budgetCharacters }
    public func summarize(_ patient: PatientSnapshot, visitID: UUID) async throws -> PatientSummary {
        try ContextBudget.check(model)
        guard let index = patient.visits.firstIndex(where: { $0.id == visitID }) else { throw AssistantError.failed("Visit no longer exists") }
        var patient = patient; patient.visits = Array(patient.visits.prefix(index + 1))
        var budget = min(ContextBudget.inputBytes, max(256, budgetCharacters))
        let targetVisit = patient.visits[index]
        let targetLabel = "V\(index + 1)"
        let priorities = Dictionary(uniqueKeysWithValues: patient.visits.enumerated().map { ($0.element.id, $0.offset) })
        // Put the consultation being viewed first, retaining original Vn IDs and answer order.
        let orderedChunks = RecordChunker.chunks(for: patient).enumerated().sorted {
            let left = priorities[$0.element.visitID] ?? 0, right = priorities[$1.element.visitID] ?? 0
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
        let focus = "The target/current visit is \(targetLabel), dated \(targetVisit.arrivedAt.formatted(.iso8601.year().month().day())). Prioritize this visit's findings and meaningful changes from older visits. 'Today' refers ONLY to this target visit. Describe older information as historical; never present it as current. Include target-visit evidence when it is supplied. Preserve improvement, deterioration, uncertainty, and negative statements."
        var overview: CitedText?
        for attempt in 0...3 {
            do { overview = try await reduce(orderedChunks, budget: budget, focus: focus); break }
            catch AssistantError.contextOverflow { if attempt == 3 { throw AssistantError.contextOverflow }; budget = max(192, budget / 2) }
        }
        if orderedChunks.contains(where: { $0.visitID == visitID }),
           overview?.citedChunks.contains(where: { $0.visitID == visitID }) != true {
            // Do not present a historical-only summary as the current consultation.
            throw AssistantError.unsupportedEvidence
        }
        var followUps: [FollowUpResult] = [], incomplete = false
        if let previous = patient.visits.dropLast().last(where: { !$0.gpNote.isEmpty || !$0.consultationSummaries.isEmpty }) {
            let all = RecordChunker.chunks(for: patient)
            let notes = all.filter { $0.visitID == previous.id && ($0.source == .gpEntered || $0.source == .gpReviewedSummary) }
            let today = all.filter { $0.visitID == visitID && $0.source == .patientReported }
            var followUpBudget = 2400
            for attempt in 0...3 {
                do {
                    (followUps, incomplete) = try await checkFollowUps(notes: notes, today: today, budget: followUpBudget)
                    break
                } catch is CancellationError { throw CancellationError() }
                catch AssistantError.contextOverflow {
                    if attempt == 3 { incomplete = true } else { followUpBudget /= 2 }
                } catch { incomplete = true; break }
            }
        }
        try Task.checkCancellation()
        return PatientSummary(followUps: followUps, overview: overview ?? CitedText(claims: []), incompleteFollowUps: incomplete)
    }
    private func checkFollowUps(notes: [Chunk], today: [Chunk], budget: Int) async throws -> ([FollowUpResult], Bool) {
        // Never truncate a sentence: omitted oversized notes must be disclosed.
        let fittingNotes = notes.filter { AssistantPrompts.excerpts([$0]).utf8.count <= budget }
        var incomplete = fittingNotes.count != notes.count
        let noteBatches = ContextBudget.batches(fittingNotes, budget: budget)
        let todayBatches = ContextBudget.batches(ContextBudget.split(today, maxBytes: max(192, budget / 2)), budget: budget)
        if noteBatches.count > 12 || todayBatches.count > 12 { incomplete = true }
        var seen = Set<String>(), results: [FollowUpResult] = []
        for batch in noteBatches.prefix(12) {
            try Task.checkCancellation()
            let items = try await model.extractFollowUps(fromNote: batch.map(\.text).joined(separator: "\n"))
            try Task.checkCancellation()
            if items.count > 20 { incomplete = true }
            for item in items.prefix(20) {
                guard !item.item.isEmpty, item.item.utf8.count <= 600, !item.sourceSentence.isEmpty,
                      let source = batch.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == item.sourceSentence.trimmingCharacters(in: .whitespacesAndNewlines) }) else { incomplete = true; continue }
                guard seen.insert(item.sourceSentence).inserted else { continue }
                var matches: [Chunk] = []
                var itemComplete = todayBatches.count <= 12
                for excerpts in todayBatches.prefix(12) {
                    try Task.checkCancellation()
                    let judgement = try await model.judgeFollowUp(item: item.item, excerpts: AssistantPrompts.excerpts(excerpts))
                    try Task.checkCancellation()
                    guard judgement.chunkIDs.allSatisfy({ id in excerpts.contains { $0.id == id } }),
                          !judgement.mentioned || !judgement.chunkIDs.isEmpty else { incomplete = true; itemComplete = false; continue }
                    if judgement.mentioned { matches += excerpts.filter { judgement.chunkIDs.contains($0.id) } }
                }
                // A partial search cannot support a confident "Not mentioned" label.
                if !matches.isEmpty || itemComplete {
                    results.append(FollowUpResult(item: item.item, noteSource: source, status: matches.isEmpty ? .notMentioned : .mentioned(matches)))
                }
            }
        }
        return (results, incomplete)
    }
    func reduce(_ original: [Chunk], budget: Int, focus: String) async throws -> CitedText {
        if original.isEmpty { return CitedText(claims: []) }
        let originals = ContextBudget.split(original, maxBytes: budget)
        var current = originals
        // Each intermediate claim keeps the original, validated quotation and its source.
        struct Evidence { var chunk: Chunk; var quote: String }
        var lineage: [String: [Evidence]] = [:]
        for round in 0..<5 {
            try Task.checkCancellation()
            let batches = ContextBudget.batches(current, budget: budget)
            guard batches.count <= 64 else { throw AssistantError.contextOverflow }
            var combined: [CitedClaim] = [], next: [Chunk] = [], nextLineage: [String: [Evidence]] = [:]
            for batch in batches {
                try Task.checkCancellation()
                guard AssistantPrompts.excerpts(batch).utf8.count <= budget else { throw AssistantError.contextOverflow }
                let response = try await model.respond(instructions: AssistantPrompts.baseInstructions + " Summarise the record concisely. " + focus, prompt: AssistantPrompts.excerpts(batch))
                try Task.checkCancellation()
                let validated = try CitationValidator.validate(response, chunks: batch)
                for claim in validated.claims {
                    let evidence = zip(claim.sources, claim.quotes).flatMap { source, quote in
                        lineage[source.id] ?? [Evidence(chunk: source, quote: quote)]
                    }
                    var seen = Set<String>()
                    let unique = evidence.filter { seen.insert($0.chunk.id).inserted }.sorted { $0.chunk.id < $1.chunk.id }
                    combined.append(CitedClaim(text: claim.text, sources: unique.map(\.chunk), quotes: unique.map(\.quote)))
                    let id = "S\(round)-\(next.count)"
                    if let source = unique.first?.chunk {
                        next.append(Chunk(id: id, visitID: source.visitID, date: source.date, source: source.source, text: claim.text))
                        nextLineage[id] = unique
                    }
                }
            }
            if batches.count == 1 { return CitedText(claims: combined) }
            guard !next.isEmpty else { return CitedText(claims: []) }
            guard AssistantPrompts.excerpts(next).utf8.count < AssistantPrompts.excerpts(current).utf8.count else { throw AssistantError.noProgress }
            // A single oversized generated claim cannot be safely split without losing meaning.
            guard next.allSatisfy({ AssistantPrompts.excerpts([$0]).utf8.count <= budget }) else { throw AssistantError.noProgress }
            current = next; lineage = nextLineage
        }
        throw AssistantError.noProgress
    }
}
