import Foundation
import XCTest
import NaturalLanguage

final class SemanticRerankerTests: XCTestCase {
    func testFusionRetainsLexicalPrecisionAndReturnsOriginalIdentities() async throws {
        let ranker = LibreReverseSemanticReranker(vector: { text in
            text.contains("exact") ? [0.8, 0.6] : [1, 0]
        })
        let candidates: [LibreReverseSemanticReranker.Candidate] = [
            .init(id: "meeting-a", text: "exact 48172", lexicalRank: 1),
            .init(id: "meeting-b", text: "paraphrase", lexicalRank: nil)
        ]
        let value = try await ranker.rank(question: "query", candidates: candidates, limit: 2)
        let ranked = try XCTUnwrap(value)
        XCTAssertEqual(ranked.map(\.id), ["meeting-a", "meeting-b"])
        XCTAssertGreaterThan(ranked[1].semanticScore, ranked[0].semanticScore)
    }

    func testUnavailableOrInvalidVectorsRequireLexicalFallback() async throws {
        let vectors: [@Sendable (String) -> [Double]?] = [{ _ in nil }, { _ in [0, 0] }, { _ in [.nan, 1] }]
        for vector in vectors {
            let ranker = LibreReverseSemanticReranker(vector: vector)
            let value = try await ranker.rank(question: "question", candidates: [.init(id: "a", text: "document", lexicalRank: 1)], limit: 1)
            XCTAssertNil(value)
        }
        let partial = LibreReverseSemanticReranker(vector: { $0 == "missing" ? nil : [1, 0] })
        let value = try await partial.rank(question: "question", candidates: [
            .init(id: "a", text: "present", lexicalRank: 1),
            .init(id: "b", text: "missing", lexicalRank: 2)], limit: 2)
        XCTAssertNil(value, "A failed embedding must not silently discard a lexical source")
    }

    func testCandidateAndChunkWorkIsBounded() async throws {
        let ranker = LibreReverseSemanticReranker(vector: { text in
            XCTAssertLessThanOrEqual(text.count, 1_000)
            XCTAssertFalse(text.contains("OUTSIDE_BOUND"))
            return [1, 0]
        })
        let text = String(repeating: "a", count: 4_000) + "OUTSIDE_BOUND"
        let value = try await ranker.rank(question: String(repeating: "q", count: 2_000),
            candidates: [.init(id: "a", text: text, lexicalRank: 1)], limit: 1)
        XCTAssertEqual(value?.first?.id, "a")
        do {
            _ = try await ranker.rank(question: "q", candidates: (0..<101).map {
                .init(id: String($0), text: "t", lexicalRank: nil)
            }, limit: 10)
            XCTFail("Must reject oversized discovery sets, not silently truncate")
        } catch LibreReverseSemanticReranker.Failure.candidateLimit { }
    }

    func testDuplicateIDsAndCancellationAreRejected() async throws {
        let ranker = LibreReverseSemanticReranker(vector: { _ in [1, 0] })
        do {
            _ = try await ranker.rank(question: "q", candidates: [
                .init(id: "a", text: "one", lexicalRank: 1), .init(id: "a", text: "two", lexicalRank: 2)], limit: 2)
            XCTFail("Duplicate identities must not create false citation support")
        } catch LibreReverseSemanticReranker.Failure.duplicateIdentity { }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ranker.rank(question: "q", candidates: [.init(id: "a", text: "t", lexicalRank: 1)], limit: 1)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
    }

