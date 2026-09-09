import XCTest
import LibreReverseCore

final class TimelinePresentationLifecycleTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1000 + seconds) }

    private func segment(_ end: Double) -> TimelineSegment {
        .init(startDate: date(0), endDate: date(end), bundleID: "editor",
              rawID: 1, rawType: .capturedScreen)
    }

    private func presentation() throws -> PlaybackTimelinePresentation {
        try XCTUnwrap(.init(window: .init(segments: [segment(100)],
            validSeekInterval: .init(start: date(0), end: date(100)),
            playbackFrameDates: stride(from: 0.0, through: 100.0, by: 10).map(date))))
    }

    private func admission(_ seconds: Double) -> LibreReverseAdmittedFrame {
        .init(id: Int64(seconds), segmentID: 1, segment: segment(seconds),
              createdAt: date(seconds), imageFileName: "fixture", context: nil, encodingStatus: "complete")
    }

    func testDecorationsUpdateWithoutChangingCoordinates() throws {
        let original = try presentation()
        let starred = original.withStarredDates([date(50)])
        XCTAssertEqual(starred.snapshot.starredFrames.count, 1)
        XCTAssertEqual(starred.withStarredDates([]).snapshot.starredFrames.count, 0)
        XCTAssertEqual(original.snapshot.contiguousOffset(atWallDate: date(50)),
                       starred.snapshot.contiguousOffset(atWallDate: date(50)))
        XCTAssertEqual(original.interval, starred.interval)
    }

    func testMissingArchiveTimingRetainsAxisAndRefreshesDecorations() throws {
        let original = try presentation()
        let unavailable = HistoricalTimelineSegmentWindow(segments: [segment(500)],
            validSeekInterval: .init(start: date(0), end: date(500)))
        let retained = original.refreshed(window: unavailable, starredDates: [date(50)])
        XCTAssertEqual(retained.interval, original.interval)
        XCTAssertEqual(retained.frameDates, original.frameDates)
        XCTAssertEqual(retained.snapshot.contiguousDuration, original.snapshot.contiguousDuration)
        XCTAssertEqual(retained.snapshot.starredFrames.count, 1)
        XCTAssertFalse(retained.includesLiveTail)
    }

    func testLiveWindowRemainsBoundedAcrossRepeatedUpdatesOfOneLongSegment() throws {
        var value = try presentation()
        for second in stride(from: 110.0, through: 1000.0, by: 10) {
            value = value.appending(admittedFrame: admission(second), maximumDuration: 100)
            XCTAssertLessThanOrEqual(value.frameDates.count, 11)
            XCTAssertEqual(value.interval.duration, 100, accuracy: 0.000001)
        }
        XCTAssertEqual(value.interval.start, date(900))
        XCTAssertTrue(value.includesLiveTail)
    }

    func testTrimmingPreservesDistancesAndRetainsPrecedingFrame() throws {
        let original = try presentation()
        let updated = original.appending(admittedFrame: admission(110), maximumDuration: 45)
        XCTAssertEqual(updated.frameDates.first, date(60))
        func distance(_ value: PlaybackTimelinePresentation) throws -> Double {
            try XCTUnwrap(value.snapshot.contiguousOffset(atWallDate: date(85)))
                - XCTUnwrap(value.snapshot.contiguousOffset(atWallDate: date(65)))
        }
        XCTAssertEqual(try distance(original), try distance(updated), accuracy: 0.000001)
    }

    func testOldHistoricalSelectionFreezesInsteadOfBeingEvicted() throws {
        let original = try presentation()
        let frozen = original.appending(admittedFrame: admission(110),
            retaining: date(20), maximumDuration: 45)
        XCTAssertEqual(frozen.interval, original.interval)
        XCTAssertEqual(frozen.frameDates, original.frameDates)
        XCTAssertTrue(frozen.contains(date(20)))
        XCTAssertFalse(frozen.includesLiveTail)
        XCTAssertEqual(frozen.snapshot.validSeekInterval?.end, date(110))
    }

    func testTrimmingKeepsMeetingMediaOriginAndRealTimeSpacing() throws {
        let meeting = TimelineSegment(startDate: date(20), endDate: date(90),
            bundleID: "meeting", rawID: 2, rawType: .audio)
        let original = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(
            segments: [segment(100), meeting],
            validSeekInterval: .init(start: date(0), end: date(100)),
            playbackFrameDates: stride(from: 0.0, through: 100.0, by: 10).map(date))))
        let updated = original.appending(admittedFrame: admission(110), maximumDuration: 45)
        XCTAssertEqual(updated.snapshot.rawAudioSegments.first?.startDate, date(20))
        let start = try XCTUnwrap(updated.snapshot.contiguousOffset(atWallDate: date(65)))
        let end = try XCTUnwrap(updated.snapshot.contiguousOffset(atWallDate: date(85)))
        XCTAssertEqual(end - start, 20, accuracy: 0.000001)
    }
}
