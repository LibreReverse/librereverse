import AppKit
import XCTest
@testable import LibreReverseApp
import LibreReverseCore

@MainActor
final class PermissionSetupTests: XCTestCase {
    func testFreshSnapshotStartsCaptureAndKeepsChecklistOpen() {
        _ = NSApplication.shared
        var state = PermissionGrantContract.PublishedState(accessibility: false, screenCapture: false, microphone: false)
        let permissions = LibreReversePermissionsController(readState: { state })
        let suite = "LibreReverse.PermissionSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        let controller = LibreReverseQuickStartWindowController(
            permissions: permissions, defaults: defaults,
            recordingStatus: { starts > 0 ? .recording : .waiting },
            startCapture: { starts += 1 }
        )
        controller.window?.orderFront(nil)
        defer { controller.window?.orderOut(nil) }
        controller.refresh()
        savePreview(controller, name: "waiting")
        XCTAssertEqual(starts, 0)
        state.screenCapture = true
        controller.refresh()
        XCTAssertEqual(starts, 0)
        state.accessibility = true
        controller.refresh()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(controller.window?.isVisible == true)
        savePreview(controller, name: "ready")
        XCTAssertTrue(defaults.bool(forKey: LibreReverseQuickStartWindowController.completionDefaultsKey))
        let labels = texts(in: controller.window!.contentView!)
        XCTAssertTrue(labels.contains(where: { $0.contains("Recording is on") }))
        XCTAssertTrue(labels.contains(where: { $0.contains("Optional") && $0.contains("meeting") }))
        XCTAssertEqual(labels.filter { $0 == "✓" }.count, 2)
        state.microphone = true
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(texts(in: controller.window!.contentView!).filter { $0 == "✓" }.count, 3)
    }

    func testCompletedSetupDoesNotSuppressMissingPermissionRecovery() {
        _ = NSApplication.shared
        var state = PermissionGrantContract.PublishedState(accessibility: true, screenCapture: false, microphone: false)
        let permissions = LibreReversePermissionsController(readState: { state })
        let suite = "LibreReverse.PermissionSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LibreReverseQuickStartWindowController.completionDefaultsKey)
        var starts = 0
        let controller = LibreReverseQuickStartWindowController(permissions: permissions, defaults: defaults, startCapture: { starts += 1 })
        controller.refresh()
        XCTAssertEqual(starts, 0)
        state.screenCapture = true
        controller.refresh()
        XCTAssertEqual(starts, 1)
    }

    private func savePreview(_ controller: LibreReverseQuickStartWindowController, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_PERMISSION_TEST_PREVIEWS"],
              let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["LIBREREVERSE_NATIVE_WINDOW_PREVIEWS"] == "1",
            let window = controller.window {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                URL(fileURLWithPath: directory).appendingPathComponent("setup-\(name).png").path]
            do {
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0, "Native setup window capture failed")
            } catch { XCTFail("Native setup window capture failed: \(error)") }
            return
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("setup-\(name).png"))
    }

    private func texts(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? []
            + view.subviews.flatMap { texts(in: $0) }
    }
}
