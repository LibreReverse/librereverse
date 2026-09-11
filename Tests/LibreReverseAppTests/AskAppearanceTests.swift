import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AskAppearanceTests: XCTestCase {
    func testAnswerAndQueryFitWindow() throws {
        _ = NSApplication.shared
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: { }, openMoment: { _ in })
        controller.presentFixture(question: "What did we decide about the launch?", answer: .init(
            text: "The team agreed to release on Friday.\n\nAlex will test screen sharing, and Morgan will review transcription accuracy.",
            citations: [.init(instant: Date(timeIntervalSince1970: 1_700_000_000), title: "Weekly planning", excerpt: "Release on Friday", source: "Meeting")]))
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(view.subviews.first as? NSStackView)
        for child in root.arrangedSubviews where !child.isHidden {
            XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(child.convert(child.bounds, to: view)), "Clipped Ask row")
        }
        if let path = ProcessInfo.processInfo.environment["LIBREREVERSE_ASK_PREVIEW"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    func testDisconnectedSetupDoesNotExposeDisabledComposerOrOverflowCopy() throws {
        _ = NSApplication.shared
        var settingsOpened = 0
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { nil }, openAISettings: { settingsOpened += 1 }, openMoment: { _ in })
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let query = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "ask.question" })
        XCTAssertTrue(query.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(descendants(content).contains { $0 is NSSecureTextField })
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.contains { ["Connect", "Disconnect"].contains($0.title) })
        let settings = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "ask.setup.ai-settings" })
        XCTAssertFalse(settings.isHiddenOrHasHiddenAncestor)
        settings.performClick(nil)
        XCTAssertEqual(settingsOpened, 1)
        let root = try XCTUnwrap(content.subviews.first as? NSStackView)
        for row in root.arrangedSubviews where !row.isHidden {
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(row.convert(row.bounds, to: content)))
        }
    }

    func testReturningFromSettingsReloadsCredentialsWithoutAskMutations() throws {
        _ = NSApplication.shared
        var credential: String?
        var opened = 0
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { credential }, openAISettings: { opened += 1 }, openMoment: { _ in })
        let content = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let query = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "ask.question" })
        XCTAssertFalse(query.isEditable)
        credential = "synthetic-saved-in-settings"
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window))
        XCTAssertTrue(query.isEditable)
        XCTAssertFalse(query.isHiddenOrHasHiddenAncestor)
        let settings = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "ask.ai-settings" })
        settings.performClick(nil)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(credential, "synthetic-saved-in-settings")
        credential = nil
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window))
        XCTAssertFalse(query.isEditable)
        XCTAssertTrue(query.isHiddenOrHasHiddenAncestor)
    }

}
