#if os(macOS)
import Carbon
import XCTest
@testable import LibreReverseApp

final class ShortcutSettingsTests: XCTestCase {
    func testDefaultsPreserveRecoveredRegistrationOrderAndChords() throws {
        let settings = try LibreReverseShortcutSettings.defaults.validated()

        XCTAssertEqual(settings.toggleCapture?.displayName, "⌃⌥⌘M")
        XCTAssertEqual(settings.starCurrentMoment?.virtualKeyCode, 1)
        XCTAssertEqual(settings.askRewind?.virtualKeyCode, 44)
        XCTAssertEqual(settings.dailyRecap?.virtualKeyCode, 41)
        XCTAssertEqual(settings.openTimeline?.virtualKeyCode, 49)
        XCTAssertEqual(settings.openTimeline?.displayName, "⇧⌘Space")
        XCTAssertTrue(settings.scrollToRewindEnabled)
        XCTAssertEqual(
            LibreReverseShortcutAction.allCases.map(\.carbonIdentifier),
            [5, 4, 2, 3, 1]
        )
    }

    func testDuplicateChordFailsWithBothOwningActions() {
        var settings = LibreReverseShortcutSettings.defaults
        settings.toggleCapture = .init(
            virtualKeyCode: settings.openTimeline!.virtualKeyCode,
            modifiers: settings.openTimeline!.modifiers,
            keyLabel: "A deliberately wrong display label"
        )

        XCTAssertThrowsError(try settings.validated()) { error in
            XCTAssertEqual(
                error as? LibreReverseShortcutSettingsError,
                .duplicate(.toggleCapture, .openTimeline)
            )
        }
    }

    func testShiftOnlyChordFailsClosed() {
        var settings = LibreReverseShortcutSettings.defaults
        settings.toggleCapture = .init(
            virtualKeyCode: 0,
            modifiers: UInt32(shiftKey),
            keyLabel: "A"
        )

        XCTAssertThrowsError(try settings.validated()) { error in
            XCTAssertEqual(
                error as? LibreReverseShortcutSettingsError,
                .unsafe(.toggleCapture)
            )
        }
    }

    func testPreferencesRoundTripPreservesCustomizedBindingsAndScrollChoice() throws {
        let suiteName = "ShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var customized = LibreReverseShortcutSettings.defaults
        customized.scrollToRewindEnabled = false
        customized.toggleCapture = .init(
            virtualKeyCode: 0,
            modifiers: UInt32(cmdKey) | UInt32(optionKey),
            keyLabel: "A"
        )
        customized.openTimeline = nil
        try LibreReverseShortcutPreferences.save(customized, to: defaults)

        XCTAssertEqual(
            LibreReverseShortcutPreferences.load(from: defaults),
            customized
        )
    }

    func testCorruptPreferencesFallBackToRecoveredDefaults() throws {
        let suiteName = "ShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: LibreReverseShortcutPreferences.key)

        XCTAssertEqual(
            LibreReverseShortcutPreferences.load(from: defaults),
            .defaults
        )
    }
}
#endif
