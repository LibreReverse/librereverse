#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class CaptureSettingsTests: XCTestCase {
    func testPreferenceDefaultsKeepPauseReminderOnAndOCRResourceUseStandard() throws {
        let suiteName = "CaptureSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(LibreReverseCaptureSettingsPreferences.remindWhenPaused(defaults))
        XCTAssertEqual(LibreReverseCaptureSettingsPreferences.ocrLanguageMode(defaults), .standard)
        defaults.set(false, forKey: LibreReverseCaptureSettingsPreferences.remindWhenPausedKey)
        defaults.set(
            LibreReverseOCRLanguageMode.additional.rawValue,
            forKey: LibreReverseCaptureSettingsPreferences.ocrLanguageModeKey
        )
        XCTAssertFalse(LibreReverseCaptureSettingsPreferences.remindWhenPaused(defaults))
        XCTAssertEqual(LibreReverseCaptureSettingsPreferences.ocrLanguageMode(defaults), .additional)
    }

    func testPersistedScreenPrivacyMapsDirectlyIntoLiveCapturePolicy() throws {
        let suiteName = "CaptureSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["com.example.Secret", "com.example.Payroll"],
            forKey: LibreReverseCaptureSettingsPreferences.omittedApplicationsKey
        )
        defaults.set(
            false,
            forKey: LibreReverseCaptureSettingsPreferences.excludePrivateWindowsKey
        )

        let settings = LibreReverseCaptureSettingsPreferences.privacySettings(
            defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(
            settings.omittedAppBundleIdentifiers,
            ["com.example.Secret", "com.example.Payroll"]
        )
        XCTAssertFalse(settings.excludeIncognito)
    }

    func testPausedReminderRetainsRecoveredOneHourFixedInterval() {
        XCTAssertEqual(LibreReversePausedReminderContract.delay, 3_600)
        XCTAssertEqual(LibreReversePausedReminderContract.identifier, "local.librereverse.capture-paused")
    }

    func testGeneralControllerReflectsAllThreeProductionSettings() {
        let value = LibreReverseGeneralSettingsSnapshot(
            launchAtLogin: true,
            remindWhenPaused: false,
            showInDock: true
        )
        let controller = LibreReverseGeneralSettingsViewController(
            snapshot: { value },
            updateLaunchAtLogin: { _ in },
            updateRemindWhenPaused: { _ in },
            updateShowInDock: { _ in }
        )
        let labels = textValues(in: controller.view)
        XCTAssertTrue(labels.contains("Open at login"))
        XCTAssertTrue(labels.contains("Remind when paused"))
        XCTAssertTrue(labels.contains("Show in Dock"))
        func switches(_ view: NSView) -> [NSSwitch] {
            (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(switches)
        }
        let controls = switches(controller.view)
        XCTAssertEqual(controls.count, 3)
        XCTAssertEqual(controls.map(\.state), [.on, .off, .on])
        XCTAssertEqual(controls.compactMap { $0.accessibilityLabel() }, [
            "Open at login", "Remind when paused", "Show in Dock",
        ])
    }

    func testScreenControllerExposesLivePrivacyAndOCRControls() {
        let controller = LibreReverseScreenSettingsViewController(
            snapshot: {
                .init(
                    omittedBundleIdentifiers: ["com.example.Secret"],
                    excludePrivateWindows: true,
                    ocrLanguageMode: .standard,
                    showRunningProcesses: true,
                    applications: [
                        .init(
                            bundleIdentifier: "com.example.Secret",
                            name: "Secret Notes",
                            applicationURL: nil,
                            isRunningProcess: true,
                            isInstalledApplication: false
                        )
                    ]
                )
            },
            updateOmittedApplications: { _ in },
            updateExcludePrivateWindows: { _ in },
            updateOCRLanguageMode: { _ in },
            updateShowRunningProcesses: { _ in }
        )
        let labels = textValues(in: controller.view)
        XCTAssertTrue(labels.contains("Show Running Processes"))
        XCTAssertTrue(labels.contains("Do not record Incognito and Private windows"))
        XCTAssertTrue(labels.contains("Text Recognition:"))
    }

    private func textValues(in root: NSView) -> [String] {
        var result: [String] = []
        if let field = root as? NSTextField { result.append(field.stringValue) }
        if let button = root as? NSButton { result.append(button.title) }
        for child in root.subviews { result.append(contentsOf: textValues(in: child)) }
        return result
    }
}
#endif