    func testInstalledEnglishModelSyntheticEvaluation() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_RUN_SEMANTIC_EVALUATION"] == "1" else {
            throw XCTSkip("Opt-in local Apple model evaluation; deterministic policy tests run by default")
        }
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else {
            throw XCTSkip("English sentence embedding is not installed; never request downloads")
        }
 let docs = [
 "The release was postponed until October because the security audit found a vulnerability.",
 "The customer ended the subscription after repeated outages and poor support.",
 "We hired three engineers to reduce the backlog before the winter launch.",
 "The invoice is overdue. Finance will ask the buyer to settle the balance.",
 "Sofia owns the migration to the new database. Her deadline is November 14.",
 "Sonia owns the migration to the new database. Her deadline is November 21.",
 "The final approved budget for Project Cedar is 48172 dollars.",
 "The final approved budget for Project Cedar is 48127 dollars.",
 "At the first planning meeting, Atlas was blocked by a missing vendor contract.",
 "At the follow-up meeting, the Atlas vendor signed and procurement cleared the blocker.",
 "The team decided to encrypt stored recordings and remove credentials from logs.",
 "The café offers oat milk and freshly baked bread every morning.",
 "A new retention campaign gives subscribers a discount when they renew.",
 "We shipped the release in September after completing the performance audit.",
 "The buyer already paid the invoice. Finance closed the account.",
 "The production outage was caused by an expired certificate, not the database migration.",
 "The doctor recommended rest and plenty of water after the race.",
 "The budget discussion was postponed until next week; no amount was approved."
 ]
 let questions: [(String,String,Set<Int>)] = [
 ("paraphrase","Why did we delay shipping the product?",[0]),
 ("paraphrase","Which client stopped paying for the service because it was unreliable?",[1]),
 ("paraphrase","How are we adding people to finish outstanding development work?",[2]),
 ("paraphrase","Who needs a reminder to pay what they owe?",[3]),
 ("paraphrase","What protects private data from exposure?",[10]),
 ("exact-name","What is Sofia's migration deadline?",[4]),
 ("exact-name","What is Sonia's migration deadline?",[5]),
 ("exact-number","Which approved budget was 48172 dollars?",[6]),
 ("exact-number","Which approved budget was 48127 dollars?",[7]),
 ("cross-meeting","How did the Atlas vendor contract blocker change between meetings?",[8,9]),
 ("negation","What caused the production outage rather than the migration?",[15]),
 ("exact-topic","Which invoice has already been paid?",[14])
 ]
 let stop:Set<String> = ["a","an","the","what","which","why","who","how","we","did","is","was","are","to","it","for","of","they","from","has","been","in","and","s","because","with"]
 func tokens(_ s:String)->Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stop) }
 let docTokens=docs.map(tokens)
 var totals=["lexical":0.0,"semantic":0.0,"fusion":0.0]

        XCTAssertEqual(docs.count, 18)
        XCTAssertEqual(questions.count, 12)
        let ranker = LibreReverseSemanticReranker()
        let start = Date()
        for (_, question, relevant) in questions {
            let queryTokens = tokens(question)
            let lexical = docs.indices.filter { !queryTokens.intersection(docTokens[$0]).isEmpty }.sorted(by: >)
            let candidates = docs.indices.map { index in
                LibreReverseSemanticReranker.Candidate(id: String(index), text: docs[index],
                    lexicalRank: lexical.firstIndex(of: index).map { $0 + 1 })
            }
            let value = try await ranker.rank(question: question, candidates: candidates, limit: docs.count)
            let ranking = try XCTUnwrap(value)
            XCTAssertEqual(Set(ranking.map(\.id)), Set(candidates.map(\.id)), "No fabricated or dropped source identities")
            let semantic = ranking.sorted { $0.semanticScore > $1.semanticScore }.compactMap { Int($0.id) }
            let fused = ranking.compactMap { Int($0.id) }
            for (name, ids) in ["lexical": lexical, "semantic": semantic, "fusion": fused] {
                totals[name, default: 0] += Double(Set(ids.prefix(3)).intersection(relevant).count) / Double(relevant.count)
            }
        }
        // Evaluation output, not a claim that a small fixture earns production adoption.
        print("Semantic synthetic recall@3: \(totals.mapValues { $0 / Double(questions.count) }); elapsedSeconds=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(totals.count, 3)
        XCTAssertTrue(totals.values.allSatisfy { $0 >= 0 && $0 <= Double(questions.count) })
    }
}
