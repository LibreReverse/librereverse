#if os(macOS)
import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class JumpToDateViewTests: XCTestCase {
    func testRecordedDaysAndHoursRemainSelectableAfterStyling() throws {
        _ = NSApplication.shared
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        let selected = day.addingTimeInterval(10 * 3_600)
        var state = JumpToDateState(currentSeekPosition: selected,
            pickerDateRange: DateInterval(start: day.addingTimeInterval(-10 * 86_400), end: day.addingTimeInterval(10 * 86_400)),
            calendar: calendar)
        state.updateValidDays([day, day.addingTimeInterval(-86_400)])
        state.updateValidHours([selected, selected.addingTimeInterval(3_600)])
        let view = LibreReverseJumpToDateView(frame: NSRect(origin: .zero, size: LibreReverseJumpToDateView.preferredContentSize))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1)
        if ProcessInfo.processInfo.environment["LIBREREVERSE_NATIVE_WINDOW_PREVIEWS"] == "1" { window.orderFront(nil) }
        defer { window.orderOut(nil) }
        var chosenDay: Date?
        var chosenHour: Date?
        view.onSelectDay = { chosenDay = $0 }
        view.onSelectHour = { chosenHour = $0 }
        view.render(state, loadingDays: false, loadingHours: false)
        view.layoutSubtreeIfNeeded()
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        let days = buttons.filter { $0.accessibilityIdentifier() == "timeline.jumpToDate.day" }
        let hours = buttons.filter { $0.accessibilityIdentifier() == "timeline.jumpToDate.hour" }
        XCTAssertEqual(days.filter(\.isEnabled).count, 2)
        XCTAssertEqual(hours.filter(\.isEnabled).count, 2)
        let dayButton = try XCTUnwrap(days.first { $0.title == "6" && $0.isEnabled })
        dayButton.performClick(nil)
        XCTAssertEqual(chosenDay, day)
        let hourButton = try XCTUnwrap(hours.first { $0.title == "11:00" })
        hourButton.performClick(nil)
        XCTAssertEqual(chosenHour, selected.addingTimeInterval(3_600))
        XCTAssertTrue(descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("September 2026"))
        XCTAssertFalse(view.hasAmbiguousLayout)
        let heading = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Date & time" })
        let headingRect = view.convert(heading.bounds, from: heading)
        XCTAssertGreaterThanOrEqual(headingRect.minX, 16)
        XCTAssertLessThanOrEqual(headingRect.maxX, view.bounds.maxX - 16)
        XCTAssertGreaterThanOrEqual(view.bounds.maxY - headingRect.maxY, 16)
        XCTAssertGreaterThanOrEqual(headingRect.width, heading.intrinsicContentSize.width)
        for button in days {
            let rect = view.convert(button.bounds, from: button)
            XCTAssertGreaterThanOrEqual(rect.minX, 16)
            XCTAssertLessThanOrEqual(rect.maxX, view.bounds.maxX - 16)
        }
        try snapshot(view)
        view.render(state, loadingDays: true, loadingHours: true)
        XCTAssertTrue(days.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(hours.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(dayButton.toolTip?.contains("Checking") == true)
    }

    func testDSTHourRowsRepresentEveryActualHourAndLabelRepeatedHoursDistinctly() throws {
        _ = NSApplication.shared
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let view = LibreReverseJumpToDateView(frame: NSRect(origin: .zero, size: LibreReverseJumpToDateView.preferredContentSize))
        // Reuse the same picker across 23, 25 and ordinary 24-hour days.
        for (month, dayNumber, count) in [(3, 8, 23), (11, 1, 25), (11, 2, 24)] {
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: dayNumber)))
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: day))
            let dates = (0..<count).map { day.addingTimeInterval(Double($0) * 3600) }
            var state = JumpToDateState(currentSeekPosition: day, pickerDateRange: interval, calendar: calendar)
            state.updateValidDays([day])
            state.updateValidHours(dates)
            view.render(state, loadingDays: false, loadingHours: false)
            let buttons = descendants(view).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityIdentifier() == "timeline.jumpToDate.hour" }
                .sorted { $0.tag < $1.tag }
            XCTAssertEqual(buttons.count, count)
            XCTAssertEqual(Set(buttons.map(\.title)).count, count, "Repeated hours need distinct labels")
            var selected: Date?
            view.onSelectHour = { selected = $0 }
            for (button, expected) in zip(buttons, dates) {
                XCTAssertTrue(button.isEnabled)
                button.performClick(nil)
                XCTAssertEqual(selected, expected)
                XCTAssertTrue(state.selectHour(expected))
                XCTAssertEqual(state.selectedDate, expected)
                let labelHour: String = String(button.title.prefix(2))
                let expectedHour: Int = calendar.component(.hour, from: expected)
                let expectedLabel: String = expectedHour < 10 ? "0\(expectedHour)" : "\(expectedHour)"
                XCTAssertEqual(labelHour, expectedLabel)
                XCTAssertLessThan(expected, interval.end)
            }
            XCTAssertEqual(buttons.last?.title, "23:00", "The last recorded hour must remain reachable")
            if count == 23 { XCTAssertFalse(buttons.contains { $0.title.hasPrefix("02:00") }) }
            if count == 25 {
                XCTAssertEqual(buttons.filter { $0.title.hasPrefix("01:00") }.map(\.title),
                    ["01:00 -0400", "01:00 -0500"])
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func snapshot(_ view: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_ANCILLARY_PREVIEWS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["LIBREREVERSE_NATIVE_WINDOW_PREVIEWS"] == "1", let window = view.window {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent("date-picker.png").path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0, "Native date picker capture failed")
            return
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("date-picker.png"))
    }
}
#endif
