import Foundation

public struct LibreReverseDailyRecapActivity: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case application(bundleID: String)
        case website(host: String)
    }

    public let kind: Kind
    public let title: String
    public let duration: TimeInterval

    public init(kind: Kind, title: String, duration: TimeInterval) {
        self.kind = kind
        self.title = title
        self.duration = max(0, duration)
    }

    public var id: String {
        switch kind {
        case .application(let bundleID): "app:\(bundleID)"
        case .website(let host): "web:\(host)"
        }
    }
}

public struct LibreReverseDailyRecapMeeting: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case recorded
        case calendar
    }

    public let kind: Kind
    public let segmentID: Int64?
    public let calendarEventID: String?
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let calendarTitle: String?
    public let participants: [String]
    public let meetingURL: URL?

    public init(
        kind: Kind,
        segmentID: Int64? = nil,
        calendarEventID: String? = nil,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarTitle: String? = nil,
        participants: [String] = [],
        meetingURL: URL? = nil
    ) {
        self.kind = kind
        self.segmentID = segmentID
        self.calendarEventID = calendarEventID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Meeting"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startDate = startDate
        self.endDate = max(startDate, endDate)
        self.calendarTitle = calendarTitle
        self.participants = participants
        self.meetingURL = meetingURL
    }

    public var id: String {
        if let segmentID { return "recorded:\(segmentID)" }
        if let calendarEventID { return "calendar:\(calendarEventID)" }
        return "calendar:\(startDate.timeIntervalSinceReferenceDate):\(title)"
    }
}

public struct LibreReverseDailyRecap: Equatable, Sendable {
    public let day: Date
    public let interval: DateInterval
    public let activeIntervals: [DateInterval]
    public let applications: [LibreReverseDailyRecapActivity]
    public let websites: [LibreReverseDailyRecapActivity]
    public let recordedMeetings: [LibreReverseDailyRecapMeeting]
    public let upcomingMeetings: [LibreReverseDailyRecapMeeting]
    public let totalActiveTime: TimeInterval
    public let totalApplicationTime: TimeInterval
    public let totalWebsiteTime: TimeInterval
    public let totalCalendarEventTime: TimeInterval

    public init(
        day: Date, interval: DateInterval, activeIntervals: [DateInterval],
        applications: [LibreReverseDailyRecapActivity], websites: [LibreReverseDailyRecapActivity],
        recordedMeetings: [LibreReverseDailyRecapMeeting] = [],
        upcomingMeetings: [LibreReverseDailyRecapMeeting] = [],
        totalActiveTime: TimeInterval, totalApplicationTime: TimeInterval,
        totalWebsiteTime: TimeInterval, totalCalendarEventTime: TimeInterval = 0
    ) {
        self.day = day
        self.interval = interval
        self.activeIntervals = activeIntervals
        self.applications = applications
        self.websites = websites
        self.recordedMeetings = recordedMeetings
        self.upcomingMeetings = upcomingMeetings
        self.totalActiveTime = max(0, totalActiveTime)
        self.totalApplicationTime = max(0, totalApplicationTime)
        self.totalWebsiteTime = max(0, totalWebsiteTime)
        self.totalCalendarEventTime = max(0, totalCalendarEventTime)
    }
}

public enum LibreReverseDailyRecapBuilder {
    public static func dayInterval(containing day: Date, calendar: Calendar = .current)
        -> DateInterval
    {
        if let interval = calendar.dateInterval(of: .day, for: day) { return interval }
        let start = calendar.startOfDay(for: day)
        return DateInterval(start: start, duration: 86_400)
    }

