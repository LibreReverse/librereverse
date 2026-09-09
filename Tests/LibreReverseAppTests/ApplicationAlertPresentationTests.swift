#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class ApplicationAlertPresentationTests: XCTestCase {
    func testSharedAlertsPreserveActionOrder() {
        let update = LibreReverseApplicationAlerts.make(.availableUpdate(version: "1.2", releaseNotes: true))
        XCTAssertEqual(update.buttons.map(\.title), ["Download", "Later", "Release Notes"])
        let meeting = LibreReverseApplicationAlerts.make(.meetingDetected("Design review"))
        XCTAssertEqual(meeting.buttons.map(\.title), ["Record", "Not Now"])
        XCTAssertTrue(meeting.informativeText.contains("Design review"))
    }

    func testNativeAlertPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_ALERT_PREVIEWS"] else { return }
        _ = NSApplication.shared
        let originalIcon = NSApp.applicationIconImage
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let previewIcon = try XCTUnwrap(NSImage(contentsOf: repository.appendingPathComponent("App/AppIcon.icon/Assets/LibreReverseIcon-1024.png")))
        NSApp.applicationIconImage = previewIcon
        defer { NSApp.applicationIconImage = originalIcon }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(String, LibreReverseApplicationAlerts.Presentation)] = [
            ("updates-unavailable", .updatesUnavailable),
            ("updates-current", .currentVersion("1.2")),
            ("updates-available", .availableUpdate(version: "1.3", releaseNotes: true)),
            ("updates-verified", .verifiedUpdate),
            ("updates-error", .updateError("The network connection is unavailable.")),
            ("library-error", .libraryError("The library is already open in another LibreReverse window.")),
            ("meeting-title", .meetingTitle(initialTitle: "Design review", message: "Rename this recording.")),
            ("meeting-detected", .meetingDetected("Design review")),
        ]
        for (name, presentation) in cases {
            let alert = LibreReverseApplicationAlerts.make(presentation)
            // XCTest is an unbundled host; NSAlert otherwise resolves its folder icon.
            alert.icon = previewIcon
            alert.layout()
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
            alert.window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(alert.window.windowNumber), root.appendingPathComponent("alert-" + name + ".png").path]
            try task.run(); task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0)
            alert.window.orderOut(nil)
        }
    }
}
#endif
