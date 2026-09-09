#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseDailyRecapTests: XCTestCase {
    func testBuildClipsMergesAndRanksDailyActivityWithoutDoubleCounting() throws {
        let day = try date("2026-08-30T12:00:00.000")
        let segments = [
            segment(
                id: 1, start: "2026-08-29T23:50:00.000", end: "2026-08-30T00:20:00.000",
                bundleID: "com.example.Editor"),
            segment(
                id: 2, start: "2026-08-30T00:10:00.000", end: "2026-08-30T00:40:00.000",
                bundleID: "com.example.Editor"),
            segment(
                id: 3, start: "2026-08-30T01:00:00.000", end: "2026-08-30T02:00:00.000",
                bundleID: "com.example.Browser", browserURL: "https://Example.com/first"),
            segment(
                id: 4, start: "2026-08-30T01:30:00.000", end: "2026-08-30T02:30:00.000",
                bundleID: "com.example.Browser", browserURL: "example.com/second",
                type: .importedScreenshot),
            segment(
                id: 5, start: "2026-08-30T03:00:00.000", end: "2026-08-30T03:10:00.000",
                bundleID: nil),
            segment(
                id: 6, start: "2026-08-30T04:00:00.000", end: "2026-08-30T05:00:00.000",
                bundleID: "ai.rewind.audiorecorder", type: .audio),
            segment(
                id: 7, start: "2026-08-31T00:00:00.000", end: "2026-08-31T01:00:00.000",
                bundleID: "com.example.Future"),
        ]

        let recap = LibreReverseDailyRecapBuilder.build(
            day: day, segments: segments,
            applicationNames: ["com.example.Browser": "Browser", "com.example.Editor": "Editor"],
            calendar: calendar)

        XCTAssertEqual(recap.interval.start, try date("2026-08-30T00:00:00.000"))
        XCTAssertEqual(recap.interval.end, try date("2026-08-31T00:00:00.000"))
        XCTAssertEqual(recap.activeIntervals.count, 3)
        XCTAssertEqual(recap.totalActiveTime, 140 * 60)
        XCTAssertEqual(recap.applications.map(\.title), ["Browser", "Editor"])
        XCTAssertEqual(recap.applications.map(\.duration), [90 * 60, 40 * 60])
        XCTAssertEqual(recap.totalApplicationTime, 130 * 60)
        XCTAssertEqual(recap.websites.map(\.title), ["example.com"])
        XCTAssertEqual(recap.websites.map(\.duration), [90 * 60])
        XCTAssertEqual(recap.totalWebsiteTime, 90 * 60)
    }

    func testDayIntervalUsesCalendarBoundariesAcrossDaylightSavingTime() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        XCTAssertEqual(
            LibreReverseDailyRecapBuilder.dayInterval(
                containing: try localDate("2026-03-08T12:00:00", timeZone: eastern.timeZone),
                calendar: eastern
            ).duration, 23 * 60 * 60)
        XCTAssertEqual(
            LibreReverseDailyRecapBuilder.dayInterval(
                containing: try localDate("2026-11-01T12:00:00", timeZone: eastern.timeZone),
                calendar: eastern
            ).duration, 25 * 60 * 60)
    }

    func testDurationLabelsMatchCompactRecapPresentation() {
        XCTAssertEqual(LibreReverseDailyRecapBuilder.durationLabel(59), "0m")
        XCTAssertEqual(LibreReverseDailyRecapBuilder.durationLabel(13 * 60), "13m")
        XCTAssertEqual(LibreReverseDailyRecapBuilder.durationLabel(60 * 60), "1h")
        XCTAssertEqual(LibreReverseDailyRecapBuilder.durationLabel(11 * 60 * 60 + 20 * 60), "11h 20m")
    }

    func testMeetingMergeDeduplicatesRecordedEventsAndBuildsSevenDayUpcomingFeed() throws {
        let day = try date("2026-08-30T12:00:00.000")
        let now = try date("2026-08-30T10:00:00.000")
        let recorded = [
            LibreReverseDailyRecapMeeting(
                kind: .recorded,
                segmentID: 8,
                title: "Ad hoc standup",
                startDate: try date("2026-08-30T08:00:00.000"),
                endDate: try date("2026-08-30T08:20:00.000")
            ),
            LibreReverseDailyRecapMeeting(
                kind: .recorded,
                segmentID: 9,
                calendarEventID: "duplicate",
                title: "Recorded planning",
                startDate: try date("2026-08-30T09:00:00.000"),
                endDate: try date("2026-08-30T09:30:00.000")
            ),
        ]
        let events = [
            calendarEvent(
                id: "past", title: "Past unrecorded", start: "2026-08-30T07:00:00.000",
                end: "2026-08-30T08:00:00.000"),
            calendarEvent(
                id: "duplicate", title: "Calendar planning", start: "2026-08-30T09:00:00.000",
                end: "2026-08-30T09:30:00.000"),
            calendarEvent(
                id: "today", title: "Customer call", start: "2026-08-30T11:00:00.000",
                end: "2026-08-30T12:00:00.000"),
            calendarEvent(
                id: "future", title: "Friday review", start: "2026-09-04T15:00:00.000",
                end: "2026-09-04T16:00:00.000"),
            calendarEvent(
                id: "outside", title: "Outside horizon", start: "2026-09-06T10:00:00.000",
                end: "2026-09-06T11:00:00.000"),
            calendarEvent(
                id: "canceled", title: "Canceled", start: "2026-08-30T13:00:00.000",
                end: "2026-08-30T14:00:00.000", status: .canceled),
            calendarEvent(
                id: "all-day", title: "All day", start: "2026-08-30T00:00:00.000",
                end: "2026-08-31T00:00:00.000", isAllDay: true),
        ]
        let recap = LibreReverseDailyRecapBuilder.build(
            day: day,
            segments: [],
            recordedMeetings: recorded,
            calendarEvents: events,
            upcomingInterval: DateInterval(
                start: try date("2026-08-30T00:00:00.000"),
                end: try date("2026-09-06T00:00:00.000")
            ),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(recap.recordedMeetings.map(\.segmentID), [9, 8])
        XCTAssertEqual(recap.upcomingMeetings.map(\.calendarEventID), ["today", "future"])
        XCTAssertEqual(recap.upcomingMeetings.map(\.title), ["Customer call", "Friday review"])
        XCTAssertEqual(recap.totalCalendarEventTime, 2.5 * 60 * 60)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func segment(
        id: Int64, start: String, end: String, bundleID: String?, browserURL: String? = nil,
        type: SegmentType = .capturedScreen
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: try! date(start), endDate: try! date(end), bundleID: bundleID,
            browserURL: browserURL, rawID: id, rawType: type)
    }

    private func calendarEvent(
        id: String,
        title: String,
        start: String,
        end: String,
        status: LibreReverseCalendarEventStatus = .confirmed,
        isAllDay: Bool = false
    ) -> LibreReverseMeetingCalendarEvent {
        LibreReverseMeetingCalendarEvent(
            eventIdentifier: id,
            calendarIdentifier: "work",
            calendarTitle: "Work",
            title: title,
            startDate: try! date(start),
            endDate: try! date(end),
            isAllDay: isAllDay,
            status: status,
            participants: ["Ada"],
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(Self.formatter.date(from: value))
    }

    private func localDate(_ value: String, timeZone: TimeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return try XCTUnwrap(formatter.date(from: value))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()
}
#endif
