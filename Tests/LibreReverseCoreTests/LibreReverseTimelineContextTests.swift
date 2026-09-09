import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseTimelineContextTests: XCTestCase {
    func testRecoveredBrowserBundleIdentities() {
        XCTAssertEqual(LibreReverseRecordedApplication(bundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(LibreReverseRecordedApplication(bundleID: "com.google.Chrome"), .chrome)
        XCTAssertEqual(LibreReverseRecordedApplication(bundleID: "com.brave.Browser"), .brave)
        XCTAssertEqual(LibreReverseRecordedApplication(bundleID: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(LibreReverseRecordedApplication(bundleID: "org.mozilla.firefox"), .firefox)
        XCTAssertEqual(
            LibreReverseRecordedApplication(bundleID: "com.example.Editor"),
            .other(bundleID: "com.example.Editor")
        )
    }

    func testSelectedRawIDWinsOverDateFallbackAndCarriesWindowContext() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = segment(
            id: 10,
            start: start,
            bundleID: "com.example.Editor",
            windowName: "Draft"
        )
        let second = segment(
            id: 20,
            start: start.addingTimeInterval(2),
            bundleID: "com.apple.Safari",
            windowName: "Project notes",
            browserURL: "https://example.test/article"
        )
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [first, second])
        let context = try XCTUnwrap(LibreReverseTimelineContextResolver.selectedContext(
            in: snapshot,
            selectedSegmentIDs: [10],
            at: second.startDate
        ))
        XCTAssertEqual(context.segmentID, 10)
        XCTAssertEqual(context.application, .other(bundleID: "com.example.Editor"))
        XCTAssertEqual(context.windowName, "Draft")
        XCTAssertNil(context.openAction)
    }

    func testMergedRawIDResolvesProcessedApplicationContext() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var first = segment(id: 10, start: start, bundleID: "com.apple.Safari")
        var second = segment(
            id: 11,
            start: start.addingTimeInterval(2),
            bundleID: "com.apple.Safari",
            browserURL: "https://example.test"
        )
        first.mergedSegmentIDs = [7]
        second.mergedSegmentIDs = [8]
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [first, second])
        let context = try XCTUnwrap(LibreReverseTimelineContextResolver.selectedContext(
            in: snapshot,
            selectedSegmentIDs: [8],
            at: nil
        ))
        XCTAssertEqual(context.application, .safari)
    }

    func testOpenActionRequiresKnownBrowserAndAbsoluteHTTPURL() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let browser = LibreReverseTimelineSelectionContext(segment: segment(
            id: 1,
            start: start,
            bundleID: "company.thebrowser.Browser",
            browserURL: "https://example.test/path"
        ))
        XCTAssertEqual(browser.openAction?.url.absoluteString, "https://example.test/path")
        XCTAssertEqual(browser.openAction?.application, .arc)

        let nonBrowser = LibreReverseTimelineSelectionContext(segment: segment(
            id: 2,
            start: start,
            bundleID: "com.example.Editor",
            browserURL: "https://example.test/path"
        ))
        XCTAssertNil(nonBrowser.openAction)

        XCTAssertNil(LibreReverseTimelineContextResolver.openableWebURL("example.test/path"))
        XCTAssertNil(LibreReverseTimelineContextResolver.openableWebURL("file:///tmp/example"))
    }

    func testRecordedOpenActionPresentsControlWithoutInstalledBrowserFiltering() throws {
        let action = try XCTUnwrap(LibreReverseTimelineSelectionContext(segment: segment(
            id: 1,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            bundleID: "com.google.Chrome.dev",
            browserURL: "https://example.test/path"
        )).openAction)

        XCTAssertTrue(LibreReverseContextualOpenContract.presentsControl(for: action))
        XCTAssertFalse(LibreReverseContextualOpenContract.presentsControl(for: nil))
    }

    func testDateAtTouchingBoundarySelectsIncomingApplication() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let outgoing = segment(
            id: 1,
            start: start,
            bundleID: "com.example.Editor",
            windowName: "Draft"
        )
        let incoming = segment(
            id: 2,
            start: start.addingTimeInterval(2),
            bundleID: "com.apple.Safari",
            windowName: "Project notes",
            browserURL: "https://example.test/notes"
        )
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [outgoing, incoming])

        let context = try XCTUnwrap(LibreReverseTimelineContextResolver.selectedContext(
            in: snapshot,
            selectedSegmentIDs: [],
            at: incoming.startDate
        ))

        XCTAssertEqual(context.segmentID, 2)
        XCTAssertEqual(context.application, .safari)
        XCTAssertEqual(context.windowName, "Project notes")
    }

    private func segment(
        id: Int64,
        start: Date,
        bundleID: String?,
        windowName: String? = nil,
        browserURL: String? = nil
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: start,
            endDate: start.addingTimeInterval(2),
            bundleID: bundleID,
            windowName: windowName,
            browserURL: browserURL,
            rawID: id,
            rawType: .capturedScreen
        )
    }
}
