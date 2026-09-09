#if os(macOS)
import XCTest
@testable import LibreReverseCore

final class XIDTests: XCTestCase {
    func testCanonicalValidationRequiresExactLegacyAlphabetAndLength() {
        XCTAssertTrue(XID.isValid("c5q1r6b49g5u0i2k1j4g"))
        XCTAssertFalse(XID.isValid("c5q1r6b49g5u0i2k1j4"))
        XCTAssertFalse(XID.isValid("c5q1r6b49g5u0i2k1j4g0"))
        XCTAssertFalse(XID.isValid("C5q1r6b49g5u0i2k1j4g"))
        XCTAssertFalse(XID.isValid("c5q1r6b49g5u0i2k1j4w"))
    }

    func testExactByteLayoutAndBase32Encoding() {
        XCTAssertEqual(
            XID.string(
                timestamp: 0x6930_943b,
                machineIdentifier: [0x1b, 0x45, 0x28],
                processIdentifier: 0x03ec,
                counter: 0xf1_b812
            ),
            "d4o98eor8kk07r7hn090"
        )
    }

    func testCounterUsesOnlyLowThreeBytes() {
        XCTAssertEqual(
            XID.string(
                timestamp: 0,
                machineIdentifier: [0, 0, 0],
                processIdentifier: 0,
                counter: 0xab12_3456
            ),
            XID.string(
                timestamp: 0,
                machineIdentifier: [0, 0, 0],
                processIdentifier: 0,
                counter: 0x0012_3456
            )
        )
    }
}
#endif
