import XCTest
import AppKit
@testable import LibreReverseApp

@MainActor
final class SettingsChromeTests: XCTestCase {
    func testSettingsChromeExposesCurrentAppSections() {
        let descriptors = LibreReverseSettingsWindowController.sectionDescriptors

        XCTAssertEqual(
            descriptors.map(\.section),
            [.general, .screen, .meetings, .ai, .storage, .shortcuts]
        )
        XCTAssertEqual(
            descriptors.map(\.label),
            ["General", "Screen", "Meetings", "AI", "Storage", "Shortcuts"]
        )
        XCTAssertEqual(Set(descriptors.map(\.symbolName)).count, descriptors.count)
    }
    func testShortcutConflictHasVisibleNativeFeedback() throws {
        _ = NSApplication.shared
        let controller = LibreReverseShortcutsSettingsViewController(settings: { .defaults }, updateSettings: { _ = try $0.validated() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 800))
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        let recorder = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "shortcuts.askRewind.recorder" } as? NSButton)
        recorder.performClick(nil)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        recorder.keyDown(with: event)
        let error = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "shortcuts.error" } as? NSTextField)
        XCTAssertFalse(error.isHidden)
        XCTAssertFalse(error.stringValue.isEmpty)
        if let output = ProcessInfo.processInfo.environment["LIBREREVERSE_CONNECTED_STORAGE_PREVIEWS"] {
            window.center(); window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output + "/settings-shortcuts-conflict.png"]
            try capture.run(); capture.waitUntilExit(); XCTAssertEqual(capture.terminationStatus, 0)
        }
        window.orderOut(nil)
    }

}
