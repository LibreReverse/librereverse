import XCTest

@testable import LibreReverseCore

final class MeetingPlaybackLifecycleTests: XCTestCase {
    func testHistoricalPlaybackSkipsGapsAndCrossesBothMediaKinds() throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        func segment(_ start: Double, _ end: Double, _ id: Int64,
            _ type: SegmentType) -> TimelineSegment {
            .init(startDate: origin.addingTimeInterval(start), endDate: origin.addingTimeInterval(end),
                bundleID: type == .audio ? "meeting" : "screen", rawID: id, rawType: type)
        }
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [
            segment(0, 2, 1, .capturedScreen), segment(10, 12, 2, .capturedScreen),
            segment(20, 24, 3, .audio), segment(30, 32, 4, .capturedScreen)
        ])
        for (from, to) in [(1.5, 10.5), (11.5, 20.5), (23.5, 30.5)] {
            let result = try XCTUnwrap(LibreReverseTimelinePlaybackNavigation.advance(
                from: origin.addingTimeInterval(from), elapsed: 1, snapshot: snapshot))
            XCTAssertEqual(result.timeIntervalSince(origin), to, accuracy: 0.001)
        }
    }

    func testSparseHistoryUsesChangeCadenceInsteadOfObservedDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        for gap in [1.0, 60.0, 3600.0] {
            let step = LibreReverseHistoryPlaybackStep(start: start,
                end: start.addingTimeInterval(gap), startUptimeNanoseconds: 0)
            XCTAssertEqual(step.wallDate(at: 125_000_000).timeIntervalSince(start), gap / 2,
                accuracy: 0.0001)
            XCTAssertFalse(step.isComplete(at: 249_000_000))
            XCTAssertTrue(step.isComplete(at: 250_000_000))
            XCTAssertEqual(step.wallDate(at: 1_000_000_000), step.end)
        }
    }

    func testHistoryCannotStepOverMeetingEntryOrRepeatItsCurrentFrame() {
        let date = Date(timeIntervalSince1970: 1000)
        let meeting = date.addingTimeInterval(10)
        XCTAssertEqual(LibreReverseHistoryPlaybackStep.nextDate(after: date,
            frameDate: date.addingTimeInterval(60), meetingStart: meeting), meeting)
        XCTAssertEqual(LibreReverseHistoryPlaybackStep.nextDate(after: date,
            frameDate: date, meetingStart: meeting), meeting)
        XCTAssertNil(LibreReverseHistoryPlaybackStep.nextDate(after: date,
            frameDate: date, meetingStart: nil))
        // Meeting completion resumes at the next change, skipping idle wall time.
        XCTAssertEqual(LibreReverseHistoryPlaybackStep.nextDate(after: meeting,
            frameDate: date.addingTimeInterval(60), meetingStart: meeting),
            date.addingTimeInterval(60))
    }

    private let following = LibreReverseTimelineSnapshot.MeetingSelection(
        segmentID: 22,
        seekDate: Date(timeIntervalSince1970: 1_700_000_022)
    )

    func testInactiveAndSupersededItemEventsCannotMutatePlayback() {
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .failed,
                playbackIsActive: false,
                ownsPresentedItem: true,
                followingSelection: following
            ),
            .ignore
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .ended,
                playbackIsActive: true,
                ownsPresentedItem: false,
                followingSelection: following
            ),
            .ignore
        )
    }

    func testOwnedEndAdvancesToFollowingMergedChildOrStopsAtMeetingEnd() {
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .ended,
                playbackIsActive: true,
                ownsPresentedItem: true,
                followingSelection: following
            ),
            .advance(following)
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .ended,
                playbackIsActive: true,
                ownsPresentedItem: true,
                followingSelection: nil
            ),
            .stopAtMeetingEnd
        )
    }

    func testStallRemainsRetryableButFailureRevokesReadiness() {
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .stalled,
                playbackIsActive: true,
                ownsPresentedItem: true,
                followingSelection: nil
            ),
            .pauseForRetry
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.action(
                for: .failed,
                playbackIsActive: true,
                ownsPresentedItem: true,
                followingSelection: nil
            ),
            .stopAndInvalidate
        )
    }

    func testWallClockOnlyAdvancesWithRealPlayerMotion() {
        XCTAssertTrue(
            LibreReverseMeetingPlaybackItemPolicy.shouldAdvanceWallClock(
                playerIsPlaying: true
            )
        )
        XCTAssertFalse(
            LibreReverseMeetingPlaybackItemPolicy.shouldAdvanceWallClock(
                playerIsPlaying: false
            )
        )
    }

    func testFailureSurfaceUsesExactPersistedStillOrExplicitErrorOnlyState() {
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.failureSurface(
                hasPersistedStill: true
            ),
            .persistedStill
        )
        XCTAssertEqual(
            LibreReverseMeetingPlaybackItemPolicy.failureSurface(
                hasPersistedStill: false
            ),
            .errorOnly
        )
    }

    func testPlaybackNoticeIsSegmentScopedAndSurvivesSameTranscriptRefresh() {
        var state = LibreReverseMeetingPlaybackNoticeState()
        XCTAssertFalse(
            state.present(
                .failedDuringPlayback,
                for: 10,
                selectedSegmentID: 11
            )
        )
        XCTAssertNil(state.notice)

        XCTAssertTrue(
            state.present(
                .failedDuringPlayback,
                for: 10,
                selectedSegmentID: 10
            )
        )
        state.transcriptDidPresent(segmentID: 10)
        XCTAssertEqual(
            state.notice,
            .init(segmentID: 10, kind: .failedDuringPlayback)
        )

        state.transcriptDidPresent(segmentID: 11)
        XCTAssertNil(state.notice)
    }

    func testFailedNoticeBecomesSingleInFlightRetryUntilMediaIsReady() {
        var state = LibreReverseMeetingPlaybackNoticeState(
            notice: .init(segmentID: 10, kind: .failedToPrepare)
        )
        XCTAssertTrue(state.retryDidBegin(segmentID: 10))
        XCTAssertEqual(state.notice, .init(segmentID: 10, kind: .retrying))
        XCTAssertFalse(state.retryDidBegin(segmentID: 10))

        state.mediaDidBecomeReady(segmentID: 11)
        XCTAssertEqual(state.notice, .init(segmentID: 10, kind: .retrying))
        state.mediaDidBecomeReady(segmentID: 10)
        XCTAssertNil(state.notice)
    }

    func testStallOffersDirectPlaybackRetryInsteadOfMediaReload() {
        XCTAssertFalse(LibreReverseMeetingPlaybackNoticeKind.stalled.offersMediaReload)
        XCTAssertTrue(LibreReverseMeetingPlaybackNoticeKind.failedToPrepare.offersMediaReload)
        XCTAssertTrue(LibreReverseMeetingPlaybackNoticeKind.failedDuringPlayback.offersMediaReload)

        var state = LibreReverseMeetingPlaybackNoticeState(
            notice: .init(segmentID: 10, kind: .stalled)
        )
        XCTAssertFalse(state.retryDidBegin(segmentID: 10))
        XCTAssertEqual(state.notice, .init(segmentID: 10, kind: .stalled))
    }
}
