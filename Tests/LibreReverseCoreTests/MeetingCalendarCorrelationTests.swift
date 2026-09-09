import Foundation
import XCTest

@testable import LibreReverseCore

final class MeetingCalendarCorrelationTests: XCTestCase {
    func testCalendarSelectionStartsWithAllThenFreezesExplicitChoice() {
        let available: Set<String> = ["work", "personal"]
        let initial = LibreReverseMeetingCalendarSelection()
        XCTAssertEqual(initial.resolvedIDs(availableCalendarIDs: available), available)
        XCTAssertNil(initial.eventFilter)

        let updated = initial.updating(
            calendarID: "personal",
            enabled: false,
            availableCalendarIDs: available
        )
        XCTAssertEqual(updated.explicitCalendarIDs, ["work"])
        XCTAssertEqual(
            updated.resolvedIDs(availableCalendarIDs: available.union(["new"])),
            ["work"]
        )
    }

    func testCalendarSelectionRetainsUnavailableIDsAndCanonicalizesStorage() throws {
        let selection = LibreReverseMeetingCalendarSelection(
            explicitCalendarIDs: ["work", "detached", "work", ""]
        )
        XCTAssertEqual(selection.explicitCalendarIDs, ["detached", "work"])
        XCTAssertEqual(
            selection.resolvedIDs(availableCalendarIDs: ["work", "personal"]),
            ["work"]
        )
        let restored = try JSONDecoder().decode(
            LibreReverseMeetingCalendarSelection.self,
            from: JSONEncoder().encode(selection)
        )
        XCTAssertEqual(restored, selection)
    }

