import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class TimelineEndScrollPolicyTests: XCTestCase {
    func testHiddenLaneConsumesForwardDistanceAndReversesWithoutMovingHistory() {
        var policy = TimelineEndScrollPolicy()
        XCTAssertEqual(policy.advance(atLiveEdge: false, pixels: 100, momentum: false).history, 100)
        XCTAssertFalse(policy.advance(atLiveEdge: true, pixels: 40, momentum: false).exit)
        XCTAssertEqual(policy.advance(atLiveEdge: true, pixels: -20, momentum: false).history, 0)
        XCTAssertEqual(policy.advance(atLiveEdge: true, pixels: -30, momentum: false).history, -10)
        XCTAssertTrue(policy.advance(atLiveEdge: true, pixels: 80, momentum: false).exit)
    }

    func testMomentumCannotExitOrUnpinAndBackwardFromNowIsImmediate() {
        var policy = TimelineEndScrollPolicy()
        XCTAssertFalse(policy.advance(atLiveEdge: true, pixels: 1000, momentum: true).exit)
        XCTAssertEqual(policy.offset, 0)
        XCTAssertEqual(policy.advance(atLiveEdge: true, pixels: -12, momentum: false).history, -12)
    }

    func testLivePublicationExtendsAxisWithoutChangingEarlierCoordinates() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let oldEnd = start.addingTimeInterval(10)
        let newEnd = start.addingTimeInterval(12)
        let first = TimelineSegment(startDate: start, endDate: oldEnd, bundleID: "a", rawID: 1, rawType: .capturedScreen)
        let presentation = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(segments: [first],
            validSeekInterval: .init(start: start, end: oldEnd), playbackFrameDates: [start, oldEnd])))
        let extended = presentation.appending(admittedFrame: .init(id: 2, segmentID: 1,
            segment: .init(startDate: start, endDate: newEnd, bundleID: "a", rawID: 1, rawType: .capturedScreen),
            createdAt: newEnd, imageFileName: "", context: nil, encodingStatus: "pending"))
        XCTAssertEqual(extended.interval.end, newEnd)
        XCTAssertEqual(extended.snapshot.contiguousOffset(atWallDate: oldEnd), presentation.snapshot.contiguousOffset(atWallDate: oldEnd))
        XCTAssertEqual(extended.snapshot.wallDate(atContiguousOffset: extended.snapshot.contiguousDuration), newEnd)
    }

    func testAppHandoffHasOnlyFixedDrawingGutterAtEveryZoom() {
        let start = Date(timeIntervalSince1970: 1000)
        let segments: [TimelineSegment] = [
            .init(startDate: start, endDate: start.addingTimeInterval(1), bundleID: "a", contiguousStartOffset: 0, contiguousEndOffset: 0.2, rawID: 1, rawType: .capturedScreen),
            .init(startDate: start.addingTimeInterval(2), endDate: start.addingTimeInterval(3), bundleID: "b", contiguousStartOffset: 0.25, contiguousEndOffset: 0.5, rawID: 2, rawType: .capturedScreen)
        ]
        let groups = LibreReverseTimelinePresentationPolicy.appGroups(segments)
        for zoom: Float in [20, 60, 90] {
            let scale = LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: zoom)
            XCTAssertEqual((groups[1].segments[0].contiguousStartOffset! - groups[0].segments[0].contiguousEndOffset!) * scale, 0)
        }
        XCTAssertEqual(groups[0].segments[0].endDate, segments[0].endDate)
        XCTAssertEqual(segments[0].contiguousEndOffset, 0.2)
    }
}
