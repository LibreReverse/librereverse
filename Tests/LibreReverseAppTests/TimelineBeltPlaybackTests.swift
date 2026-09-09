import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineBeltPlaybackTests: XCTestCase {
    func testControllerMaintainsBeltSpeedWhileHistoryMediaIsPending() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let window = HistoricalTimelineSegmentWindow(segments: [
            .init(startDate: start, endDate: start.addingTimeInterval(600), bundleID: "app", rawID: 1, rawType: .capturedScreen),
            .init(startDate: start.addingTimeInterval(600), endDate: start.addingTimeInterval(660), bundleID: "meeting", rawID: 2, rawType: .audio)
        ], validSeekInterval: DateInterval(start: start, duration: 660),
            playbackFrameDates: [start, start.addingTimeInterval(120), start.addingTimeInterval(600)])
        let offsets = probeHistoryBelt(window: window)
        for (actual, expected) in zip(offsets, [0.0, 0.1, 0.2, 0.3, 0.4]) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
        let presentation = try XCTUnwrap(PlaybackTimelinePresentation(window: window))
        let boundary = try XCTUnwrap(TimelineBeltPlayback.position(from: start, elapsed: 0.6, snapshot: presentation.snapshot))
        XCTAssertEqual(boundary.date, start.addingTimeInterval(600))
        XCTAssertEqual(boundary.meetingID, 2)
        for zoom: Float in [20, 60, 90] {
            let scale = LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: zoom)
            let historyPixels = (offsets[4] - offsets[3]) * scale
            let meetingStart = try XCTUnwrap(presentation.snapshot.contiguousOffset(atWallDate: start.addingTimeInterval(610)))
            let meetingEnd = try XCTUnwrap(presentation.snapshot.contiguousOffset(atWallDate: start.addingTimeInterval(610.1)))
            XCTAssertEqual(historyPixels, (meetingEnd-meetingStart)*scale, accuracy: 0.0001)
        }
    }
}
