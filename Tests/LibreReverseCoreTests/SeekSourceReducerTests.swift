import XCTest
@testable import LibreReverseCore

final class SeekSourceReducerTests: XCTestCase {
    func testPlayAfterSearchTakesOwnershipWithoutRequiringScroll() {
        var reducer = SeekSourceReducer()
        XCTAssertEqual(reducer.admit(.search, positionChanged: true), .admitted)
        XCTAssertEqual(reducer.admit(.audioPlayer, positionChanged: true), .rejected)
        reducer.playbackStarted()
        for _ in 0..<10 {
            XCTAssertEqual(reducer.admit(.audioPlayer, positionChanged: true), .admitted)
        }
        reducer.rawScrollDidMutateOffset()
        XCTAssertEqual(reducer.admit(.audioPlayer, positionChanged: true), .rejected)
        XCTAssertEqual(reducer.admit(.scroll, positionChanged: true), .admitted)
    }

    func testRecoveredOrdinalsAreExplicitAndStable() {
        XCTAssertEqual(
            SeekPositionUpdateSource.allCases.map(\.rawValue),
            Array(0...11)
        )
        XCTAssertEqual(SeekPositionUpdateSource.askRewind.rawValue, 0)
        XCTAssertEqual(SeekPositionUpdateSource.drag.rawValue, 5)
        XCTAssertEqual(SeekPositionUpdateSource.pinToEnd.rawValue, 9)
        XCTAssertEqual(SeekPositionUpdateSource.isInitialLoad.rawValue, 11)
    }

    func testDisabledReducerRejectsEverySourceIncludingPinToEnd() {
        for source in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer(
                canUpdateSeekPosition: false,
                source: .audioPlayer
            )
            XCTAssertEqual(reducer.admit(source, positionChanged: true), .rejected)
            XCTAssertEqual(reducer.source, .audioPlayer)
        }
    }

    func testLowerOrdinalOwnsPriorityAndEqualPriorityIsAccepted() {
        for current in SeekPositionUpdateSource.allCases {
            for incoming in SeekPositionUpdateSource.allCases where incoming != .pinToEnd {
                var reducer = SeekSourceReducer(source: current)
                let result = reducer.admit(incoming, positionChanged: true)
                if current.rawValue >= incoming.rawValue {
                    XCTAssertEqual(result, .admitted, "\(current) should admit \(incoming)")
                    XCTAssertEqual(reducer.source, incoming)
                } else {
                    XCTAssertEqual(result, .rejected, "\(current) should reject \(incoming)")
                    XCTAssertEqual(reducer.source, current)
                }
            }
        }
    }

    func testNilOwnerAdmitsEverySource() {
        for source in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer()
            XCTAssertEqual(reducer.admit(source, positionChanged: true), .admitted)
            XCTAssertEqual(reducer.source, source)
        }
    }

    func testPinToEndOverridesEveryExistingPriority() {
        for current in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer(source: current)
            XCTAssertEqual(reducer.admit(.pinToEnd, positionChanged: true), .admitted)
            XCTAssertEqual(reducer.source, .pinToEnd)
        }
    }

    func testEqualPositionMutatesNothingAndEmitsNothing() {
        var reducer = SeekSourceReducer(source: .audioPlayer)
        XCTAssertEqual(reducer.admit(.pinToEnd, positionChanged: false), .unchanged)
        XCTAssertEqual(reducer.source, .audioPlayer)
    }

    func testFreshDragTakesOwnershipFromEveryPreviousSource() {
        for initial in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer(source: initial)
            reducer.dragStarted()
            XCTAssertEqual(reducer.source, .drag)
            XCTAssertEqual(reducer.admit(.drag, positionChanged: true), .admitted)
            reducer.dragEnded()
            XCTAssertNil(reducer.source)
        }
    }

    func testCompletedSearchDoesNotLockLaterClickDragOrNow() {
        for next in [SeekPositionUpdateSource.click, .drag, .jumpToEnd] {
            var reducer = SeekSourceReducer()
            XCTAssertTrue(reducer.beginInteraction(.search))
            XCTAssertEqual(reducer.admit(.search, positionChanged: true), .admitted)
            reducer.endInteraction(.search)
            XCTAssertNil(reducer.source)
            XCTAssertTrue(reducer.beginInteraction(next))
            XCTAssertEqual(reducer.admit(next, positionChanged: true), .admitted)
        }
    }

    func testDisabledFreshInteractionsCannotReplaceCurrentOwner() {
        for incoming in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer(canUpdateSeekPosition: false, source: .search)
            XCTAssertFalse(reducer.beginInteraction(incoming))
            reducer.dragStarted()
            reducer.playbackStarted()
            XCTAssertEqual(reducer.source, .search)
        }
    }

    func testFinishingOlderInteractionPreservesNewOwnerAndLivePin() {
        var reducer = SeekSourceReducer(source: .search)
        reducer.beginInteraction(.click)
        reducer.endInteraction(.search)
        XCTAssertEqual(reducer.source, .click)
        reducer.admit(.pinToEnd, positionChanged: true)
        reducer.clickEnded()
        XCTAssertEqual(reducer.source, .pinToEnd)
        reducer.dragEnded()
        XCTAssertEqual(reducer.source, .pinToEnd)
    }

    func testBoundsDidChangeUsesExactMembershipMask() {
        let cleared: Set<SeekPositionUpdateSource> = [
            .askRewind, .search, .jumpToDate, .keyboardShortcut, .jumpToEnd,
            .scroll, .summarization, .isInitialLoad,
        ]

        for initial in SeekPositionUpdateSource.allCases {
            var reducer = SeekSourceReducer(source: initial)
            reducer.boundsDidChange()
            XCTAssertEqual(reducer.source, cleared.contains(initial) ? nil : initial)
        }
    }

    func testRawScrollDirectlyOverwritesPinThenBoundsReleasesScroll() {
        var reducer = SeekSourceReducer(source: .pinToEnd)
        reducer.rawScrollDidMutateOffset()
        XCTAssertEqual(reducer.source, .scroll)
        reducer.boundsDidChange()
        XCTAssertNil(reducer.source)
    }

    func testRawScrollOverwriteIsDistinctFromSharedAdmission() {
        var reducer = SeekSourceReducer(
            canUpdateSeekPosition: false,
            source: .askRewind
        )
        XCTAssertEqual(reducer.admit(.scroll, positionChanged: true), .rejected)
        XCTAssertEqual(reducer.source, .askRewind)

        reducer.rawScrollDidMutateOffset()
        XCTAssertEqual(reducer.source, .scroll)
    }
}
