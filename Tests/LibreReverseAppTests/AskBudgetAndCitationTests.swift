import Foundation
import XCTest
@testable import LibreReverseApp

final class AskBudgetAndCitationTests: XCTestCase {
    func testGroupedAndRangeCitationsResolveAndUnknownIDsFail() throws {
        let refs = try LibreReverseAskCitationValidation.references(in: "🧭 Evidence [1, 3] and [2–4].", sourceCount: 4)
        XCTAssertEqual(refs.map(\.sourceIDs), [[1, 3], [2, 3, 4]])
        XCTAssertEqual(("🧭 Evidence [1, 3] and [2–4]." as NSString).substring(with: refs[0].range), "[1, 3]")
        for value in ["[0]", "[1, 5]", "[2-9]", "[3-1]", "[999999999999999999999999999]"] {
            XCTAssertThrowsError(try LibreReverseAskCitationValidation.validate(value, sourceCount: 4))
        }
        XCTAssertEqual(LibreReverseAskCitationValidation.removingReferences(from: "Fact [1, 2–3]."), "Fact .")
    }
    func testMultilingualBudgetIncludesBytesQuestionAndOutputReserve() {
        XCTAssertEqual(LibreReverseAskContextBudget.estimatedTokens("漢字"), 6)
        XCTAssertGreaterThan(LibreReverseAskContextBudget.estimatedTokens("👩🏽‍💻"), 1)
        let budget = LibreReverseAskContextBudget(contextTokens: 4096, outputTokens: 700)
        XCTAssertEqual(budget.evidenceCapacity(question: "漢字"), 4096 - 700 - 1024 - 6)
        XCTAssertEqual(budget.evidenceCapacity(question: String(repeating: "x", count: 5000)), 0)
    }
    func testEndpointRoutingUsesConservativeEligibleLimits() throws {
        let data = Data(#"{"data":{"endpoints":[{"provider_name":"One","context_length":128000,"max_completion_tokens":32768},{"provider_name":"Two","context_length":8192,"max_completion_tokens":1024}]}}"#.utf8)
        var profile = LibreReverseAIProfile.deepSeek
        profile.preferredProviders = ["One"]; profile.allowFallbacks = false
        XCTAssertEqual(LibreReverseOpenRouterModelMetadata.decode(data, profile: profile), .init(contextTokens: 128000, outputTokens: 16384))
        profile.allowFallbacks = true
        XCTAssertEqual(LibreReverseOpenRouterModelMetadata.decode(data, profile: profile), .init(contextTokens: 8192, outputTokens: 1024))
        profile.allowFallbacks = false; profile.preferredProviders = ["Unknown"]
        XCTAssertNil(LibreReverseOpenRouterModelMetadata.decode(data, profile: profile))
        XCTAssertNil(LibreReverseOpenRouterModelMetadata.decode(Data("{}".utf8), profile: profile))
    }
    func testOpenAIRejectsIncompleteErroredAndRefusedResponses() throws {
        let complete = #"{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"Final answer"}]}]}"#
        XCTAssertEqual(try LibreReverseOpenAICompleteResponse.decode(Data(complete.utf8)), "Final answer")
        for value in [complete.replacingOccurrences(of: "completed", with: "incomplete"),
                      #"{"status":"completed","error":{"message":"error"},"output":[]}"#,
                      #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#,
                      "{}"] {
            XCTAssertThrowsError(try LibreReverseOpenAICompleteResponse.decode(Data(value.utf8)))
        }
    }
}

private actor TokenBudgetProbe: LibreReverseAskAnswerProvider, LibreReverseAskContextBudgetProvider {
    nonisolated var allowsFullTranscriptEvidence: Bool { true }
    private(set) var chunks: [String] = []
    private(set) var oversizedRequests = 0
    func contextBudget() async throws -> LibreReverseAskContextBudget { .init(contextTokens: 4096, outputTokens: 700) }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        let budget = try await contextBudget()
        let evidence = citations.enumerated().map { "[\($0.offset + 1)] \($0.element.providerText)" }.joined(separator: "\n")
        if evidence.utf8.count > budget.evidenceCapacity(question: question) { oversizedRequests += 1 }
        if question.hasPrefix("Extract facts") { chunks.append(citations[0].evidence ?? ""); return "Relevant note" }
        return "Answer [1]"
    }
}

extension AskBudgetAndCitationTests {
    func testMultilingualReductionVisitsEveryCharacterWithinTokenBudget() async throws {
        let provider = TokenBudgetProbe()
        let text = String(repeating: "漢👩🏽‍💻", count: 250) + "TAIL"
        _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Question", citations: [
            .init(instant: Date(timeIntervalSince1970: 0), title: "Synthetic", excerpt: "Preview", source: "Transcript", evidence: text)
        ], apiKey: "synthetic", provider: provider)
        let chunks = await provider.chunks, oversized = await provider.oversizedRequests
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(oversized, 0)
    }
}
