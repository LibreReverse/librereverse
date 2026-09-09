#if os(macOS)
import EventKit
import Foundation
import LibreReverseCore

struct LibreReverseMeetingCalendarSettingsSnapshot {
    let enabled: Bool
    let authorization: EKAuthorizationStatus
    let calendars: [(id: String, title: String)]
    let selection: LibreReverseMeetingCalendarSelection
    let readAccessOverride: Bool?

    var hasReadAccess: Bool {
        if let readAccessOverride { return readAccessOverride }
        return authorization == .fullAccess
    }
}

@MainActor
final class LibreReverseCalendarMeetingSource {
    private let eventStore = EKEventStore()
    private var cachedEvents: [LibreReverseMeetingCalendarEvent] = []
    private var cachedAt: Date?
    private var cachedCalendarFilter: Set<String>?
    private var storeChangedObserver: NSObjectProtocol?

    init() {
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedAt = nil
                self?.cachedCalendarFilter = nil
            }
        }
    }

    deinit {
        if let storeChangedObserver {
            NotificationCenter.default.removeObserver(storeChangedObserver)
        }
    }

    func snapshot(
        enabled: Bool,
        selection: LibreReverseMeetingCalendarSelection
    ) -> LibreReverseMeetingCalendarSettingsSnapshot {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        let calendars: [(String, String)]
        if hasReadAccess(authorization) {
            calendars = eventStore.calendars(for: .event)
                .map { ($0.calendarIdentifier, $0.title) }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        } else {
            calendars = []
        }
        return .init(
            enabled: enabled,
            authorization: authorization,
            calendars: calendars,
            selection: selection,
            readAccessOverride: nil
        )
    }

    func requestReadAccess(completion: @escaping (Bool) -> Void) {
        eventStore.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func events(
        at now: Date,
        selectedCalendarIDs: Set<String>? = nil
    ) -> [LibreReverseMeetingCalendarEvent] {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasReadAccess(authorization) else { return [] }
        if let cachedAt, now.timeIntervalSince(cachedAt) < 60,
           cachedCalendarFilter == selectedCalendarIDs { return cachedEvents }
        let calendars = eventStore.calendars(for: .event).filter { calendar in
            selectedCalendarIDs?.contains(calendar.calendarIdentifier) ?? true
        }
        guard !calendars.isEmpty else {
            cachedEvents = []
            cachedAt = now
            cachedCalendarFilter = selectedCalendarIDs
            return []
        }
        let interval = LibreReverseMeetingCalendarCorrelation.queryInterval(at: now)
        let predicate = eventStore.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )
        cachedEvents = eventStore.events(matching: predicate).map(Self.convert)
        cachedAt = now
        cachedCalendarFilter = selectedCalendarIDs
        return cachedEvents
    }

    /// Reads one explicit recap interval without requesting authorization.
    /// Permission prompting remains owned by Settings; opening Daily Recap can
    /// therefore never surprise the user with a system consent sheet.
    func events(
        in interval: DateInterval,
        selectedCalendarIDs: Set<String>? = nil
    ) -> [LibreReverseMeetingCalendarEvent] {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasReadAccess(authorization), interval.duration > 0 else { return [] }
        let calendars = eventStore.calendars(for: .event).filter { calendar in
            selectedCalendarIDs?.contains(calendar.calendarIdentifier) ?? true
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )
        return eventStore.events(matching: predicate).map(Self.convert)
    }

    func invalidate() {
        cachedAt = nil
        cachedCalendarFilter = nil
    }

    private func hasReadAccess(_ authorization: EKAuthorizationStatus) -> Bool {
        return authorization == .fullAccess
    }

    private static func convert(_ event: EKEvent) -> LibreReverseMeetingCalendarEvent {
        LibreReverseMeetingCalendarEvent(
            eventIdentifier: event.eventIdentifier,
            seriesIdentifier: event.calendarItemExternalIdentifier,
            calendarIdentifier: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            title: event.title ?? "Meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            status: status(event.status),
            participants: (event.attendees ?? []).compactMap { attendee in
                let name = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.flatMap { $0.isEmpty ? nil : $0 }
            },
            url: event.url ?? firstMeetingURL(in: [event.location, event.notes])
        )
    }

    private static func status(_ value: EKEventStatus) -> LibreReverseCalendarEventStatus {
        switch value {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        default: .none
        }
    }

    private static func firstMeetingURL(in values: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        for value in values.compactMap({ $0 }) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in detector.matches(in: value, range: range) {
                if let url = match.url,
                   LibreReverseMeetingDetector.browserProvider(for: url) != nil {
                    return url
                }
            }
        }
        return nil
    }
}
#endif