    func testCandidateDecodesPreCalendarJournal() throws {
        let data = Data(#"{"provider":"zoom","source":"windowDetection"}"#.utf8)
        let candidate = try JSONDecoder().decode(LibreReverseMeetingCandidate.self, from: data)
        XCTAssertEqual(candidate.provider, .zoom)
        XCTAssertNil(candidate.calendarID)
        XCTAssertNil(candidate.calendarParticipants)
    }

    func testRecoveredQueryWindowEndsAtLocalMidnightSevenDaysAhead() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 60 * 60)!
        let now = Date(timeIntervalSince1970: 1_704_117_845)
        let interval = LibreReverseMeetingCalendarCorrelation.queryInterval(
            at: now,
            calendar: calendar
        )
        XCTAssertEqual(interval.start, now)
        XCTAssertEqual(
            interval.end,
            calendar.startOfDay(for: now.addingTimeInterval(7 * 24 * 60 * 60))
        )
    }

    func testAllDayCanceledAndStaleEventsNeverCorrelate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            event("all-day", now: now, isAllDay: true),
            event("canceled", now: now, status: .canceled),
            event(
                "stale",
                now: now,
                start: -3_600,
                end: -1
            ),
        ]
        XCTAssertTrue(
            LibreReverseMeetingCalendarCorrelation.eligibleEvents(
                events,
                at: now
            ).isEmpty)
    }

    func testRecoveredCurrentEventBoundariesAreInclusiveAtOneMinuteAndEnd() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.currentEventStartLeeway,
            60
        )
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.eligibleEvents(
                [
                    event("starts-at-boundary", now: now, start: 60),
                    event("ends-at-boundary", now: now, start: -60, end: 0),
                ], at: now
            ).map(\.eventIdentifier),
            ["starts-at-boundary", "ends-at-boundary"]
        )
        XCTAssertTrue(
            LibreReverseMeetingCalendarCorrelation.eligibleEvents(
                [
                    event("starts-after-boundary", now: now, start: 60.001),
                    event("ended-before-boundary", now: now, start: -60, end: -0.001),
                ], at: now
            ).isEmpty
        )
    }

    func testURLlessFallbackUsesMinuteWhileExactRoomUsesHardenedWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        let exactCandidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            title: "Google Meet",
            url: room
        )
        let exactAtTenMinutes = event(
            "exact-ten-minutes",
            now: now,
            start: 600,
            end: 1_800,
            url: room
        )
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.correlate(
                candidates: [exactCandidate],
                events: [exactAtTenMinutes],
                at: now
            )[0].calendarEventID,
            "exact-ten-minutes"
        )

        let urlLessAtSixtyOne = event(
            "url-less-too-early",
            now: now,
            start: 61,
            end: 1_800
        )
        let fallbackCandidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 43,
            title: "Google Meet"
        )
        XCTAssertNil(
            LibreReverseMeetingCalendarCorrelation.correlate(
                candidates: [fallbackCandidate],
                events: [urlLessAtSixtyOne],
                at: now
            )[0].calendarEventID
        )
    }

    func testSingleCurrentEventEnrichesLiveWindowWithoutChangingIdentity() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            title: "Google Meet"
        )
        let result = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [candidate],
            events: [event("event-1", now: now)],
            at: now
        )[0]
        XCTAssertEqual(result.identity, candidate.identity)
        XCTAssertEqual(result.title, "Design Review")
        XCTAssertEqual(result.calendarEventID, "event-1")
        XCTAssertEqual(result.calendarID, "calendar-1")
        XCTAssertEqual(result.calendarSeriesID, "series-event-1")
        XCTAssertEqual(result.calendarParticipants, ["Ada", "Grace"])
    }

    func testAmbiguousCurrentEventsRequireUniqueProviderOrTitleEvidence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            title: "Quarterly Design Review — Google Meet"
        )
        let design = event(
            "design",
            now: now,
            title: "Quarterly Design Review",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let sales = event("sales", now: now, title: "Sales Forecast")
        let result = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [candidate],
            events: [sales, design],
            at: now
        )[0]
        XCTAssertEqual(result.calendarEventID, "design")

        let ambiguous = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [
                LibreReverseMeetingCandidate(
                    provider: .zoom,
                    source: .windowDetection,
                    windowID: 9,
                    title: "Zoom Meeting"
                )
            ],
            events: [sales, event("planning", now: now, title: "Planning")],
            at: now
        )[0]
        XCTAssertNil(ambiguous.calendarEventID)
    }

    func testCalendarAloneNeverManufacturesCaptureCandidate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.correlate(
                candidates: [],
                events: [event("event-1", now: now)],
                at: now
            ), [])
    }

    func testExactRoomWinsBackToBackBoundaryAndDifferentRoomFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetURL = URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            title: "Google Meet",
            url: targetURL
        )
        let outgoing = event(
            "outgoing",
            now: now,
            title: "Previous meeting",
            start: -1_800,
            end: 60
        )
        let target = event(
            "target",
            now: now,
            title: "Next meeting",
            start: 60,
            end: 1_860,
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let result = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [candidate],
            events: [outgoing, target],
            at: now
        )[0]
        XCTAssertEqual(result.calendarEventID, "target")

        let wrongRoom = event(
            "wrong",
            now: now,
            title: "Wrong room",
            url: URL(string: "https://meet.google.com/xyz-abcd-efg")
        )
        let failedClosed = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [candidate],
            events: [wrongRoom],
            at: now
        )[0]
        XCTAssertNil(failedClosed.calendarEventID)
    }

    func testMeetingURLIdentityKeepsRoomAndDropsTrackingParameters() {
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(
                URL(string: "https://acme.zoom.us/j/123456?pwd=secret")!
            ),
            "zoom:123456"
        )
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(
                URL(string: "https://meet.google.com/abc-defg-hij?authuser=2")!
            ),
            "google-meet:abc-defg-hij"
        )
        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(
                URL(string: "https://app.slack.com/huddle/T123/C456?thread_ts=private")!
            ),
            "slack-huddle:t123/c456"
        )
        XCTAssertNil(
            LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(
                URL(string: "https://app.slack.com/client/T123/C456")!
            )
        )
    }

    func testSlackHuddleCorrelationUsesExactRoomAndIgnoresProviderOnlyTitles() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetURL = URL(string: "https://app.slack.com/huddle/T123/C456")!
        let candidate = LibreReverseMeetingCandidate(
            provider: .slackHuddle,
            source: .windowDetection,
            windowID: 42,
            bundleIdentifier: "com.apple.Safari",
            title: "Slack Huddle",
            url: targetURL
        )
        let wrongRoom = event(
            "wrong-room",
            now: now,
            title: "Slack Huddle",
            url: URL(string: "https://app.slack.com/huddle/T123/C999")
        )
        let target = event(
            "target-room",
            now: now,
            title: "Design Review",
            start: 60,
            url: targetURL
        )

        XCTAssertEqual(
            LibreReverseMeetingCalendarCorrelation.correlate(
                candidates: [candidate],
                events: [wrongRoom, target],
                at: now
            )[0].calendarEventID,
            "target-room"
        )

        let urlLessCandidate = LibreReverseMeetingCandidate(
            provider: .slackHuddle,
            source: .windowDetection,
            windowID: 43,
            title: "Slack Huddle"
        )
        let ambiguous = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [urlLessCandidate],
            events: [
                event("first", now: now, title: "Slack Huddle"),
                event("second", now: now, title: "Slack Huddle notes"),
            ],
            at: now
        )[0]
        XCTAssertNil(ambiguous.calendarEventID)
    }

    func testRecurringSeriesChoosesCurrentOccurrenceAndPersistsSeriesIdentity() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = URL(string: "https://acme.zoom.us/j/123456")!
        let candidate = LibreReverseMeetingCandidate(
            provider: .zoomWeb,
            source: .windowDetection,
            windowID: 7,
            title: "Zoom Meeting",
            url: room
        )
        let prior = LibreReverseMeetingCalendarEvent(
            eventIdentifier: "occurrence-prior",
            seriesIdentifier: "series-weekly",
            calendarIdentifier: "work",
            calendarTitle: "Work",
            title: "Weekly planning",
            startDate: now.addingTimeInterval(-7 * 24 * 60 * 60),
            endDate: now.addingTimeInterval(-7 * 24 * 60 * 60 + 1_800),
            status: .confirmed,
            url: room
        )
        let current = LibreReverseMeetingCalendarEvent(
            eventIdentifier: "occurrence-current",
            seriesIdentifier: "series-weekly",
            calendarIdentifier: "work",
            calendarTitle: "Work",
            title: "Weekly planning",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(1_740),
            status: .confirmed,
            url: room
        )
        let result = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: [candidate],
            events: [prior, current],
            at: now
        )[0]
        XCTAssertEqual(result.calendarEventID, "occurrence-current")
        XCTAssertEqual(result.calendarSeriesID, "series-weekly")
    }

    private func event(
        _ id: String,
        now: Date,
        title: String = "Design Review",
        start: TimeInterval = -60,
        end: TimeInterval = 1_800,
        isAllDay: Bool = false,
        status: LibreReverseCalendarEventStatus = .confirmed,
        url: URL? = nil
    ) -> LibreReverseMeetingCalendarEvent {
        .init(
            eventIdentifier: id,
            seriesIdentifier: "series-\(id)",
            calendarIdentifier: "calendar-1",
            calendarTitle: "Work",
            title: title,
            startDate: now.addingTimeInterval(start),
            endDate: now.addingTimeInterval(end),
            isAllDay: isAllDay,
            status: status,
            participants: ["Ada", "Grace"],
            url: url
        )
    }
}
