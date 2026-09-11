import Foundation
import NaturalLanguage

/// Experimental, opt-in reranking only. No index, downloads, network, or retained text.
/// Candidate discovery and its coverage guarantees remain the caller's responsibility.
actor LibreReverseSemanticReranker {
    struct Candidate: Sendable {
        let id: String
        let text: String
        /// One-based rank in the caller's lexical result, or nil for a broader candidate.
        let lexicalRank: Int?
    }
    struct Result: Sendable {
        let id: String
        let semanticScore: Double
        let fusedScore: Double
    }
    enum Failure: Error { case candidateLimit, duplicateIdentity, invalidLexicalRank }
    static let maximumCandidates = 100
    static let maximumCharactersPerCandidate = 4_000
    private var embedding: NLEmbedding?
    private let injectedVector: (@Sendable (String) -> [Double]?)?

    init(vector: (@Sendable (String) -> [Double]?)? = nil) { injectedVector = vector }

    /// Returns nil when the local English model is unavailable. Never requests assets.
    /// This bounds a preview reranker; it must not be used to claim full-transcript coverage.
    func rank(question: String, candidates: [Candidate], limit: Int) throws -> [Result]? {
        try Task.checkCancellation()
        guard candidates.count <= Self.maximumCandidates else { throw Failure.candidateLimit }
        guard Set(candidates.map(\.id)).count == candidates.count else { throw Failure.duplicateIdentity }
        guard candidates.allSatisfy({ ($0.lexicalRank ?? 1) > 0 }) else { throw Failure.invalidLexicalRank }
        guard limit > 0, !candidates.isEmpty else { return [] }
        if injectedVector == nil && embedding == nil { embedding = NLEmbedding.sentenceEmbedding(for: .english) }
        guard let query = vector(String(question.prefix(1_000))) else { return nil }
        var scores: [(Candidate, Double)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let text = String(candidate.text.prefix(Self.maximumCharactersPerCandidate))
            var start = text.startIndex
            var best: Double?
            while start < text.endIndex {
                try Task.checkCancellation()
                let end = text.index(start, offsetBy: 1_000, limitedBy: text.endIndex) ?? text.endIndex
                if let value = vector(String(text[start..<end])), let score = Self.cosine(query, value) {
                    best = max(best ?? score, score)
                }
                start = end
            }
            if let best { scores.append((candidate, best)) }
        }
        try Task.checkCancellation()
        // A missing candidate vector must not silently remove a lexical source.
        guard scores.count == candidates.count else { return nil }
        scores.sort { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        let results = scores.enumerated().map { index, entry in
            let lexical = entry.0.lexicalRank.map { 1.0 / (60.0 + Double($0)) } ?? 0
            return Result(id: entry.0.id, semanticScore: entry.1,
                fusedScore: lexical + 1.0 / (61.0 + Double(index)))
        }
        return Array(results.sorted {
            $0.fusedScore == $1.fusedScore ? $0.id < $1.id : $0.fusedScore > $1.fusedScore
        }.prefix(limit))
    }

    private func vector(_ text: String) -> [Double]? {
        if let injectedVector { return injectedVector(text) }
        return embedding?.vector(for: text)
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { dot += x * y; aa += x * x; bb += y * y }
        guard aa > 0, bb > 0, dot.isFinite, aa.isFinite, bb.isFinite else { return nil }
        return dot / sqrt(aa * bb)
    }
}