    public static func build(
        day: Date, segments: [TimelineSegment], applicationNames: [String: String] = [:],
        recordedMeetings: [LibreReverseDailyRecapMeeting] = [],
        calendarEvents: [LibreReverseMeetingCalendarEvent] = [],
        upcomingInterval: DateInterval? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LibreReverseDailyRecap {
        let dayInterval = dayInterval(containing: day, calendar: calendar)
        let activitySegments = segments.compactMap { segment -> ClippedSegment? in
            guard segment.rawType == .capturedScreen || segment.rawType == .importedScreenshot,
                segment.endDate > segment.startDate,
                let interval = clipped(
                    DateInterval(start: segment.startDate, end: segment.endDate), to: dayInterval)
            else { return nil }
            return ClippedSegment(segment: segment, interval: interval)
        }.sorted {
            if $0.interval.start != $1.interval.start {
                return $0.interval.start < $1.interval.start
            }
            if $0.interval.end != $1.interval.end { return $0.interval.end < $1.interval.end }
            return $0.segment.rawID < $1.segment.rawID
        }

        let activeIntervals = merge(activitySegments.map(\.interval))
        var appIntervals: [String: [DateInterval]] = [:]
        var webIntervals: [String: [DateInterval]] = [:]
        for item in activitySegments {
            if let bundleID = normalized(item.segment.bundleID) {
                appIntervals[bundleID, default: []].append(item.interval)
            }
            if let host = TimelineSegmentProcessor.websiteHost(
                for: item.segment.browserURL)?.lowercased(), !host.isEmpty
            {
                webIntervals[host, default: []].append(item.interval)
            }
        }

        let applications = appIntervals.map { bundleID, intervals in
            LibreReverseDailyRecapActivity(
                kind: .application(bundleID: bundleID),
                title: applicationNames[bundleID]
                    ?? LibreReverseRecordedApplication(bundleID: bundleID).fallbackDisplayName,
                duration: merge(intervals).reduce(0) { $0 + $1.duration })
        }.sorted(by: activityOrder)
        let websites = webIntervals.map { host, intervals in
            LibreReverseDailyRecapActivity(
                kind: .website(host: host), title: host,
                duration: merge(intervals).reduce(0) { $0 + $1.duration })
        }.sorted(by: activityOrder)
        let meetings = mergeMeetings(
            recorded: recordedMeetings,
            calendarEvents: calendarEvents,
            dayInterval: dayInterval,
            upcomingInterval: upcomingInterval ?? dayInterval,
            now: now
        )

        return LibreReverseDailyRecap(
            day: dayInterval.start, interval: dayInterval, activeIntervals: activeIntervals,
            applications: applications, websites: websites,
            recordedMeetings: meetings.recorded,
            upcomingMeetings: meetings.upcoming,
            totalActiveTime: activeIntervals.reduce(0) { $0 + $1.duration },
            totalApplicationTime: applications.reduce(0) { $0 + $1.duration },
            totalWebsiteTime: websites.reduce(0) { $0 + $1.duration },
            totalCalendarEventTime: meetings.calendarIntervals.reduce(0) { $0 + $1.duration }
        )
    }

    public static func durationLabel(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, let minutes): return "\(minutes)m"
        case (let hours, 0): return "\(hours)h"
        default: return "\(hours)h \(minutes)m"
        }
    }

    private struct ClippedSegment {
        let segment: TimelineSegment
        let interval: DateInterval
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    private static func clipped(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval?
    {
        let start = max(interval.start, bounds.start)
        let end = min(interval.end, bounds.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }) {
            guard let previous = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= previous.end {
                result[result.count - 1] = DateInterval(
                    start: previous.start, end: max(previous.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func activityOrder(
        _ lhs: LibreReverseDailyRecapActivity, _ rhs: LibreReverseDailyRecapActivity
    ) -> Bool {
        if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func mergeMeetings(
        recorded: [LibreReverseDailyRecapMeeting],
        calendarEvents: [LibreReverseMeetingCalendarEvent],
        dayInterval: DateInterval,
        upcomingInterval: DateInterval,
        now: Date
    ) -> (
        recorded: [LibreReverseDailyRecapMeeting],
        upcoming: [LibreReverseDailyRecapMeeting],
        calendarIntervals: [DateInterval]
    ) {
        let recorded = recorded.filter {
            $0.kind == .recorded && $0.endDate > dayInterval.start
                && $0.startDate < dayInterval.end
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
            return $0.id < $1.id
        }
        let recordedCalendarIDs = Set(recorded.compactMap(\.calendarEventID))
        let dayCalendarEvents = calendarEvents.filter {
            !$0.isAllDay && $0.status != .canceled && $0.endDate > dayInterval.start
                && $0.startDate < dayInterval.end
        }
        let upcomingCalendarEvents = calendarEvents.filter {
            !$0.isAllDay && $0.status != .canceled && $0.endDate > upcomingInterval.start
                && $0.startDate < upcomingInterval.end
        }
        let upcoming = upcomingCalendarEvents.compactMap { event
            -> LibreReverseDailyRecapMeeting? in
            guard event.endDate >= now,
                !recordedCalendarIDs.contains(event.eventIdentifier)
            else { return nil }
            return LibreReverseDailyRecapMeeting(
                kind: .calendar,
                calendarEventID: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                calendarTitle: event.calendarTitle,
                participants: event.participants,
                meetingURL: event.url
            )
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
        let calendarIntervals = merge(dayCalendarEvents.compactMap {
            clipped(DateInterval(start: $0.startDate, end: $0.endDate), to: dayInterval)
        })
        return (recorded, upcoming, calendarIntervals)
    }
}
