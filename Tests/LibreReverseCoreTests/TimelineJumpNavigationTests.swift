import XCTest
@testable import LibreReverseCore

final class TimelineJumpNavigationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func segment(_ start: TimeInterval, _ end: TimeInterval, id: Int64) -> TimelineSegment {
        TimelineSegment(
            startDate: epoch.addingTimeInterval(start),
            endDate: epoch.addingTimeInterval(end),
            bundleID: "test.bundle",
            rawID: id,
            rawType: .capturedScreen
        )
    }

    private func assertUpdate(
        _ outcome: TimelineJumpOutcome,
        date: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .updateSeekPosition(actualDate, actualSource) = outcome else {
            return XCTFail("expected updateSeekPosition, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(actualDate, date, file: file, line: line)
        guard case .jumpToDate = actualSource else {
            return XCTFail("expected jumpToDate source", file: file, line: line)
        }
    }

    func testRecoveredBinaryPartitionAndDirectionalIndices() {
        let segments = [
            segment(0, 10, id: 0),
            segment(10, 20, id: 1),
            segment(20, 30, id: 2),
            segment(30, 40, id: 3),
        ]

        XCTAssertEqual(
            TimelineJumpNavigation.candidateSegment(
                for: .next,
                anchorDate: epoch.addingTimeInterval(15),
                processedScreenshotSegments: segments
            )?.rawID,
            2
        )
        XCTAssertEqual(
            TimelineJumpNavigation.candidateSegment(
                for: .previous,
                anchorDate: epoch.addingTimeInterval(25),
                processedScreenshotSegments: segments
            )?.rawID,
            1
        )
        XCTAssertNil(
            TimelineJumpNavigation.candidateSegment(
                for: .previous,
                anchorDate: epoch.addingTimeInterval(15),
                processedScreenshotSegments: segments
            )
        )
        XCTAssertEqual(
            TimelineJumpNavigation.candidateSegment(
                for: .next,
                anchorDate: epoch.addingTimeInterval(20),
                processedScreenshotSegments: segments
            )?.rawID,
            2,
            "end-date equality stays on the false side of the strict > predicate"
        )
    }

    func testNilSelectsLastScreenshotSegment() {
        let segments = [segment(0, 10, id: 0), segment(10, 20, id: 1)]
        XCTAssertEqual(
            TimelineJumpNavigation.candidateSegment(
                for: .next,
                anchorDate: nil,
                processedScreenshotSegments: segments
            )?.rawID,
            1
        )
        XCTAssertEqual(
            TimelineJumpNavigation.candidateSegment(
                for: .previous,
                anchorDate: nil,
                processedScreenshotSegments: segments
            )?.rawID,
            1
        )
    }

    func testCandidateUsesStartPlusHalfSecondAndJumpToDateSource() {
        let segments = [
            segment(0, 10, id: 0),
            segment(10, 20, id: 1),
            segment(20, 30, id: 2),
        ]
        assertUpdate(
            TimelineJumpNavigation.outcome(
                for: .next,
                anchorDate: epoch.addingTimeInterval(15),
                processedScreenshotSegments: segments,
                validSeekInterval: DateInterval(start: epoch, end: epoch.addingTimeInterval(30))
            ),
            date: epoch.addingTimeInterval(20.5)
        )
    }

    func testNextGuardAndFallbackAreAsymmetricWithPrevious() {
        let interval = DateInterval(start: epoch, end: epoch.addingTimeInterval(40))
        guard case .missingValidSeekInterval = TimelineJumpNavigation.outcome(
                for: .next,
                anchorDate: epoch,
                processedScreenshotSegments: [],
                validSeekInterval: nil
            ) else { return XCTFail("next must reject a missing valid seek interval") }
        assertUpdate(
            TimelineJumpNavigation.outcome(
                for: .next,
                anchorDate: epoch,
                processedScreenshotSegments: [],
                validSeekInterval: interval
            ),
            date: interval.end
        )
        guard case .noAction = TimelineJumpNavigation.outcome(
                for: .previous,
                anchorDate: epoch,
                processedScreenshotSegments: [],
                validSeekInterval: interval
            ) else { return XCTFail("previous must have no interval-end fallback") }
    }
}
