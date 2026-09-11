import Foundation
import XCTest
@testable import LibreReverseApp

private actor ObservationPlannerProbe: LibreReverseAskAnswerProvider, LibreReverseAskContextBudgetProvider {
    nonisolated let allowsFullTranscriptEvidence: Bool
    let context: LibreReverseAskContextBudget
    private(set) var calls: [(String, [LibreReverseAskCitation])] = []
    init(authorized: Bool = true, contextTokens: Int = 128000) {
        allowsFullTranscriptEvidence = authorized
        context = .init(contextTokens: contextTokens, outputTokens: 700)
    }
    func contextBudget() async throws -> LibreReverseAskContextBudget { context }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        calls.append((question, citations))
        return #"{"operations":[]}"#
    }
}

final class AskPlannerObservationTests: XCTestCase {
    private func observation(_ text: String) -> LibreReverseAskCitation {
        .init(instant: Date(timeIntervalSince1970: 0), title: "Synthetic meeting", excerpt: "SAFE PREVIEW",
            source: "Transcript d1_s1", evidence: text)
    }
    func testSecondRoundReceivesFullAuthorizedReadIncludingItsTail() async throws {
        let provider = ObservationPlannerProbe()
        _ = try await LibreReverseAskRetrievalPlanner.plan(question: "Find TAILMARKER", candidates: [], completed: [], provider: provider, apiKey: "test")
        let text = String(repeating: "x", count: 53000) + " TAILMARKER"
        let read = LibreReverseAskRetrievalPlanner.Operation(tool: .read, sourceID: "d1_s1")
        _ = try await LibreReverseAskRetrievalPlanner.plan(question: "Find TAILMARKER", candidates: [], completed: [read], observations: [observation(text)], provider: provider, apiKey: "test")
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].1.isEmpty)
        XCTAssertEqual(calls[1].1.first?.evidence, text)
        XCTAssertTrue(calls[1].0.contains("complete relevant meeting answers"))
    }
    func testUnconsentedObservationsExposeOnlyPreview() async throws {
        let provider = ObservationPlannerProbe(authorized: false)
        _ = try await LibreReverseAskRetrievalPlanner.plan(question: "Question", candidates: [], completed: [], observations: [observation("PRIVATE FULL TEXT")], provider: provider, apiKey: "test")
        let calls = await provider.calls
        let source = try XCTUnwrap(calls.first?.1.first)
        XCTAssertNil(source.evidence)
        XCTAssertEqual(source.excerpt, "SAFE PREVIEW")
        XCTAssertFalse(source.providerText.contains("PRIVATE"))
    }
    func testSmallContextReceivesMarkedQueryCenteredObservationWithinCombinedBudget() async throws {
        let provider = ObservationPlannerProbe(contextTokens: 4096)
        let text = String(repeating: "unrelated ", count: 2000) + "TAILMARKER is the relevant answer."
        _ = try await LibreReverseAskRetrievalPlanner.plan(question: "Find TAILMARKER", candidates: [], completed: [], observations: [observation(text)], provider: provider, apiKey: "test")
        let calls = await provider.calls
        let call = try XCTUnwrap(calls.first)
        let supplied = try XCTUnwrap(call.1.first)
        XCTAssertTrue(supplied.providerText.contains("Partial observation"))
        XCTAssertTrue(supplied.providerText.contains("TAILMARKER"))
        let serialized = call.1.enumerated().map { "[\($0.offset + 1)] \($0.element.providerText)" }.joined(separator: "\n")
        let budget = try await provider.contextBudget()
        XCTAssertLessThanOrEqual(call.0.utf8.count + serialized.utf8.count, budget.inputTokens)
    }
}
