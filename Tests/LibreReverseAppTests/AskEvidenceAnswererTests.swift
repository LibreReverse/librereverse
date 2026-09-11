import XCTest
@testable import LibreReverseApp

private actor EvidenceProviderProbe: LibreReverseAskAnswerProvider {
    nonisolated let evidenceCharacterBudget: Int
    nonisolated let allowsFullTranscriptEvidence: Bool
    enum Mode { case extract, echo, cancel }
    let mode: Mode
    private(set) var inputs: [[LibreReverseAskCitation]] = []
    init(budget: Int = 64_000, mode: Mode = .extract, authorized: Bool = true) {
        allowsFullTranscriptEvidence = authorized
        evidenceCharacterBudget = budget
        self.mode = mode
    }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        inputs.append(citations)
        if mode == .cancel { throw CancellationError() }
        if mode == .echo { return citations[0].providerText }
        if question.hasPrefix("Extract facts") {
            let supplied = allowsFullTranscriptEvidence ? citations[0].providerText : citations[0].plainText
            return supplied.contains("TAILMARKER") ? "TAILMARKER [1]" : "Other fact [1]"
        }
        return "Final [1] [2]"
    }
}

final class AskEvidenceAnswererTests: XCTestCase {
    private func citation(_ evidence: String, title: String = "Meeting") -> LibreReverseAskCitation {
        .init(instant: Date(timeIntervalSince1970: 0), title: title, excerpt: "Short preview",
            source: "Transcript", evidence: evidence)
    }

    func testLongMeetingFitsCloudBudgetWithoutLosingItsTail() async throws {
        let provider = EvidenceProviderProbe()
        let source = citation(String(repeating: "x", count: 53_000) + " TAILMARKER")
        _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Decision?", citations: [source], apiKey: "test", provider: provider)
        let inputs = await provider.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0], [source])
        XCTAssertTrue(inputs[0][0].providerText.hasSuffix("TAILMARKER"))
    }

    func testEveryChunkIsVisitedAndFinalNumbersKeepOriginalSources() async throws {
        let provider = EvidenceProviderProbe(budget: 500)
        let sources = [citation(String(repeating: "a", count: 1200) + "TAILMARKER", title: "First"),
                       citation(String(repeating: "b", count: 900), title: "Second")]
        _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Decision?", citations: sources, apiKey: "test", provider: provider)
        let inputs = await provider.inputs
        let final = try XCTUnwrap(inputs.last)
        XCTAssertGreaterThan(inputs.count, 4)
        XCTAssertEqual(final.map(\.title), ["First", "Second"])
        XCTAssertTrue(final[0].providerText.contains("TAILMARKER"))
        XCTAssertFalse(final[0].providerText.contains("[1]"))
        let extracted = inputs.dropLast().flatMap { $0 }.filter { $0.title == "First" }.map { $0.evidence ?? "" }.joined()
        XCTAssertEqual(extracted, sources[0].evidence)
        for input in inputs {
            let evidence = input.enumerated().map { "[\($0.offset + 1)] \($0.element.providerText)" }.joined(separator: "\n")
            XCTAssertLessThanOrEqual(evidence.count, 500)
        }
    }

    func testPreviewOnlyProviderReceivesActualDerivedChunksAndNotes() async throws {
        let provider = EvidenceProviderProbe(budget: 500, authorized: false)
        let source = LibreReverseAskCitation(instant: Date(timeIntervalSince1970: 0), title: "Preview",
            excerpt: String(repeating: "p", count: 1200) + "TAILMARKER", source: "OCR")
        _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Decision?", citations: [source], apiKey: "test", provider: provider)
        let inputs = await provider.inputs
        let final = try XCTUnwrap(inputs.last?.first)
        XCTAssertTrue(final.plainText.contains("TAILMARKER"))
        XCTAssertLessThan(final.excerpt.count, source.excerpt.count)
        XCTAssertEqual(inputs.dropLast().flatMap { $0 }.map(\.excerpt).joined(), source.excerpt)
    }

    func testNonReducingProviderFailsInsteadOfDroppingEvidence() async throws {
        let provider = EvidenceProviderProbe(budget: 300, mode: .echo)
        do {
            _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Decision?", citations: [citation(String(repeating: "x", count: 1000))], apiKey: "test", provider: provider)
            XCTFail("Expected narrowing error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Narrow"))
        }
        let calls = await provider.inputs.count
        XCTAssertLessThan(calls, 10)
    }

    func testCancellationStopsBeforeAdditionalChunksOrFinalAnswer() async throws {
        let provider = EvidenceProviderProbe(budget: 300, mode: .cancel)
        do {
            _ = try await LibreReverseAskEvidenceAnswerer.answer(question: "Decision?", citations: [citation(String(repeating: "x", count: 1000))], apiKey: "test", provider: provider)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let calls = await provider.inputs.count
        XCTAssertEqual(calls, 1)
    }
}
