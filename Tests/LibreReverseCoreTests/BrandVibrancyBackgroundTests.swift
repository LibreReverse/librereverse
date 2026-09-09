import LibreReverseCore
import XCTest

final class BrandVibrancyBackgroundTests: XCTestCase {
    func testOpacityTable() {
        XCTAssertEqual(BrandVibrancyBackgroundContract.opacity(for: .light), 0.2)
        XCTAssertEqual(BrandVibrancyBackgroundContract.opacity(for: .medium), 0.5)
        XCTAssertEqual(BrandVibrancyBackgroundContract.opacity(for: .heavy), 0.8)
    }

    func testFrameDetailConstants() {
        XCTAssertEqual(BrandVibrancyBackgroundContract.frameDetailCornerRadius, 10)
        XCTAssertEqual(BrandVibrancyBackgroundContract.frameDetailCallerOpacity, 0.85)
        XCTAssertEqual(BrandVibrancyBackgroundContract.strokeWidth, 1)
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.brandBlackRed,
            0.20000000298023224
        )
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.brandBlackGreen,
            0.20000000298023224
        )
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.brandBlackBlue,
            0.20000000298023224
        )
    }

    func testVisualEffectMappings() {
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.visualEffectMapping(for: .behindWindow),
            .init(
            blendingModeRawValue: 0,
            materialRawValue: 15,
            isAlwaysActive: true,
            isEmphasized: false
        ))
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.visualEffectMapping(for: .withinWindow),
            .init(
            blendingModeRawValue: 1,
            materialRawValue: 15,
            isAlwaysActive: true,
            isEmphasized: false
        ))
        XCTAssertEqual(
            BrandVibrancyBackgroundContract.visualEffectMapping(for: .contentBackground),
            .init(
            blendingModeRawValue: 1,
            materialRawValue: 18,
            isAlwaysActive: true,
            isEmphasized: false
        ))
    }
}
