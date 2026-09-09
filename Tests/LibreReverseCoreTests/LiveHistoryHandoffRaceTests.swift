import Foundation
import XCTest
@testable import LibreReverseCore

/// Database-window reconciliation with concurrent recording publications.
final class LiveHistoryHandoffRaceTests: XCTestCase {
    func testRecordingPublicationDuringFetchCannotRollTheLiveEndBackward() {
        let fetchedEnd = Date(timeIntervalSince1970: 100)
        let liveEnd = Date(timeIntervalSince1970: 102)
        let fetched = TimelineSegment(
            startDate: Date(timeIntervalSince1970: 90),
            endDate: fetchedEnd,
            bundleID: "test.app",
            rawID: 7,
            rawType: .capturedScreen
        )
        let extended = TimelineSegment(
            startDate: fetched.startDate,
            endDate: liveEnd,
            bundleID: "test.app",
            rawID: 7,
            rawType: .capturedScreen
        )

        let result = RecordingWindowReconciliation.reconcile(
            fetchedSegments: [fetched],
            fetchedValidSeekInterval: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: fetchedEnd
            ),
            recordingPublications: [
                RecordingSegmentPublication(revision: 42, segment: extended)
            ],
            after: 41
        )

        XCTAssertEqual(result.segments, [extended])
        XCTAssertEqual(result.validSeekInterval?.end, liveEnd)
    }

    func testFetchWithoutLaterRecordingRemainsACompleteReplacement() {
        let fetched = TimelineSegment(
            startDate: Date(timeIntervalSince1970: 90),
            endDate: Date(timeIntervalSince1970: 100),
            bundleID: "test.app",
            rawID: 7,
            rawType: .capturedScreen
        )
        let stalePriorTail = TimelineSegment(
            startDate: Date(timeIntervalSince1970: 101),
            endDate: Date(timeIntervalSince1970: 102),
            bundleID: "other.app",
            rawID: 8,
            rawType: .capturedScreen
        )
        let result = RecordingWindowReconciliation.reconcile(
            fetchedSegments: [fetched],
            fetchedValidSeekInterval: nil,
            recordingPublications: [
                RecordingSegmentPublication(revision: 40, segment: stalePriorTail)
            ],
            after: 41
        )
        XCTAssertEqual(result.segments, [fetched])
        XCTAssertNil(result.validSeekInterval)
    }

}
