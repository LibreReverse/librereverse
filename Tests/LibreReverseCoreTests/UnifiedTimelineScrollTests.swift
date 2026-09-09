import XCTest
@testable import LibreReverseCore

final class UnifiedTimelineScrollTests: XCTestCase {
    func testSameGestureMovesSamePixelsAcrossMediaAtEveryZoom() throws {
        let origin = Date(timeIntervalSince1970: 1000)
        func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        let axis = LibreReverseTimelineSnapshot(rawSegments: [
            .init(startDate: date(0), endDate: date(600), bundleID: "app", rawID: 1, rawType: .capturedScreen),
            .init(startDate: date(600), endDate: date(660), bundleID: "meeting", rawID: 2, rawType: .audio),
            .init(startDate: date(660), endDate: date(2000), bundleID: "app", rawID: 3, rawType: .capturedScreen)
        ], playbackFrameDates: stride(from: 0.0, through: 2000.0, by: 2).map(date))
        for zoom: Float in [20, 60, 90] {
            for seconds in [300.0, 620, 1000] {
                for pixels in [-4.0, 4] {
                    let step = try XCTUnwrap(UnifiedTimelineScroll.step(snapshot: axis, from: date(seconds), distance: UnifiedTimelineScroll.distance(pixels: pixels, zoom: zoom)))
                    let start = try XCTUnwrap(axis.contiguousOffset(atWallDate: date(seconds)))
                    let end = try XCTUnwrap(axis.contiguousOffset(atWallDate: step.date))
                    XCTAssertEqual((end-start) * LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: zoom), pixels, accuracy: 0.0001)
                    XCTAssertEqual(step.remainder, 0, accuracy: 0.0001)
                }
            }
        }
    }

    func testBoundaryRetainsUnconsumedMovementAcrossWindowReplacement() throws {
        func axis(_ start: Double, _ end: Double) -> LibreReverseTimelineSnapshot {
            .init(rawSegments: [.init(startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end), bundleID: "app", rawID: 1, rawType: .capturedScreen)])
        }
        let first = try XCTUnwrap(UnifiedTimelineScroll.step(snapshot: axis(100, 200), from: Date(timeIntervalSince1970: 110), distance: -40))
        XCTAssertEqual(first.date.timeIntervalSince1970, 100)
        XCTAssertEqual(first.remainder, -30)
        let next = try XCTUnwrap(UnifiedTimelineScroll.step(snapshot: axis(0, 150), from: first.date, distance: first.remainder))
        XCTAssertEqual(next.date.timeIntervalSince1970, 70)
        XCTAssertEqual(next.remainder, 0)
    }
}
