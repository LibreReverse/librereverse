import XCTest
import AppKit
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class ShortcutPlaybackScaleTests: XCTestCase {
    func testSearchFieldEscapeUsesSearchDismissalCallback() {
        let overlay = LibreReverseSearchOverlayView()
        var actions: [String] = []
        overlay.onDismiss = { actions.append("hide") }
        overlay.onEscape = { actions.append("hide") }
        XCTAssertTrue(overlay.control(NSSearchField(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(actions, ["hide"])
    }

    func testTypingSpacesBracketsAndCaretNavigationNeverControlsTimelinePlayback() {
        let result = probeTimelineSearchEditingKeys()
        XCTAssertEqual(result.timelineActions, [])
        XCTAssertEqual(result.editingKeys, [49, 123, 124, 30, 124])
    }

    func testStandardEditingCommandsSelectReplaceUndoAndRedoInsideFieldEditor() {
        let result = probeTimelineEditingCommands()
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 6))
        XCTAssertEqual(result.replacement, "Project schedule")
        XCTAssertEqual(result.undone, "Launch")
        XCTAssertEqual(result.redone, "Project schedule")
        XCTAssertEqual(result.clipboardActions, ["copy", "cut", "paste"])
    }

    func testEscapeBracketAndCommandRightRoutes() {
        XCTAssertEqual(probeTimelineNavigationKeys(), ["exit", "now", "now"])
    }

    func testBackwardScrollLeavesNowWhenLiveFrameIsNewerThanLoadedHistory() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(100)
        let window = HistoricalTimelineSegmentWindow(segments: [
            .init(startDate: start, endDate: end, bundleID: "app", rawID: 1, rawType: .capturedScreen)
        ], validSeekInterval: DateInterval(start: start, end: end), playbackFrameDates: [start, end])
        XCTAssertTrue(probeScrollFromFreshLiveFrame(window: window))
    }

    func testShortcutLiveSeekThenHistoryPlayNeverResetsScale() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(100)
        let window = HistoricalTimelineSegmentWindow(segments: [
            .init(startDate: start, endDate: end, bundleID: "app", rawID: 1, rawType: .capturedScreen)
        ], validSeekInterval: DateInterval(start: start, end: end),
            playbackFrameDates: [start, end])
        XCTAssertEqual(probeShortcutPlaybackScale(window: window), [true, true, true, true, true])
    }
}
