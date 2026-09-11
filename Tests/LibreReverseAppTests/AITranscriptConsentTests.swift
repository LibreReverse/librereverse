import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AITranscriptConsentTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func fixture(_ body: (LibreReverseAISettingsViewController, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let name = "AITranscriptConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try LibreReverseAIProfiles.save([.local, .deepSeek, .openAI], selected: LibreReverseAIProfile.deepSeek.id, defaults: defaults)
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in }, defaults: defaults)
        _ = controller.view
        try body(controller, defaults)
    }

    private func button(_ id: String, _ controller: LibreReverseAISettingsViewController) throws -> NSButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id })
    }
    private func save(_ controller: LibreReverseAISettingsViewController) throws {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Save profile" }).performClick(nil)
    }

    func testCloudConsentEditorFitsSettingsWindow() throws {
        try fixture { controller, _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 730),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.view
            controller.view.layoutSubtreeIfNeeded()
            let stack = try XCTUnwrap(controller.view.subviews.first as? NSStackView)
            for row in stack.arrangedSubviews {
                XCTAssertTrue(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(row.convert(row.bounds, to: controller.view)))
            }
            let toggle = try button("settings.ai.full-transcripts", controller)
            XCTAssertTrue(controller.view.bounds.contains(toggle.convert(toggle.bounds, to: controller.view)))
        }
    }

    func testGrantAndRevokeArePersistedOnlyForSelectedCloudProfile() throws {
        try fixture { controller, defaults in
            let toggle = try button("settings.ai.full-transcripts", controller)
            XCTAssertEqual(toggle.state, .off)
            XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor)
            toggle.performClick(nil)
            XCTAssertFalse(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization, "Editing requires Save profile")
            try save(controller)
            XCTAssertTrue(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
            XCTAssertFalse(try XCTUnwrap(LibreReverseAIProfiles.load(defaults).first { $0.id == "openai" }).hasFullTranscriptAuthorization)
            toggle.performClick(nil)
            try save(controller)
            XCTAssertNil(LibreReverseAIProfiles.selected(defaults).fullTranscriptAuthorization)
        }
    }

    func testEveryRouteEditClearsConsentAndRequiresExplicitRegrant() throws {
        try fixture { controller, defaults in
            let toggle = try button("settings.ai.full-transcripts", controller)
            for id in ["settings.ai.model", "settings.ai.routing"] {
                toggle.performClick(nil)
                try save(controller)
                let field = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id })
                field.stringValue += "-changed"
                controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                XCTAssertEqual(toggle.state, .off)
                try save(controller)
                XCTAssertFalse(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
            }
            toggle.performClick(nil)
            try button("settings.ai.fallbacks", controller).performClick(nil)
            XCTAssertEqual(toggle.state, .off)
            try save(controller)
            XCTAssertFalse(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
            toggle.performClick(nil)
            let provider = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.ai.provider" })
            provider.selectItem(withTitle: LibreReverseAIProfile.Provider.openAI.rawValue)
            _ = provider.sendAction(try XCTUnwrap(provider.action), to: provider.target)
            XCTAssertEqual(toggle.state, .off)
            try save(controller)
            XCTAssertFalse(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
            toggle.performClick(nil)
            try save(controller)
            XCTAssertTrue(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
        }
    }

    func testSaveRejectsChangedRouteEvenWithoutTextNotificationAndLocalHidesConsent() throws {
        try fixture { controller, defaults in
            let toggle = try button("settings.ai.full-transcripts", controller)
            toggle.performClick(nil)
            let model = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "settings.ai.model" })
            model.stringValue = "another-model"
            try save(controller)
            XCTAssertFalse(LibreReverseAIProfiles.selected(defaults).hasFullTranscriptAuthorization)
            let profile = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.ai.profile" })
            profile.selectItem(at: 0)
            _ = profile.sendAction(try XCTUnwrap(profile.action), to: profile.target)
            XCTAssertTrue(toggle.isHiddenOrHasHiddenAncestor)
            try save(controller)
            XCTAssertNil(LibreReverseAIProfiles.selected(defaults).fullTranscriptAuthorization)
        }
    }
}
