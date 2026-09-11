#if os(macOS)
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class ArchiveFailurePresentationTests: XCTestCase {
    func testPriorAuthorizationFailuresDoNotDeclareCurrentAccountDisconnected() {
        let text = LibreReverseArchiveFailurePresentation.text(summaries: [
            .init(isHistoryIndex: false, count: 24, reason: "Google HTTP 400: invalid_grant; authorization expired or revoked")
        ], totalFailed: 24)
        XCTAssertTrue(text.contains("24 recording files"))
        XCTAssertTrue(text.contains("invalid_grant"))
        XCTAssertTrue(text.contains("earlier backup attempt"))
        XCTAssertTrue(text.contains("New backups may already be working"))
        XCTAssertTrue(text.contains("If authorization fails again, reconnect"))
    }

    func testMediaAndIndexReasonsAndUnlistedFailuresRemainDistinct() {
        let text = LibreReverseArchiveFailurePresentation.text(summaries: [
            .init(isHistoryIndex: false, count: 2, reason: "Synthetic storage quota exceeded\nRetry later"),
            .init(isHistoryIndex: true, count: 1, reason: "Synthetic checksum mismatch")
        ], totalFailed: 5)
        XCTAssertTrue(text.contains("2 recording files: Synthetic storage quota exceeded Retry later"))
        XCTAssertTrue(text.contains("1 history index file: Synthetic checksum mismatch"))
        XCTAssertTrue(text.contains("2 other failed files"))
        XCTAssertTrue(text.contains("Click Retry Backup"))
    }

    func testResolvedFailureHidesPriorReasonAndLongReasonsAreBounded() {
        let summary = LibreReverseArchiveFailureSummary(isHistoryIndex: false, count: 1, reason: String(repeating: "x", count: 1000))
        XCTAssertEqual(LibreReverseArchiveFailurePresentation.text(summaries: [summary], totalFailed: 0), "")
        XCTAssertFalse(LibreReverseArchiveFailurePresentation.text(summaries: [summary], totalFailed: 1).contains(String(repeating: "x", count: 241)))
    }
}
#endif
