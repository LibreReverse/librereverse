import XCTest
@testable import LibreReverseCore

/// Covers the independent leading-edge gates.
/// Completion actions do not provide a trailing flush.
final class TimelineSeekThrottleTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    func testRecoveredTimingTables() {
        XCTAssertEqual(TimelineInteractionTiming.boundsInterval, 0.1)
        XCTAssertEqual(TimelineInteractionTiming.scrollInterval(for: .normal), 0.1)
        XCTAssertEqual(TimelineInteractionTiming.scrollInterval(for: .manuallyFast), 0.2)
        XCTAssertEqual(TimelineInteractionTiming.scrollInterval(for: .shiftPowerUp), 0.2)
    }

    func testFirstEventIsAdmittedImmediately() {
        var throttle = TimelineSeekThrottle()
        XCTAssertTrue(throttle.admits(interval: 0.1, now: at(0)))
    }

    func testBoundsEventsInsideWindowAreDroppedNotDeferred() {
        var throttle = TimelineSeekThrottle()
        XCTAssertTrue(throttle.admits(interval: 0.1, now: at(0)))
        XCTAssertFalse(throttle.admits(interval: 0.1, now: at(0.05)))
        XCTAssertFalse(throttle.admits(interval: 0.1, now: at(0.0999)))
        XCTAssertTrue(throttle.admits(interval: 0.1, now: at(0.1001)))
    }

    func testFastScrollUsesTwoHundredMilliseconds() {
        var throttle = TimelineSeekThrottle()
        XCTAssertTrue(throttle.admits(interval: 0.2, now: at(0)))
        XCTAssertFalse(throttle.admits(interval: 0.2, now: at(0.1999)))
        XCTAssertTrue(throttle.admits(interval: 0.2, now: at(0.2001)))
    }

    func testContinuousBoundsUpdatesProduceLeadingEdgeFrames() {
        var throttle = TimelineSeekThrottle()
        var admitted = 0
        for step in 0..<60 {
            if throttle.admits(interval: 0.1, now: at(TimeInterval(step) / 60.0)) {
                admitted += 1
            }
        }
        XCTAssertEqual(admitted, 10)
    }

    func testRejectedEventDoesNotMoveTheWindow() {
        var throttle = TimelineSeekThrottle()
        XCTAssertTrue(throttle.admits(interval: 0.1, now: at(0)))
        XCTAssertFalse(throttle.admits(interval: 0.1, now: at(0.05)))
        XCTAssertEqual(throttle.lastUpdate, at(0))
        XCTAssertTrue(throttle.admits(interval: 0.1, now: at(0.11)))
    }

    func testBoundsAndScrollDatesAreIndependent() {
        var bounds = TimelineSeekThrottle()
        var scroll = TimelineSeekThrottle()
        XCTAssertTrue(bounds.admits(interval: 0.1, now: at(0)))
        XCTAssertTrue(scroll.admits(interval: 0.1, now: at(0)))
        XCTAssertFalse(bounds.admits(interval: 0.1, now: at(0.05)))
        XCTAssertFalse(scroll.admits(interval: 0.1, now: at(0.05)))
    }
}
