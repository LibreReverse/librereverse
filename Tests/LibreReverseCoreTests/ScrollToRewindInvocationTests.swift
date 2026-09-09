import XCTest
@testable import LibreReverseCore

final class ScrollToRewindInvocationTests: XCTestCase {
    func testAbsentPersistedValueDefaultsToEnabled() {
        XCTAssertTrue(ScrollToRewindInvocation.defaultEnabled)
    }

    func testInstalledModifierPredicateIsCommandShiftWithoutOption() {
        XCTAssertTrue(ScrollToRewindInvocation.modifiersMatch(.init(command: true, shift: true)))
        XCTAssertFalse(ScrollToRewindInvocation.modifiersMatch(.init(command: true)))
        XCTAssertFalse(ScrollToRewindInvocation.modifiersMatch(.init(shift: true)))
        XCTAssertFalse(ScrollToRewindInvocation.modifiersMatch(.init(command: true, option: true, shift: true)))
    }

    func testBeganAndNonMomentumUnphasedEventsRefreshModifierState() {
        let began = decision(previous: false, phase: 1, momentum: 0, modifiers: .init(command: true, shift: true))
        XCTAssertTrue(began.isPressingModifierKeys)

        let unphased = decision(previous: true, phase: 0, momentum: 0, modifiers: .init())
        XCTAssertFalse(unphased.isPressingModifierKeys)
    }

    func testChangedAndMomentumEventsRetainPriorModifierState() {
        let changed = decision(previous: true, phase: 4, momentum: 0, modifiers: .init())
        XCTAssertTrue(changed.isPressingModifierKeys)

        let momentum = decision(previous: true, phase: 0, momentum: 4, modifiers: .init())
        XCTAssertTrue(momentum.isPressingModifierKeys)
    }

    func testOpeningThresholdIsInclusiveAndDirectionAgnostic() {
        XCTAssertFalse(decision(deltaY: 0.999999, previous: true).shouldOpen)
        XCTAssertTrue(decision(deltaY: 1, previous: true).shouldOpen)
        XCTAssertTrue(decision(deltaY: -1, previous: true).shouldOpen)
        XCTAssertTrue(decision(deltaX: -2, deltaY: 1, previous: true).shouldOpen)
        XCTAssertTrue(decision(deltaY: .nan, previous: true).shouldOpen)
    }

    func testModifierStateCanUpdateWithoutOpening() {
        let result = decision(
            deltaY: 0.5,
            previous: false,
            phase: 1,
            modifiers: .init(command: true, shift: true)
        )
        XCTAssertTrue(result.isPressingModifierKeys)
        XCTAssertFalse(result.shouldOpen)
    }

    private func decision(
        deltaX: Double = 0,
        deltaY: Double = 2,
        previous: Bool,
        phase: UInt = 4,
        momentum: UInt = 0,
        modifiers: ScrollToRewindModifiers = .init()
    ) -> ScrollToRewindDecision {
        ScrollToRewindInvocation.decision(
            previousIsPressingModifierKeys: previous,
            event: .init(
                scrollingDeltaX: deltaX,
                scrollingDeltaY: deltaY,
                phaseRawValue: phase,
                momentumPhaseRawValue: momentum,
                modifiers: modifiers
            )
        )
    }
}
