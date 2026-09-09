import Foundation

public enum JumpToDatePickerOpenState: Equatable, Sendable {
    case opening
    case open
    case closing
    case closed
}

/// Keeps cursor, draft date, viewed month, recording availability, and popover
/// animation state separate. Timeline updates must not overwrite a date the
/// user is editing while the picker is open.
public struct JumpToDateState: Equatable {
    public private(set) var currentSeekPosition: Date
    public private(set) var pickerDate: Date
    public private(set) var pickerDateRange: DateInterval
    public private(set) var pickerOpenState: JumpToDatePickerOpenState
    public private(set) var viewingMonth: Date
    public private(set) var validDays: Set<Date>
    public private(set) var validHours: Set<Date>
    public private(set) var isTimePickerEnabled: Bool
    public let calendar: Calendar

    // Availability buckets retain their first recording timestamp alongside
    // normalized day and hour keys so
    // selecting a day/hour never fabricates an uncaptured wall-clock instant.
    private var firstRecordingByDay: [Date: Date]
    private var firstRecordingByHour: [Date: Date]

    public init(
        currentSeekPosition: Date,
        pickerDateRange: DateInterval,
        calendar: Calendar = .current
    ) {
        self.calendar = calendar
        self.pickerDateRange = pickerDateRange
        let clamped = Self.clamp(currentSeekPosition, to: pickerDateRange)
        self.currentSeekPosition = clamped
        self.pickerDate = clamped
        self.viewingMonth = Self.monthStart(containing: clamped, calendar: calendar)
        self.pickerOpenState = .closed
        self.validDays = []
        self.validHours = []
        self.isTimePickerEnabled = false
        self.firstRecordingByDay = [:]
        self.firstRecordingByHour = [:]
    }

    public mutating func togglePicker() {
        switch pickerOpenState {
        case .closed, .closing: pickerOpenState = .opening
        case .open, .opening: pickerOpenState = .closing
        }
    }

    public mutating func completePickerAnimation() {
        switch pickerOpenState {
        case .opening: pickerOpenState = .open
        case .closing: pickerOpenState = .closed
        case .open, .closed: break
        }
    }

    public mutating func closePicker() {
        guard pickerOpenState != .closed else { return }
        pickerOpenState = .closing
    }

    public mutating func updateCurrentSeekPosition(_ date: Date) {
        currentSeekPosition = Self.clamp(date, to: pickerDateRange)
        guard pickerOpenState == .closed else { return }
        pickerDate = currentSeekPosition
        viewingMonth = Self.monthStart(containing: pickerDate, calendar: calendar)
    }

    public mutating func updateRange(_ range: DateInterval) {
        pickerDateRange = range
        currentSeekPosition = Self.clamp(currentSeekPosition, to: range)
        pickerDate = Self.clamp(pickerDate, to: range)
        viewingMonth = Self.monthStart(containing: pickerDate, calendar: calendar)
    }

    public mutating func viewMonth(_ date: Date) {
        viewingMonth = Self.monthStart(containing: date, calendar: calendar)
        validDays = []
        validHours = []
        isTimePickerEnabled = false
        firstRecordingByDay = [:]
        firstRecordingByHour = [:]
    }

    public mutating func updateValidDays(_ dates: some Sequence<Date>) {
        firstRecordingByDay = dates.reduce(into: [:]) { result, sample in
            let day = calendar.startOfDay(for: sample)
            result[day] = min(result[day] ?? sample, sample)
        }
        validDays = Set(firstRecordingByDay.keys)
    }

    @discardableResult
    public mutating func selectDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        guard validDays.contains(day) else { return false }
        pickerDate = Self.clamp(firstRecordingByDay[day] ?? day, to: pickerDateRange)
        validHours = []
        isTimePickerEnabled = false
        firstRecordingByHour = [:]
        return true
    }

    public mutating func updateValidHours(_ dates: some Sequence<Date>) {
        firstRecordingByHour = dates.reduce(into: [:]) { result, sample in
            guard let hour = calendar.dateInterval(of: .hour, for: sample)?.start else { return }
            result[hour] = min(result[hour] ?? sample, sample)
        }
        validHours = Set(firstRecordingByHour.keys)
        isTimePickerEnabled = !validHours.isEmpty
    }

    @discardableResult
    public mutating func selectHour(_ date: Date) -> Bool {
        guard validHours.contains(where: {
            calendar.isDate($0, equalTo: date, toGranularity: .hour)
        }) else { return false }
        guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return false }
        pickerDate = Self.clamp(firstRecordingByHour[hour] ?? hour, to: pickerDateRange)
        return true
    }

    @discardableResult
    public mutating func selectTime(_ date: Date) -> Bool {
        guard validHours.contains(where: {
            calendar.isDate($0, equalTo: date, toGranularity: .hour)
        }) else { return false }
        var components = calendar.dateComponents([.year, .month, .day], from: pickerDate)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        pickerDate = Self.clamp(calendar.date(from: components) ?? pickerDate, to: pickerDateRange)
        return true
    }

    public var selectedDate: Date { pickerDate }

    public func monthInterval() -> DateInterval? {
        calendar.dateInterval(of: .month, for: viewingMonth)
    }

    public func selectedDayInterval() -> DateInterval? {
        calendar.dateInterval(of: .day, for: pickerDate)
    }

    private static func clamp(_ date: Date, to range: DateInterval) -> Date {
        min(max(date, range.start), range.end)
    }

    private static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }
}
