import XCTest
@testable import LibreReverseCore

final class TimelineScrollTests: XCTestCase {
    func testDominantAxisIsNegatedAndTiesChooseY() {
        XCTAssertEqual(result(x: 9, y: -4).delta, -9)
        XCTAssertEqual(result(x: 4, y: -9).delta, 9)
        XCTAssertEqual(result(x: 9, y: -9).delta, 9)
    }

    /// Threshold is the lazy global at `0x1011e06b8`, initialized at
    /// `0x100422abc..0x100422ac8` as `0x4074500000000000` == 325.0.
    /// (A previous note read it as `320.01953125` = `0x4074005000000000`,
    /// the same nibbles transposed.)
    func testManuallyFastThresholdIsStrictAndPrecedesPreciseScaling() {
        XCTAssertEqual(TimelineScroll.manuallyFastThreshold, 325.0)
        XCTAssertEqual(result(y: 325.0).scrollType, .normal, "comparison is strict")
        let fast = result(y: 325.00000000000006, precise: true)
        XCTAssertEqual(fast.scrollType, .manuallyFast)
        // Classification precedes the precise /10 scaling.
        XCTAssertEqual(fast.delta, -32.500000000000007, accuracy: 1e-12)
    }

    func testShiftPowerUpRequiresShiftWithoutCommandOrOption() {
        let shift = TimelineScrollModifiers(shift: true)
        XCTAssertEqual(result(y: 2, modifiers: shift).scrollType, .shiftPowerUp)
        XCTAssertEqual(result(y: 2, modifiers: shift).delta, -80)

        let commandShift = TimelineScrollModifiers(command: true, shift: true)
        XCTAssertEqual(result(y: 2, modifiers: commandShift).scrollType, .normal)
        XCTAssertEqual(result(y: 2, modifiers: commandShift).delta, -2)

        let optionShift = TimelineScrollModifiers(option: true, shift: true)
        XCTAssertEqual(result(y: 2, modifiers: optionShift).scrollType, .normal)
    }

    /// Shift x40, then precise /10, then zoom scaling — and `.globalScroll`
    /// (ordinal 0, bit 0 clear) is a scaled source.
    func testPreciseAndZoomTransformsComposeAfterPowerUp() {
        let transformed = result(
            y: 2,
            precise: true,
            modifiers: .init(shift: true),
            zoomLevel: 15,
            source: .globalScroll
        )
        // -2 * 40 = -80; /10 = -8; * (15/5) = -24
        XCTAssertEqual(transformed.delta, -24)
        XCTAssertEqual(transformed.scrollType, .shiftPowerUp)

        // The same gesture from `.localScroll` (bit 0 set) is NOT zoom-scaled.
        let unscaled = result(
            y: 2,
            precise: true,
            modifiers: .init(shift: true),
            zoomLevel: 15,
            source: .localScroll
        )
        XCTAssertEqual(unscaled.delta, -8)
    }

    /// `0x100422c54`: `tst w19,#0x1` then `fcsel d0, d0, d1, ne` — the
    /// condition selects the UNSCALED value when bit 0 is **set**. So the
    /// zoom-scaled sources are the even ordinals.
    func testSourceTagParityControlsZoomScaling() {
        // bit 0 clear -> scaled by zoomLevel / 5
        XCTAssertEqual(result(y: 10, zoomLevel: 15, source: .globalScroll).delta, -30)
        XCTAssertEqual(result(y: 10, zoomLevel: 15, source: .timelinePan).delta, -30)
        // bit 0 set -> unscaled
        XCTAssertEqual(result(y: 10, zoomLevel: 15, source: .localScroll).delta, -10)
        XCTAssertEqual(result(y: 10, zoomLevel: 15, source: .click).delta, -10)
    }

    private func result(
        x: Double = 0,
        y: Double = 0,
        precise: Bool = false,
        modifiers: TimelineScrollModifiers = .init(),
        zoomLevel: Double = 5,
        source: TimelineScrubbingSource = .globalScroll
    ) -> TimelineScrollResult {
        TimelineScroll.timeDelta(
            scrollingDeltaX: x,
            scrollingDeltaY: y,
            hasPreciseScrollingDeltas: precise,
            modifiers: modifiers,
            zoomLevel: zoomLevel,
            source: source
        )
    }
}
