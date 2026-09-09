#if os(macOS)
import XCTest
@testable import LibreReverseApp
final class MeetingSummarizerTests: XCTestCase {
    func testLongMultilingualTranscriptPreservesEveryWordAcrossModelWindows() {
        let words = (0..<600).map { "話題\($0)" }
        let chunks = LibreReverseMeetingSummarizer.chunks(words.joined(separator: " "))
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_000 })
        XCTAssertEqual(chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init), words)
    }
    func testSilenceDoesNotLaunchAModelOrInventAMeeting() async throws {
        let summary = try await LibreReverseMeetingSummarizer.summarize(" \n ")
        XCTAssertEqual(summary, "No speech was detected in this meeting.")
    }
}
#endif
