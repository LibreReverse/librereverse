import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AISettingsAppearanceTests: XCTestCase {
    func testProfileEditorFitsSettingsContent() throws {
        _ = NSApplication.shared
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 730),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(controller.view).compactMap { $0 as? NSTextField }
        if LibreReverseAIProfiles.selected().provider == .local {
            let key = try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == "settings.ai.api-key" })
            XCTAssertTrue(key.isHiddenOrHasHiddenAncestor, "Local profiles must not show irrelevant credentials")
            let routing = try XCTUnwrap(fields.first { $0.placeholderString?.hasPrefix("Preferred OpenRouter") == true })
            XCTAssertTrue(routing.isHiddenOrHasHiddenAncestor)
        }
        let stack = try XCTUnwrap(controller.view.subviews.first as? NSStackView)
        for child in stack.arrangedSubviews {
            let frame = child.convert(child.bounds, to: controller.view)
            XCTAssertTrue(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Clipped settings row: \(frame)")
        }
        if let path = ProcessInfo.processInfo.environment["LIBREREVERSE_AI_SETTINGS_PREVIEW"],
            let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
