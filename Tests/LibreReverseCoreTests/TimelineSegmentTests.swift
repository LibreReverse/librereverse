import Foundation
import XCTest
@testable import LibreReverseCore

final class TimelineSegmentTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecoveredEnumOrdinalsRemainStable() {
        XCTAssertEqual(SegmentType.capturedScreen.rawValue, 0)
        XCTAssertEqual(SegmentType.websiteVisit.rawValue, 3)
        XCTAssertEqual(
            SeekPositionUpdateSource.allCases.firstIndex(of: .keyboardShortcut),
            3
        )
        XCTAssertEqual(
            SeekPositionUpdateSource.allCases.firstIndex(of: .isInitialLoad),
            11
        )
        XCTAssertEqual(SegmentLegacyType.allCases.firstIndex(of: .screenshot), 1)
    }

    func testRecoveredInteractionTimingIsNotKeyedBySeekSource() {
        XCTAssertEqual(TimelineInteractionTiming.boundsInterval, 0.1)
        XCTAssertEqual(TimelineInteractionTiming.scrollInterval(for: .normal), 0.1)
        XCTAssertEqual(TimelineInteractionTiming.scrollInterval(for: .manuallyFast), 0.2)
    }

    func testWebsiteHostMatchesNormalizationPath() {
        XCTAssertEqual(
            TimelineSegmentProcessor.websiteHost(for: "example.com/path"),
            "example.com"
        )
        XCTAssertEqual(
            TimelineSegmentProcessor.websiteHost(for: "https://example.com/other"),
            "example.com"
        )
        XCTAssertNil(TimelineSegmentProcessor.websiteHost(for: nil))
        XCTAssertNil(TimelineSegmentProcessor.websiteHost(for: ""))
    }

    func testAppGroupingRequiresBundleAndWebsiteHost() {
        let first = segment(id: 1, start: 0, end: 10, bundle: "browser", url: "a.example/x")
        let same = segment(id: 2, start: 10, end: 20, bundle: "browser", url: "https://a.example/y")
        let otherHost = segment(id: 3, start: 20, end: 30, bundle: "browser", url: "b.example")
        let otherBundle = segment(id: 4, start: 30, end: 40, bundle: "editor", url: "b.example")

        XCTAssertTrue(
            TimelineSegmentProcessor.belongsInSameAppGroup(previous: first, next: same)
        )
        XCTAssertFalse(
            TimelineSegmentProcessor.belongsInSameAppGroup(previous: same, next: otherHost)
        )
        XCTAssertFalse(
            TimelineSegmentProcessor.belongsInSameAppGroup(
                previous: otherHost,
                next: otherBundle
            )
        )
    }

    func testAppGroupingUsesStrict240SecondBoundary() {
        let first = segment(id: 1, start: 0, end: 10, bundle: "editor")
        let justInside = segment(id: 2, start: 249.999, end: 260, bundle: "editor")
        let atBoundary = segment(id: 3, start: 250, end: 260, bundle: "editor")

        XCTAssertTrue(
            TimelineSegmentProcessor.belongsInSameAppGroup(
                previous: first,
                next: justInside
            )
        )
        XCTAssertFalse(
            TimelineSegmentProcessor.belongsInSameAppGroup(
                previous: first,
                next: atBoundary
            )
        )
    }

    func testGroupingKeepsRawSegmentsAndSplitsAtVerifiedPredicates() {
        let segments = [
            segment(id: 1, start: 0, end: 10, bundle: "browser", url: "a.example/1"),
            segment(id: 2, start: 10, end: 20, bundle: "browser", url: "a.example/2"),
            segment(id: 3, start: 20, end: 30, bundle: "browser", url: "b.example"),
            segment(id: 4, start: 30, end: 40, bundle: "editor"),
        ]
        let groups = TimelineSegmentProcessor.groupCapturedScreenSegments(segments)

        XCTAssertEqual(groups.map(\.segments.count), [2, 1, 1])
        XCTAssertEqual(groups.map(\.index), [0, 1, 2])
        XCTAssertEqual(groups[0].dateInterval, DateInterval(start: origin, duration: 20))
    }

    private func segment(
        id: Int64,
        start: TimeInterval,
        end: TimeInterval,
        bundle: String?,
        url: String? = nil
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: origin.addingTimeInterval(start),
            endDate: origin.addingTimeInterval(end),
            bundleID: bundle,
            browserURL: url,
            rawID: id,
            rawType: .capturedScreen
        )
    }
}
