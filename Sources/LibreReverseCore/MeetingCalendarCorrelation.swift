import Foundation

/// Durable selected-calendar policy. `nil` means follow every available
/// calendar, including calendars added later. Once the user changes an
/// individual calendar the explicit set is frozen; unavailable IDs remain in
/// that set so a temporarily disconnected account restores its prior choice.
public struct LibreReverseMeetingCalendarSelection: Codable, Equatable, Sendable {
    public let explicitCalendarIDs: [String]?

    public init(explicitCalendarIDs: [String]? = nil) {
        self.explicitCalendarIDs = explicitCalendarIDs.map {
            Array(Set($0.filter { !$0.isEmpty })).sorted()
        }
    }

    public var eventFilter: Set<String>? {
        explicitCalendarIDs.map(Set.init)
    }

    public func resolvedIDs(availableCalendarIDs: Set<String>) -> Set<String> {
        guard let explicitCalendarIDs else { return availableCalendarIDs }
        return Set(explicitCalendarIDs).intersection(availableCalendarIDs)
    }

    public func updating(
        calendarID: String,
        enabled: Bool,
        availableCalendarIDs: Set<String>
    ) -> Self {
        var selected = explicitCalendarIDs.map(Set.init) ?? availableCalendarIDs
        if enabled { selected.insert(calendarID) } else { selected.remove(calendarID) }
        return .init(explicitCalendarIDs: Array(selected))
    }
}

public enum LibreReverseCalendarEventStatus: String, Codable, Sendable {
    case none
    case confirmed
    case tentative
    case canceled
}

/// EventKit-independent calendar evidence. The app target owns permission and
/// EventKit conversion; keeping correlation here makes ambiguity and boundary
/// behavior reproducible without a user's calendar database.
public struct LibreReverseMeetingCalendarEvent: Equatable, Sendable {
    public let eventIdentifier: String
    public let seriesIdentifier: String?
    public let calendarIdentifier: String
    public let calendarTitle: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let status: LibreReverseCalendarEventStatus
    public let participants: [String]
    public let url: URL?

    public init(
        eventIdentifier: String,
        seriesIdentifier: String? = nil,
        calendarIdentifier: String,
        calendarTitle: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        status: LibreReverseCalendarEventStatus = .none,
        participants: [String] = [],
        url: URL? = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.seriesIdentifier = seriesIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.status = status
        self.participants = participants
        self.url = url
    }
}

public enum LibreReverseMeetingCalendarCorrelation {
    public static let queryHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// Current events include starts up to one minute ahead:
    /// `startDate <= now + 60` and `endDate >= now`, both inclusive.
    public static let currentEventStartLeeway: TimeInterval = 60
    /// Require an exact room identity when correlating calendar events.
    /// Calendar metadata can enrich a capture candidate but cannot create one.
    public static let exactURLStartLeeway: TimeInterval = 10 * 60
    public static let exactURLEndLeeway: TimeInterval = 10 * 60

    /// Normalize the query horizon to local midnight for EventKit.
    public static func queryInterval(
        at now: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        let future = now.addingTimeInterval(queryHorizon)
        return DateInterval(start: now, end: calendar.startOfDay(for: future))
    }

    public static func eligibleEvents(
        _ events: [LibreReverseMeetingCalendarEvent],
        at now: Date
    ) -> [LibreReverseMeetingCalendarEvent] {
        events.filter { event in
            !event.isAllDay
                && event.status != .canceled
                && event.endDate >= now
                && event.startDate
                    <= now.addingTimeInterval(
                        currentEventStartLeeway
                    )
        }
    }

