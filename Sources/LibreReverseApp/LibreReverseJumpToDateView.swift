#if os(macOS)
import AppKit
import LibreReverseCore

/// Calendar/hour surface used by the explorer. Choosing an enabled day or
/// hour emits a timeline jump immediately while the transient picker stays open.
@MainActor
final class LibreReverseJumpToDateView: NSView {
    static let preferredContentSize = NSSize(width: 448, height: 378)
    var onPreviousMonth: (() -> Void)?
    var onNextMonth: (() -> Void)?
    var onSelectDay: ((Date) -> Void)?
    var onSelectHour: ((Date) -> Void)?

    private let monthLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let dayGrid = NSGridView()
    private let hourDocument = NSView()
    private let hourScrollView = NSScrollView()
    private var dayButtons: [NSButton] = []
    private var hourButtons: [NSButton] = []
    private var representedDays: [Date?] = Array(repeating: nil, count: 42)
    private var representedHours: [Date?] = []
    private var hourDocumentHeightConstraint: NSLayoutConstraint?
    private var loadingDays = true
    private var loadingHours = true
    private var state: JumpToDateState?
    private var revealedHour: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func render(
        _ state: JumpToDateState,
        loadingDays: Bool,
        loadingHours: Bool
    ) {
        self.state = state
        self.loadingDays = loadingDays
        self.loadingHours = loadingHours
        Self.monthFormatter.calendar = state.calendar
        Self.monthFormatter.timeZone = state.calendar.timeZone
        Self.dayFormatter.calendar = state.calendar
        Self.dayFormatter.timeZone = state.calendar.timeZone
        monthLabel.stringValue = Self.monthFormatter.string(from: state.viewingMonth)
        renderMonthButtons(state)
        renderDays(state)
        renderHours(state)
        if !loadingHours,
            let hour = state.calendar.dateInterval(of: .hour, for: state.selectedDate)?.start,
            hour != revealedHour,
            let index = representedHours.firstIndex(where: { $0 == hour }) {
            layoutSubtreeIfNeeded()
            hourButtons[index].scrollToVisible(hourButtons[index].bounds.insetBy(dx: 0, dy: -70))
            revealedHour = hour
        }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Date & time")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .left

        previousButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Back"
        )
        nextButton.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Forward"
        )
        for button in [previousButton, nextButton] {
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        previousButton.target = self
        previousButton.action = #selector(previousMonth)
        nextButton.target = self
        nextButton.action = #selector(nextMonth)
        monthLabel.font = .systemFont(ofSize: 15, weight: .medium)
        monthLabel.alignment = .center
        monthLabel.setAccessibilityRole(.staticText)

        let monthHeader = NSStackView(views: [previousButton, monthLabel, nextButton])
        monthHeader.orientation = .horizontal
        monthHeader.alignment = .centerY
        monthHeader.distribution = .fill
        monthLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var rows: [[NSView]] = []
        rows.append(Self.weekdaySymbols.map { symbol in
            let label = NSTextField(labelWithString: symbol)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return label
        })
        for _ in 0..<6 {
            var row: [NSView] = []
            for _ in 0..<7 {
                let button = NSButton(title: "", target: self, action: #selector(selectDay(_:)))
                button.isBordered = false
                button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                button.widthAnchor.constraint(equalToConstant: 38).isActive = true
                button.heightAnchor.constraint(equalToConstant: 34).isActive = true
                button.setAccessibilityIdentifier("timeline.jumpToDate.day")
                button.tag = dayButtons.count
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                dayButtons.append(button)
                row.append(button)
            }
            rows.append(row)
        }
        for row in rows { dayGrid.addRow(with: row) }
        dayGrid.rowAlignment = .none
        dayGrid.yPlacement = .center
        dayGrid.row(at: 0).height = 24
        for row in 1...6 { dayGrid.row(at: row).height = 34 }
        dayGrid.heightAnchor.constraint(equalToConstant: 246).isActive = true
        dayGrid.rowSpacing = 3
        dayGrid.columnSpacing = 6
        for column in 0..<7 { dayGrid.column(at: column).xPlacement = .fill }

        let calendarStack = NSStackView(views: [monthHeader, dayGrid])
        calendarStack.orientation = .vertical
        calendarStack.alignment = .centerX
        calendarStack.spacing = 12

        hourDocument.translatesAutoresizingMaskIntoConstraints = false
        hourScrollView.documentView = hourDocument
        hourScrollView.hasVerticalScroller = true
        hourScrollView.hasHorizontalScroller = false
        hourScrollView.drawsBackground = false
        hourScrollView.scrollerStyle = .overlay
        hourScrollView.verticalScrollElasticity = .none
        hourDocumentHeightConstraint = hourDocument.heightAnchor.constraint(equalToConstant: 8)
        hourDocumentHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            hourDocument.widthAnchor.constraint(equalTo: hourScrollView.contentView.widthAnchor),
            hourScrollView.widthAnchor.constraint(equalToConstant: 92),
            hourScrollView.heightAnchor.constraint(equalToConstant: 312),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 312).isActive = true

        let body = NSStackView(views: [calendarStack, separator, hourScrollView])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 10

        // Keep the heading inside the same explicit content gutter as the
        // calendar. Stack fitting sizes can otherwise exceed popover content.
        title.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(body)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            monthHeader.widthAnchor.constraint(equalTo: dayGrid.widthAnchor),
        ])
    }

    private func renderMonthButtons(_ state: JumpToDateState) {
        guard let previous = state.calendar.date(
            byAdding: .month, value: -1, to: state.viewingMonth
        ), let next = state.calendar.date(
            byAdding: .month, value: 1, to: state.viewingMonth
        ) else {
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            return
        }
        let previousEnd = state.calendar.date(byAdding: .month, value: 1, to: previous)
        previousButton.isEnabled = previousEnd.map { $0 > state.pickerDateRange.start } ?? false
        nextButton.isEnabled = next < state.pickerDateRange.end
        // Keep the month centered when one edge of the library is reached.
        previousButton.isHidden = false
        nextButton.isHidden = false
    }

    private func renderDays(_ state: JumpToDateState) {
        guard let month = state.monthInterval() else { return }
        let weekday = state.calendar.component(.weekday, from: month.start)
        let firstColumn = (weekday - state.calendar.firstWeekday + 7) % 7
        guard let gridStart = state.calendar.date(
            byAdding: .day, value: -firstColumn, to: month.start
        ) else { return }

        for (index, button) in dayButtons.enumerated() {
            guard let date = state.calendar.date(byAdding: .day, value: index, to: gridStart) else {
                button.isHidden = true
                representedDays[index] = nil
                continue
            }
            button.isHidden = false
            button.title = String(state.calendar.component(.day, from: date))
            representedDays[index] = date
            let inMonth = state.calendar.isDate(date, equalTo: month.start, toGranularity: .month)
            let day = state.calendar.startOfDay(for: date)
            let valid = inMonth && state.validDays.contains(day)
            let selected = inMonth && state.calendar.isDate(date, inSameDayAs: state.selectedDate)
            button.isEnabled = valid
            button.layer?.backgroundColor = selected
                ? NSColor.systemBlue.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            button.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
            let fullDate = Self.dayFormatter.string(from: date)
            button.setAccessibilityLabel(fullDate)
            button.toolTip = valid ? fullDate : loadingDays
                ? "Checking recordings for \(fullDate)" : "No recording on \(fullDate)"
            button.contentTintColor = selected
                ? .white
                : valid ? .labelColor : .tertiaryLabelColor
        }
    }

    private func setHourRowCount(_ count: Int) {
        guard hourButtons.count != count else { return }
        hourButtons.forEach { $0.removeFromSuperview() }
        hourButtons.removeAll()
        for hour in 0..<count {
            let button = NSButton(
                title: String(format: "%02d:00", hour),
                target: self,
                action: #selector(selectHour(_:))
            )
            button.tag = hour
            button.isBordered = false
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.alignment = .center
            button.setAccessibilityIdentifier("timeline.jumpToDate.hour")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.cornerCurve = .continuous
            hourDocument.addSubview(button)
            hourButtons.append(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: hourDocument.leadingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: hourDocument.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: hourDocument.topAnchor, constant: CGFloat(hour * 35) + 4),
                button.heightAnchor.constraint(equalToConstant: 27),
            ])
        }
        hourDocumentHeightConstraint?.constant = CGFloat(count * 35 + 8)
    }

    private func renderHours(_ state: JumpToDateState) {
        guard let day = state.selectedDayInterval() else { return }
        var dates: [Date] = []
        var date = day.start
        while date < day.end {
            dates.append(date)
            guard let next = state.calendar.date(byAdding: .hour, value: 1, to: date), next > date else { break }
            date = next
        }
        setHourRowCount(dates.count)
        representedHours = dates.map(Optional.some)
        let formatter = DateFormatter()
        formatter.calendar = state.calendar
        formatter.timeZone = state.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let labels = dates.map(formatter.string(from:))
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        for (hour, button) in hourButtons.enumerated() {
            let date = representedHours[hour]
            // The repeated hour has two distinct instants. Include its UTC
            // offset so both choices remain unambiguous in every time zone.
            if counts[labels[hour], default: 0] > 1 {
                formatter.dateFormat = "HH:mm Z"
                button.title = formatter.string(from: dates[hour])
                button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            } else {
                button.title = labels[hour]
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            }
            let valid = date.map { candidate in
                state.validHours.contains(where: {
                    state.calendar.isDate($0, equalTo: candidate, toGranularity: .hour)
                })
            } ?? false
            let selected = date.map {
                state.calendar.isDate($0, equalTo: state.selectedDate, toGranularity: .hour)
            } ?? false
            button.isEnabled = valid
            button.contentTintColor = valid ? .labelColor : .tertiaryLabelColor
            button.layer?.backgroundColor = valid
                ? (selected
                    ? NSColor.systemBlue.withAlphaComponent(0.18).cgColor
                    : NSColor.clear.cgColor)
                : NSColor.clear.cgColor
            button.layer?.borderWidth = valid && selected ? 1 : 0
            button.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
            let availability = valid ? "recording available" : loadingHours ? "loading recordings" : "no recording"
            button.setAccessibilityLabel("\(button.title), \(availability)")
        }
    }

    @objc private func previousMonth() { onPreviousMonth?() }
    @objc private func nextMonth() { onNextMonth?() }

    @objc private func selectDay(_ sender: NSButton) {
        guard representedDays.indices.contains(sender.tag),
              let date = representedDays[sender.tag] else { return }
        onSelectDay?(date)
    }

    @objc private func selectHour(_ sender: NSButton) {
        guard representedHours.indices.contains(sender.tag),
              let date = representedHours[sender.tag] else { return }
        onSelectHour?(date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    private static let weekdaySymbols: [String] = {
        let formatter = DateFormatter()
        let symbols = formatter.shortStandaloneWeekdaySymbols
            ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let first = Calendar.current.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }()
}
#endif
