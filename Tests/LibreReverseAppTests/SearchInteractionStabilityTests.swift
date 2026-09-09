import AppKit
import XCTest
@testable import LibreReverseApp
@testable import LibreReverseCore

@MainActor
final class SearchInteractionStabilityTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func edit(_ overlay: LibreReverseSearchOverlayView, _ query: String) {
        let field = descendants(overlay).compactMap { $0 as? NSSearchField }.first!
        field.stringValue = query
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testLiveTypingDebouncesBothScreenAndMeetingQueriesOnce() async throws {
        for filters: Set<LibreReverseSearchOverlayFilter> in [[], [.meetings]] {
            let overlay = LibreReverseSearchOverlayView(state: .init(filters: filters))
            var submissions: [String] = []
            overlay.onSubmit = { submissions.append($0.query) }
            edit(overlay, "m")
            edit(overlay, "me")
            edit(overlay, "meeting notes")
            XCTAssertEqual(submissions, [])
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(submissions, ["meeting notes"])
        }
    }

    func testClearDismissAndReturnCancelDelayedSubmission() async throws {
        let overlay = LibreReverseSearchOverlayView()
        var submissions: [String] = []
        var confirmations: [String] = []
        overlay.onSubmit = { submissions.append($0.query) }
        overlay.onConfirm = { confirmations.append($0.query) }
        edit(overlay, "clear me")
        edit(overlay, "")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(submissions, [])
        edit(overlay, "dismiss me")
        overlay.cancelPendingSubmission()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(submissions, [])
        edit(overlay, "confirm once")
        let field = descendants(overlay).compactMap { $0 as? NSSearchField }.first!
        XCTAssertTrue(field.sendsWholeSearchString)
        XCTAssertFalse(field.sendsSearchStringImmediately)
        field.sendAction(field.action!, to: field.target)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(confirmations, ["confirm once"])
        XCTAssertEqual(submissions, [])
    }

    func testPendingReplacementKeepsRowsStationaryAndOneLabelClickSelectsDisplayedResult() {
        _ = NSApplication.shared
        let view = LibreReverseSearchResultsView()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 278),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let date = Date(timeIntervalSince1970: 12345)
        let candidate = HistoricalSearchCandidate(docID: 1, frameID: 2, segmentID: 3,
            frameDate: date, bundleID: nil, windowName: "Displayed result",
            text: "exact displayed evidence", otherText: "")
        let result = OCRSearchResult(result: .init(candidate: candidate, representativeInstant: date,
            resolvedTitle: "Displayed result", segmentType: .capturedScreen, matchRectangle: nil),
            firstNode: .init(nodeOrder: 0, textOffset: 0, textLength: 10,
                leftX: 0.1, topY: 0.2, width: 0.3, height: 0.04, windowIndex: 0))
        var selected: [OCRSearchResult] = []
        var state = ExplorerSearchState()
        state.send(.input(.init(query: "displayed")))
        state.send(.submit)
        view.onSelect = { selected.append($0); state.send(.hide) }
        view.show(results: [result])
        view.layoutSubtreeIfNeeded()
        let collection = descendants(view).compactMap { $0 as? NSCollectionView }.first!
        let row = collection.item(at: IndexPath(item: 0, section: 0))!.view
        let originalFrame = row.convert(row.bounds, to: view)
        state.send(.input(.init(query: "replacement")))
        state.send(.submit)
        let pendingRevision = state.revision
        view.showLoading(preservingResults: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(collection.item(at: IndexPath(item: 0, section: 0))!.view === row)
        XCTAssertEqual(row.convert(row.bounds, to: view), originalFrame)
        let label = descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Displayed result" }!
        let point = label.convert(NSPoint(x: 5, y: label.bounds.midY), to: view)
        let hit = view.hitTest(point)!
        XCTAssertTrue(hit === row, "Label clicks must reach the row action on their first event")
        let location = view.convert(point, to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        hit.mouseDown(with: event)
        XCTAssertEqual(selected, [result])
        XCTAssertEqual(selected.first?.result.representativeInstant, date)
        XCTAssertFalse(state.accepts(pendingRevision), "A pending replacement cannot reopen search after selection")
        XCTAssertFalse(state.expanded)
        let background = row.convert(NSPoint(x: 3, y: 3), to: view)
        XCTAssertTrue(view.hitTest(background) === row)
        let button = descendants(row).compactMap { $0 as? NSButton }.first!
        button.isEnabled = true
        let icon = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
        XCTAssertTrue(view.hitTest(icon) is NSButton, "Preview buttons retain their separate native action")
    }
}