    /// Calendar evidence enriches a live provider/window candidate. It never
    /// manufactures a recording candidate by itself: ambiguous or stale
    /// calendars therefore cannot trigger unattended screen capture.
    public static func correlate(
        candidates: [LibreReverseMeetingCandidate],
        events: [LibreReverseMeetingCalendarEvent],
        at now: Date
    ) -> [LibreReverseMeetingCandidate] {
        let plausible = events.filter { !$0.isAllDay && $0.status != .canceled }
        guard !plausible.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard candidate.calendarEventID == nil,
                let event = bestEvent(for: candidate, among: plausible, at: now)
            else {
                return candidate
            }
            return LibreReverseMeetingCandidate(
                provider: candidate.provider,
                source: candidate.source,
                windowID: candidate.windowID,
                processIdentifier: candidate.processIdentifier,
                bundleIdentifier: candidate.bundleIdentifier,
                title: event.title.isEmpty ? candidate.title : event.title,
                url: candidate.url ?? event.url,
                calendarEventID: event.eventIdentifier,
                calendarID: event.calendarIdentifier,
                calendarSeriesID: event.seriesIdentifier,
                calendarTitle: event.calendarTitle,
                calendarParticipants: event.participants
            )
        }
    }

    private static func bestEvent(
        for candidate: LibreReverseMeetingCandidate,
        among events: [LibreReverseMeetingCalendarEvent],
        at now: Date
    ) -> LibreReverseMeetingCalendarEvent? {
        let observedIdentity = candidate.url.flatMap(meetingURLIdentity)
        if let observedIdentity {
            let exact = events.filter { event in
                event.url.flatMap(meetingURLIdentity) == observedIdentity
                    && exactURLTimeRank(event, at: now) != nil
            }
            if let selected = rankedByTime(exact, at: now, exact: true).first {
                return selected
            }
            // A known room may use time-only fallback only when exactly one
            // eligible event has no conference identity. A different room or
            // several nearby events is an ambiguity, never a title assignment.
            let fallback = eligibleEvents(events, at: now)
            if fallback.count == 1,
                fallback[0].url.flatMap(meetingURLIdentity) == nil
            {
                return fallback[0]
            }
            return nil
        }

        let eligible = eligibleEvents(events, at: now)
        if eligible.count == 1 { return eligible[0] }
        let ranked = eligible.map { event in (event, score(event, for: candidate)) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.startDate != $1.0.startDate {
                    return $0.0.startDate < $1.0.startDate
                }
                return $0.0.eventIdentifier < $1.0.eventIdentifier
            }
        guard let first = ranked.first, first.1 > 0,
            ranked.count == 1 || first.1 > ranked[1].1
        else { return nil }
        return first.0
    }

    private static func rankedByTime(
        _ events: [LibreReverseMeetingCalendarEvent],
        at now: Date,
        exact: Bool
    ) -> [LibreReverseMeetingCalendarEvent] {
        events.sorted { lhs, rhs in
            let left = exact ? exactURLTimeRank(lhs, at: now) : fallbackTimeRank(lhs, at: now)
            let right = exact ? exactURLTimeRank(rhs, at: now) : fallbackTimeRank(rhs, at: now)
            if left?.0 != right?.0 { return (left?.0 ?? 2) < (right?.0 ?? 2) }
            if left?.1 != right?.1 { return (left?.1 ?? .infinity) < (right?.1 ?? .infinity) }
            return lhs.eventIdentifier < rhs.eventIdentifier
        }
    }

    private static func fallbackTimeRank(
        _ event: LibreReverseMeetingCalendarEvent,
        at now: Date
    ) -> (Int, TimeInterval)? {
        if event.startDate <= now, event.endDate >= now {
            return (0, abs(event.startDate.timeIntervalSince(now)))
        }
        if event.startDate > now,
            event.startDate
                <= now.addingTimeInterval(
                    currentEventStartLeeway
                )
        {
            return (1, event.startDate.timeIntervalSince(now))
        }
        return nil
    }

    private static func exactURLTimeRank(
        _ event: LibreReverseMeetingCalendarEvent,
        at now: Date
    ) -> (Int, TimeInterval)? {
        if event.startDate <= now, event.endDate >= now {
            return (0, abs(event.startDate.timeIntervalSince(now)))
        }
        if event.startDate > now,
            event.startDate <= now.addingTimeInterval(exactURLStartLeeway)
        {
            return (1, event.startDate.timeIntervalSince(now))
        }
        if event.endDate < now,
            event.endDate.addingTimeInterval(exactURLEndLeeway) >= now
        {
            return (1, now.timeIntervalSince(event.endDate))
        }
        return nil
    }

    /// Stable provider+room identity. Authentication and tracking query items
    /// are intentionally ignored, except Webex's room-bearing `mtid`.
    public static func meetingURLIdentity(_ url: URL) -> String? {
        guard let rawHost = url.host else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        if host == "meet.google.com", let room = segments.first {
            return "google-meet:\(room)"
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            let room: String?
            switch segments.first {
            case "j", "my": room = segments.dropFirst().first
            case "wc": room = segments.dropFirst().first { $0 != "join" }
            default: room = nil
            }
            return room.map { "zoom:\($0)" }
        }
        if host == "app.slack.com", segments.first == "huddle",
            segments.count >= 3
        {
            return "slack-huddle:\(segments[1])/\(segments[2])"
        }
        let path = segments.joined(separator: "/")
        guard !path.isEmpty else { return nil }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return "teams:\(host)/\(path)"
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            if segments.last == "j.php",
                let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name.lowercased() == "mtid" })?
                    .value?.lowercased()
            {
                return "webex:\(host)/\(path)?mtid=\(token)"
            }
            return "webex:\(host)/\(path)"
        }
        if let provider = MeetingProviderCatalog.browserProvider(for: url) {
            // Preserve path and fragment case: some providers use case-sensitive room IDs.
            return "\(provider.rawValue):\(host)\(url.path)#\(url.fragment ?? "")"
        }
        return nil
    }

    private static func score(
        _ event: LibreReverseMeetingCalendarEvent,
        for candidate: LibreReverseMeetingCandidate
    ) -> Int {
        var result = 0
        if let url = event.url,
            LibreReverseMeetingDetector.browserProvider(for: url) == candidate.provider
        {
            result += 4
        }
        if let title = candidate.title {
            let lhs = significantWords(in: title)
            let rhs = significantWords(in: event.title)
            let overlap = lhs.intersection(rhs).count
            if overlap >= 2 { result += min(overlap, 3) }
        }
        return result
    }

    private static func significantWords(in value: String) -> Set<String> {
        let ignored: Set<String> = [
            "call", "google", "huddle", "meet", "meeting", "microsoft", "slack", "teams",
            "webex", "zoom",
        ]
        return Set(
            value.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !ignored.contains($0) })
    }
}
