import XCTest
@testable import LibreReverseApp

final class ExplorerSearchStateTests: XCTestCase {
    func testScrollDismissesControlsAndResultsAndRejectsPendingCompletion() {
        var state = ExplorerSearchState()
        state.send(.input(.init(filters: [.meetings])))
        state.send(.submit)
        let request = state.revision
        for _ in 0..<20 { state.send(.scroll) }
        XCTAssertFalse(state.expanded)
        XCTAssertFalse(state.resultsPresented)
        XCTAssertTrue(state.input.filters.isEmpty)
        XCTAssertFalse(state.accepts(request))
    }

    func testSelectScrollReopenCannotRetainStrandedMeetingFilter() {
        var state = ExplorerSearchState()
        state.send(.input(.init(filters: [.meetings])))
        state.send(.submit)
        let oldRequest = state.revision
        state.send(.hide)
        state.send(.scroll)
        XCTAssertFalse(state.expanded)
        XCTAssertFalse(state.resultsPresented)
        state.send(.open)
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.input.filters.isEmpty)
        XCTAssertFalse(state.resultsPresented)
        XCTAssertFalse(state.accepts(oldRequest))
    }

    func testEditingDismissAndReopenRejectOldCompletions() {
        var state = ExplorerSearchState()
        state.send(.input(.init(query: "old")))
        state.send(.submit)
        let old = state.revision
        state.send(.input(.init(query: "new")))
        XCTAssertFalse(state.accepts(old))
        XCTAssertTrue(state.resultsPresented, "Keep completed results visible while the edited query is pending")
        state.send(.submit)
        let new = state.revision
        XCTAssertTrue(state.accepts(new))
        state.send(.hide)
        state.send(.open)
        XCTAssertFalse(state.accepts(new))
        XCTAssertEqual(state.input.query, "")
    }
    func testClearingInputHidesRetainedResultsAndRejectsPendingReplacement() {
        var state = ExplorerSearchState()
        state.send(.input(.init(query: "old")))
        state.send(.submit)
        state.send(.input(.init(query: "replacement")))
        let pending = state.revision
        XCTAssertTrue(state.resultsPresented)
        state.send(.input(.init()))
        XCTAssertFalse(state.resultsPresented)
        XCTAssertFalse(state.accepts(pending))
        state.send(.hide)
        state.send(.open)
        XCTAssertEqual(state.input.query, "")
    }

}
