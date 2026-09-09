import XCTest
@testable import LibreReverseCore

final class TimelinePresentationIndexTests: XCTestCase {
    func testVisibleRangeUsesHalfOpenIntersectionSemantics() {
        let index = TimelinePresentationIndex(intervals: [
            .init(offset: 0, duration: 10),
            .init(offset: 10, duration: 10),
            .init(offset: 20, duration: 10),
            .init(offset: 30, duration: 10),
        ])

        XCTAssertEqual(index.visibleRange(centeredAt: 20, duration: 20), 1..<3)
        XCTAssertEqual(index.visibleRange(centeredAt: 5, duration: 10), 0..<1)
        XCTAssertEqual(index.visibleRange(centeredAt: 45, duration: 10), 4..<4)
    }

    func testPrefixMaximumEndRetainsLongEarlierPresentation() {
        let index = TimelinePresentationIndex(intervals: [
            .init(offset: 0, duration: 100),
            .init(offset: 10, duration: 2),
            .init(offset: 20, duration: 2),
            .init(offset: 30, duration: 2),
        ])

        XCTAssertEqual(index.visibleRange(centeredAt: 26, duration: 4), 0..<3)
    }

    func testLargeCorpusQueryDoesNotChangeResults() {
        let intervals = (0..<120_000).map {
            TimelinePresentationIndex.Interval(
                offset: Double($0) * 2,
                duration: 1
            )
        }
        let index = TimelinePresentationIndex(intervals: intervals)

        XCTAssertEqual(
            index.visibleRange(centeredAt: 120_000, duration: 60),
            59_985..<60_015
        )
    }
}
