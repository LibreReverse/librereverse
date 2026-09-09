import XCTest
@testable import LibreReverseCore

final class PlaybackAxisTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
    func snapshot(start: Double = 0) -> LibreReverseTimelineSnapshot {
        .init(rawSegments: [
            .init(startDate: date(start), endDate: date(600), bundleID: "screen", rawID: 1, rawType: .capturedScreen),
            .init(startDate: date(600), endDate: date(660), bundleID: "meeting", rawID: 2, rawType: .audio),
            .init(startDate: date(660), endDate: date(1000), bundleID: "screen", rawID: 3, rawType: .capturedScreen)
        ], playbackFrameDates: [date(0), date(120), date(600), date(900), date(1000)])
    }
    func testMeetingAndHistoryAdvanceAtEqualVisualSpeed() throws {
        let axis = snapshot()
        for (from, to, elapsed) in [(0.0,120.0,0.25), (120,600,0.25), (600,660,60), (660,900,0.25), (900,1000,0.25)] {
            let a = try XCTUnwrap(axis.contiguousOffset(atWallDate: date(from)))
            let b = try XCTUnwrap(axis.contiguousOffset(atWallDate: date(to)))
            XCTAssertEqual((b-a)/elapsed, 1, accuracy: 0.00001)
            for i in 0...60 {
                let offset = a + (b-a)*Double(i)/60
                let wall = try XCTUnwrap(axis.wallDate(atContiguousOffset: offset))
                XCTAssertEqual(try XCTUnwrap(axis.contiguousOffset(atWallDate: wall)), offset, accuracy: 0.00001)
            }
        }
    }
    func testChangingWindowStartPreservesSpacingInsideAFrameInterval() throws {
        let full = snapshot(), cropped = snapshot(start: 60)
        for axis in [full, cropped] {
            let a = try XCTUnwrap(axis.contiguousOffset(atWallDate: date(90)))
            let b = try XCTUnwrap(axis.contiguousOffset(atWallDate: date(120)))
            XCTAssertEqual(b-a, 0.0625, accuracy: 0.00001)
        }
    }
}
