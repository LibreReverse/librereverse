import XCTest
@testable import LibreReverseCore

final class TimelineInteractionTests: XCTestCase {
    func testLiveEdgeLatchRejectsSameGestureJitterButNewGestureCanLeave() {
        var latch = LibreReverseTimelineLiveGestureLatch()

        XCTAssertFalse(latch.prepareForEvent(beginsGesture: true, isPhaseless: false))
        latch.didReachEnd(isPhaseless: false)
        XCTAssertTrue(latch.prepareForEvent(beginsGesture: false, isPhaseless: false))
        XCTAssertTrue(latch.prepareForEvent(beginsGesture: false, isPhaseless: false))

        latch.gestureEnded()
        XCTAssertFalse(latch.reachedEnd)
        XCTAssertFalse(latch.prepareForEvent(beginsGesture: false, isPhaseless: false))

        latch.didReachEnd(isPhaseless: false)
        XCTAssertFalse(latch.prepareForEvent(beginsGesture: true, isPhaseless: false))
        XCTAssertFalse(latch.reachedEnd)
    }

    func testPhaselessWheelEventsDoNotRemainLatched() {
        var latch = LibreReverseTimelineLiveGestureLatch()
        latch.didReachEnd(isPhaseless: true)
        XCTAssertFalse(latch.reachedEnd)
        XCTAssertFalse(latch.prepareForEvent(beginsGesture: false, isPhaseless: true))
    }

    func testLiveEdgeLatchCanRepeatAcrossManyGestureCycles() {
        var latch = LibreReverseTimelineLiveGestureLatch()
        for _ in 0..<100 {
            XCTAssertFalse(latch.prepareForEvent(beginsGesture: true, isPhaseless: false))
            latch.didReachEnd(isPhaseless: false)
            XCTAssertTrue(latch.prepareForEvent(beginsGesture: false, isPhaseless: false))
            latch.gestureEnded()

            // Even if the next sequence has no `.began`, the completed prior
            // gesture must not suppress its first backward sample.
            XCTAssertFalse(latch.prepareForEvent(beginsGesture: false, isPhaseless: false))
        }
    }

    func testBoundedRightClampPinsDirectlyToGlobalEnd() {
        let globalEnd = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(TimelineEndOwnership.pinTarget(
            localOffset: 100,
            localDuration: 100,
            globalValidEnd: globalEnd,
            advancesForward: true
        ), globalEnd)
        XCTAssertNil(TimelineEndOwnership.pinTarget(
            localOffset: 99,
            localDuration: 100,
            globalValidEnd: globalEnd,
            advancesForward: true
        ))
        XCTAssertNil(TimelineEndOwnership.pinTarget(
            localOffset: 100,
            localDuration: 100,
            globalValidEnd: globalEnd,
            advancesForward: false
        ))
    }
    func testClickAndDragRequestsRetainProvenance() {
        let date = Date(timeIntervalSince1970: 123)
        let click = TimelineSeekRequest(date: date, source: .click)
        let drag = TimelineSeekRequest(date: date, source: .drag)
        let jump = TimelineSeekRequest(date: date, source: .jumpToDate)
        XCTAssertEqual(click.date, date)
        XCTAssertEqual(click.source, .click)
        XCTAssertEqual(drag.source, .drag)
        XCTAssertEqual(jump.source, .jumpToDate)
    }
}
