import Foundation
import XCTest
@testable import LibreReverseCore

final class JumpToDateContractTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: -4 * 3_600)!
        return value
    }

    func testTimelineUpdatesDoNotOverwriteDraftWhilePickerIsOpen() {
        let range = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 10_000)
        var state = JumpToDateState(
            currentSeekPosition: range.start.addingTimeInterval(100),
            pickerDateRange: range,
            calendar: calendar
        )
        state.togglePicker()
        state.completePickerAnimation()
        let draft = state.pickerDate
        state.updateCurrentSeekPosition(range.start.addingTimeInterval(9_000))
        XCTAssertEqual(state.pickerDate, draft)
        XCTAssertEqual(state.pickerOpenState, .open)
    }

    func testClosedPickerTracksAndClampsCurrentSeek() {
        let range = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 100)
        var state = JumpToDateState(
            currentSeekPosition: range.start,
            pickerDateRange: range,
            calendar: calendar
        )
        state.updateCurrentSeekPosition(range.end.addingTimeInterval(20))
        XCTAssertEqual(state.currentSeekPosition, range.end)
        XCTAssertEqual(state.pickerDate, range.end)
    }

    func testOnlyValidDaysAndHoursCanBeSelected() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1
        )))
        let range = DateInterval(start: start, duration: 31 * 86_400)
        let validDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 4, to: start))
        let invalidDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 5, to: start))
        var state = JumpToDateState(
            currentSeekPosition: start,
            pickerDateRange: range,
            calendar: calendar
        )
        state.updateValidDays([validDay])
        XCTAssertFalse(state.selectDay(invalidDay))
        XCTAssertTrue(state.selectDay(validDay))

        let validHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 14, to: validDay))
            .addingTimeInterval(55 * 60 + 23)
        let invalidHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 13, to: validDay))
        state.updateValidHours([validHour])
        XCTAssertTrue(state.isTimePickerEnabled)
        XCTAssertFalse(state.selectHour(invalidHour))
        XCTAssertTrue(state.selectHour(validHour))
        XCTAssertEqual(calendar.component(.hour, from: state.selectedDate), 14)
        XCTAssertEqual(calendar.component(.minute, from: state.selectedDate), 55)
        XCTAssertEqual(calendar.component(.second, from: state.selectedDate), 23)
        let precise = try XCTUnwrap(calendar.dateInterval(of: .hour, for: validHour)?.start)
            .addingTimeInterval(37 * 60 + 12)
        XCTAssertTrue(state.selectTime(precise))
        XCTAssertEqual(calendar.component(.minute, from: state.selectedDate), 37)
        XCTAssertEqual(calendar.component(.second, from: state.selectedDate), 12)
    }

    func testDayAndHourSelectionsResolveToFirstRealRecordingInBucket() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1
        )))
        let dayFirst = try XCTUnwrap(calendar.date(byAdding: .day, value: 25, to: start))
            .addingTimeInterval(12 * 3_600 + 14 * 60 + 29)
        let sameDayLater = dayFirst.addingTimeInterval(5 * 60)
        let hourFirst = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: dayFirst))
            .addingTimeInterval(40 * 60 + 54)
        var state = JumpToDateState(
            currentSeekPosition: start,
            pickerDateRange: DateInterval(start: start, duration: 31 * 86_400),
            calendar: calendar
        )

        state.updateValidDays([sameDayLater, dayFirst])
        XCTAssertTrue(state.selectDay(dayFirst))
        XCTAssertEqual(state.selectedDate, dayFirst)

        state.updateValidHours([hourFirst.addingTimeInterval(10), hourFirst])
        XCTAssertTrue(state.selectHour(hourFirst))
        XCTAssertEqual(state.selectedDate, hourFirst)
    }

    func testValidHourRefreshDoesNotMoveCurrentPickerDate() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 5, minute: 38
        )))
        var state = JumpToDateState(
            currentSeekPosition: start,
            pickerDateRange: DateInterval(
                start: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: start)),
                duration: 3 * 86_400
            ),
            calendar: calendar
        )
        let otherHour = try XCTUnwrap(calendar.date(bySettingHour: 2, minute: 7, second: 0, of: start))

        state.updateValidHours([otherHour])

        XCTAssertEqual(state.selectedDate, start)
        XCTAssertTrue(state.isTimePickerEnabled)
    }

    func testChangingMonthClearsStaleAvailability() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1
        )))
        var state = JumpToDateState(
            currentSeekPosition: start,
            pickerDateRange: DateInterval(start: start, duration: 90 * 86_400),
            calendar: calendar
        )
        state.updateValidDays([start])
        state.updateValidHours([start])
        state.viewMonth(try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: start)))
        XCTAssertTrue(state.validDays.isEmpty)
        XCTAssertTrue(state.validHours.isEmpty)
        XCTAssertFalse(state.isTimePickerEnabled)
    }
}
