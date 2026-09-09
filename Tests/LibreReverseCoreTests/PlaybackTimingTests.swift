import XCTest

@testable import LibreReverseCore

final class PlaybackTimingTests: XCTestCase {
    func testIntegralFrameRateUsesOneOverFourTimesRate() {
        XCTAssertEqual(
            PlaybackTiming.seekTolerance(frameRate: 30),
            .init(value: 1, timescale: 120)
        )
    }

    func testHalfIntegralFrameRateUsesMultiplierTwo() {
        XCTAssertEqual(
            PlaybackTiming.seekTolerance(frameRate: 29.5),
            .init(value: 2, timescale: 236)
        )
    }

    func testOtherFrameRateUsesMultiplierOneThousandAndTruncatesTimescale() {
        XCTAssertEqual(
            PlaybackTiming.seekTolerance(frameRate: 29.97),
            .init(value: 1_000, timescale: 119_880)
        )
    }

    func testInvalidFrameRatesHaveNoTolerance() {
        XCTAssertNil(PlaybackTiming.seekTolerance(frameRate: 0))
        XCTAssertNil(PlaybackTiming.seekTolerance(frameRate: -.infinity))
        XCTAssertNil(PlaybackTiming.seekTolerance(frameRate: .nan))
    }

    func testMeetingPlaybackUsesElapsedWallTimeInsteadOfAnchorFrame() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            LibreReverseMeetingPlaybackTiming.mediaTime(
                requestedDate: start.addingTimeInterval(37),
                segmentStartDate: start,
                segmentType: .audio,
                anchorFrameIndex: 0,
                frameRate: 60
            ),
            37
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackTiming.mediaTime(
                requestedDate: start.addingTimeInterval(-2),
                segmentStartDate: start,
                segmentType: .audio,
                anchorFrameIndex: 0,
                frameRate: 60
            ),
            0
        )
    }

    func testWallClockPlaybackUsesActualElapsedTimeInsteadOfTimerCount() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = LibreReverseWallClockPlaybackClock(
            startWallDate: start,
            startUptimeNanoseconds: 9_000_000_000
        )

        XCTAssertEqual(clock.wallDate(at: 8_000_000_000), start)
        XCTAssertEqual(clock.wallDate(at: 9_250_000_000), start.addingTimeInterval(0.25))
        XCTAssertEqual(clock.wallDate(at: 12_750_000_000), start.addingTimeInterval(3.75))
    }

    func testWallClockPlaybackCanRebaseAfterClampingToAChildBoundary() {
        let boundary = Date(timeIntervalSince1970: 1_700_000_011)
        let rebased = LibreReverseWallClockPlaybackClock(
            startWallDate: boundary,
            startUptimeNanoseconds: 20_500_000_000
        )

        XCTAssertEqual(
            rebased.wallDate(at: 20_750_000_000),
            boundary.addingTimeInterval(0.25)
        )
    }

    func testMeetingPlaybackControlRequiresReadyMediaButKeepsPauseReachable() {
        XCTAssertFalse(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: false,
                isActive: true,
                mediaAvailable: true
            ))
        XCTAssertFalse(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: true,
                isActive: false,
                mediaAvailable: false
            ))
        XCTAssertTrue(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: true,
                isActive: false,
                mediaAvailable: true
            ))
        XCTAssertTrue(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: true,
                isActive: true,
                mediaAvailable: false
            ))
    }

    func testMeetingPlaybackShortcutUsesTheSameMediaReadinessGate() {
        XCTAssertEqual(
            LibreReverseMeetingPlaybackControlPolicy.toggleDecision(
                hasPresentedPlayer: true,
                isActive: false,
                mediaAvailable: false
            ),
            .ignore
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackControlPolicy.toggleDecision(
                hasPresentedPlayer: false,
                isActive: false,
                mediaAvailable: true
            ),
            .ignore
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackControlPolicy.toggleDecision(
                hasPresentedPlayer: true,
                isActive: false,
                mediaAvailable: true
            ),
            .start
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackControlPolicy.toggleDecision(
                hasPresentedPlayer: false,
                isActive: true,
                mediaAvailable: false
            ),
            .stop
        )
    }

    func testPrimaryReplacementInvalidatesReadinessEvenWithARetainedPlayer() {
        var readiness = LibreReverseMeetingPlaybackReadiness()
        readiness.mediaDidBecomeReady()
        XCTAssertEqual(
            readiness.toggleDecision(
                hasPresentedPlayer: true,
                isActive: false
            ),
            .start
        )

        readiness.invalidate()
        XCTAssertEqual(
            readiness.toggleDecision(
                hasPresentedPlayer: true,
                isActive: false
            ),
            .ignore
        )
        XCTAssertEqual(
            readiness.toggleDecision(
                hasPresentedPlayer: true,
                isActive: true
            ),
            .stop
        )
    }

    func testHistoricalReloadRetainsMeetingButLiveOrPositionlessReloadDoesNot() {
        let seekDate = Date(timeIntervalSince1970: 1_700_000_123)
        XCTAssertEqual(
            LibreReverseMeetingReloadSelectionPolicy.retainedSegmentID(
                startAtLiveEdge: false,
                preservedSeekDate: seekDate,
                preservedSegmentID: 42
            ),
            42
        )
        XCTAssertNil(
            LibreReverseMeetingReloadSelectionPolicy.retainedSegmentID(
                startAtLiveEdge: true,
                preservedSeekDate: seekDate,
                preservedSegmentID: 42
            )
        )
        XCTAssertNil(
            LibreReverseMeetingReloadSelectionPolicy.retainedSegmentID(
                startAtLiveEdge: false,
                preservedSeekDate: nil,
                preservedSegmentID: 42
            )
        )
        XCTAssertNil(
            LibreReverseMeetingReloadSelectionPolicy.retainedSegmentID(
                startAtLiveEdge: false,
                preservedSeekDate: seekDate,
                preservedSegmentID: nil
            )
        )
    }

    func testHistoricalReloadFetchesAroundSelectionWhileLiveReloadFetchesRecent() {
        let seekDate = Date(timeIntervalSince1970: 1_700_000_123)
        XCTAssertEqual(
            LibreReverseTimelineReloadRequest.make(
                startAtLiveEdge: false,
                preservedSeekDate: seekDate,
                lastFetchedDuration: 900,
                defaultDuration: 600
            ),
            .around(date: seekDate, duration: 900)
        )
        XCTAssertEqual(
            LibreReverseTimelineReloadRequest.make(
                startAtLiveEdge: true,
                preservedSeekDate: seekDate,
                lastFetchedDuration: 900,
                defaultDuration: 600
            ),
            .recent(duration: 900)
        )
        XCTAssertEqual(
            LibreReverseTimelineReloadRequest.make(
                startAtLiveEdge: false,
                preservedSeekDate: nil,
                lastFetchedDuration: .nan,
                defaultDuration: 600
            ),
            .recent(duration: 600)
        )
    }
}
