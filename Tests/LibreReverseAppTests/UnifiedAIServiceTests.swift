import XCTest
@testable import LibreReverseApp

private actor SummaryProviderProbe: LibreReverseAskAnswerProvider {
    var calls = 0
    var receivedSecret = false
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        calls += 1
        receivedSecret = citations.contains { $0.excerpt.contains("person@example.com") }
        return "A decision and an action item."
    }
}

final class UnifiedAIServiceTests: XCTestCase {
    func testSummaryUsesSuppliedProviderAndRedactsItsInput() async throws {
        let provider = SummaryProviderProbe()
        let summary = try await LibreReverseAIService.summarize("Send the release notes to person@example.com.", provider: provider, apiKey: "synthetic")
        XCTAssertEqual(summary, "A decision and an action item.")
        let calls = await provider.calls, leaked = await provider.receivedSecret
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(leaked)
    }
    func testEveryProfileUsesOneProviderFactory() {
        XCTAssertTrue(LibreReverseAIService.provider(for: .local) is LibreReverseLocalAnswerProvider)
        XCTAssertTrue(LibreReverseAIService.provider(for: .deepSeek) is LibreReverseOpenRouterProvider)
        XCTAssertTrue(LibreReverseAIService.provider(for: .openAI) is LibreReverseOpenAIResponsesProvider)
    }
}
