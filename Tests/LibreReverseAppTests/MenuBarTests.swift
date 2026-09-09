import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class MenuBarTests: XCTestCase {
    func testMeetingSaveFailureDoesNotDisableScreenCapture() {
        let snapshot = LibreReverseMenuBarSnapshot(
            recordingDisabledReason: nil, screenCaptureEnabled: true, screenCaptureAvailable: true,
            audioCaptureEnabled: false, audioCaptureAvailable: true, backupTitle: "Backup",
            versionTitle: "Version", updateTitle: "Updates", updateAvailable: false,
            meetingSaveWarning: "Meeting could not be saved. Its files are kept locally.")
        let rows = LibreReverseMenuBarContract.presentations(snapshot: snapshot, shortcuts: .defaults)
        XCTAssertEqual(rows.first { $0.id == .recordingBanner }?.title, snapshot.meetingSaveWarning)
        XCTAssertEqual(rows.first { $0.id == .recordingBanner }?.isHidden, false)
        XCTAssertEqual(rows.first { $0.id == .screenCapture }?.isEnabled, true)
    }

    @MainActor
    func testBrowserTabExitRequiresACompleteRecognizableIdentity() {
        let candidate = LibreReverseMeetingCandidate(provider: .googleMeet, source: .windowDetection,
            title: "Meet – abc-defg-hij", url: URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(LibreReverseForegroundContextProvider.meetTabIsAbsent(candidate: candidate, tabTitles: ["Inbox", "Meeting notes - Gmail"]))
        for titles in [[], [""], ["Inbox", "Meet – abc-defg-hij"], ["Meet – Other room"]] {
            XCTAssertFalse(LibreReverseForegroundContextProvider.meetTabIsAbsent(candidate: candidate, tabTitles: titles))
        }
    }

    func testProductMenuHidesSetupWhenPermissionsAreNotTheBlocker() {
        let snapshot = LibreReverseMenuBarSnapshot(
            recordingDisabledReason: "LibreReverse has been shut down",
            screenCaptureEnabled: false,
            screenCaptureAvailable: false,
            audioCaptureEnabled: true,
            audioCaptureAvailable: true,
            backupTitle: "Backup • Connected",
            versionTitle: "Version 0.1",
            updateTitle: "Check for Updates…",
            updateAvailable: true
        )
        let rows = LibreReverseMenuBarContract.presentations(
            snapshot: snapshot,
            shortcuts: .defaults
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(
            LibreReverseMenuBarContract.sectionOrder.flatMap { $0 },
            [.recordingBanner, .quickStart, .search, .ask, .dailyRecap, .screenCapture,
             .audioCapture, .settings, .backup, .openDataFolder,
             .version, .checkForUpdates, .quit]
        )
        XCTAssertEqual(
            byID[.recordingBanner]?.title,
            "Recording is disabled because LibreReverse has been shut down"
        )
        XCTAssertTrue(byID[.quickStart]?.isHidden == true)
        XCTAssertEqual(byID[.screenCapture]?.isEnabled, false)
        XCTAssertEqual(byID[.screenCapture]?.isOn, false)
        XCTAssertNil(byID[.audioCapture]?.isOn)
        XCTAssertEqual(byID[.audioCapture]?.title, "Stop Meeting Recording")
    }

    func testMissingPermissionsHaveADirectSetupAction() {
        let snapshot = LibreReverseMenuBarSnapshot(
            recordingDisabledReason: "required permissions are missing",
            screenCaptureEnabled: false, screenCaptureAvailable: false,
            audioCaptureEnabled: false, audioCaptureAvailable: false,
            backupTitle: "Backup", versionTitle: "Version", updateTitle: "Updates", updateAvailable: false)
        let setup = LibreReverseMenuBarContract.presentations(snapshot: snapshot, shortcuts: .defaults).first { $0.id == .quickStart }
        XCTAssertEqual(setup?.title, "Finish Recording Setup…")
        XCTAssertEqual(setup?.isHidden, false)
        XCTAssertEqual(setup?.isEnabled, true)
    }

    func testMenuUsesEditableRecoveredShortcuts() {
        let snapshot = LibreReverseMenuBarSnapshot(
            recordingDisabledReason: nil,
            screenCaptureEnabled: true,
            screenCaptureAvailable: true,
            audioCaptureEnabled: false,
            audioCaptureAvailable: true,
            backupTitle: "Backup • Not connected",
            versionTitle: "Version 0.1",
            updateTitle: "Updates unavailable in this build",
            updateAvailable: false
        )
        let rows = LibreReverseMenuBarContract.presentations(
            snapshot: snapshot,
            shortcuts: .defaults
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertTrue(byID[.recordingBanner]?.isHidden == true)
        XCTAssertEqual(byID[.search]?.shortcut?.displayName, "⇧⌘Space")
        XCTAssertEqual(byID[.ask]?.shortcut?.displayName, "⇧⌘/")
        XCTAssertEqual(byID[.dailyRecap]?.shortcut?.displayName, "⇧⌘;")
        let equivalent = LibreReverseMenuBarContract.keyEquivalent(
            for: byID[.search]?.shortcut
        )
        XCTAssertEqual(equivalent.key, " ")
        XCTAssertEqual(equivalent.modifiers, [.command, .shift])
    }
}
