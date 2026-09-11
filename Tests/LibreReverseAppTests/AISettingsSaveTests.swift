import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AISettingsSaveTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func field(_ controller: LibreReverseAISettingsViewController, _ id: String) throws -> NSTextField {
        try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier() == id } as? NSTextField)
    }
    private func save(_ controller: LibreReverseAISettingsViewController) throws {
        let button = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier() == "settings.ai.save" } as? NSButton)
        button.performClick(nil)
    }
    private func defaults(_ profile: LibreReverseAIProfile = .openAI) throws -> (UserDefaults, String) {
        _ = NSApplication.shared
        let name = "LibreReverse.AISettingsSaveTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        try LibreReverseAIProfiles.save(profile.provider == .local ? [profile] : [.local, profile], selected: profile.id, defaults: defaults)
        return (defaults, name)
    }

    func testOneSaveWritesProfileAndKeyToEditedDestination() throws {
        let (defaults, suite) = try defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        var writes: [(String?, LibreReverseAIProfile)] = []
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: {
            writes.append(($0, LibreReverseAIProfiles.selected(defaults)))
        }, defaults: defaults)
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.filter { $0.title == "Save" }.count, 1)
        XCTAssertFalse(buttons.contains { $0.title == "Save profile" || $0.title == "Save key" })
        let provider = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier() == "settings.ai.provider" } as? NSPopUpButton)
        provider.selectItem(withTitle: LibreReverseAIProfile.Provider.openRouter.rawValue)
        try field(controller, "settings.ai.model").stringValue = "synthetic/edited-model"
        try field(controller, "settings.ai.routing").stringValue = "SyntheticRoute"
        try field(controller, "settings.ai.api-key").stringValue = "  synthetic-key  "
        try save(controller)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "synthetic-key")
        XCTAssertEqual(writes.first?.1.provider, .openRouter)
        XCTAssertEqual(writes.first?.1.model, "synthetic/edited-model")
        XCTAssertEqual(writes.first?.1.preferredProviders, ["SyntheticRoute"])
        XCTAssertEqual(try field(controller, "settings.ai.api-key").stringValue, "")
        XCTAssertTrue(try field(controller, "settings.ai.status").stringValue.hasPrefix("Saved."))
    }

    func testBlankKeyPreservesCredentialWhileSavingModel() throws {
        let (defaults, suite) = try defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        var writes = 0
        let controller = LibreReverseAISettingsViewController(apiKey: { "existing-synthetic-key" }, updateAPIKey: { _ in writes += 1 }, defaults: defaults)
        try field(controller, "settings.ai.model").stringValue = "edited-model"
        try field(controller, "settings.ai.api-key").stringValue = "  "
        try save(controller)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults).model, "edited-model")
    }

    func testInvalidModelDoesNotWriteKeyOrProfile() throws {
        let (defaults, suite) = try defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let original = LibreReverseAIProfiles.selected(defaults)
        var writes = 0
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in writes += 1 }, defaults: defaults)
        try field(controller, "settings.ai.model").stringValue = "  "
        try field(controller, "settings.ai.api-key").stringValue = "synthetic-key"
        try save(controller)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults), original)
        XCTAssertEqual(try field(controller, "settings.ai.api-key").stringValue, "synthetic-key")
        XCTAssertTrue(try field(controller, "settings.ai.status").stringValue.hasPrefix("Could not save:"))
    }

    func testCredentialFailureRestoresProfileAndKeepsTypedKeyForRetry() throws {
        let (defaults, suite) = try defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let original = LibreReverseAIProfiles.selected(defaults)
        var shouldFail = true
        var attemptedModels: [String] = []
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in
            attemptedModels.append(LibreReverseAIProfiles.selected(defaults).model)
            if shouldFail { throw NSError(domain: "SyntheticCredentialFailure", code: 1) }
        }, defaults: defaults)
        try field(controller, "settings.ai.model").stringValue = "retry-model"
        try field(controller, "settings.ai.api-key").stringValue = "synthetic-retry-key"
        try save(controller)
        XCTAssertEqual(attemptedModels, ["retry-model"])
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults), original)
        XCTAssertEqual(try field(controller, "settings.ai.api-key").stringValue, "synthetic-retry-key")
        shouldFail = false
        try save(controller)
        XCTAssertEqual(attemptedModels, ["retry-model", "retry-model"])
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults).model, "retry-model")
        XCTAssertEqual(try field(controller, "settings.ai.api-key").stringValue, "")
    }

    func testChangingLocalToCloudEnablesKeyBeforeSaving() throws {
        let (defaults, suite) = try defaults(.local); defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in }, defaults: defaults)
        let key = try field(controller, "settings.ai.api-key")
        XCTAssertFalse(key.isEnabled)
        let popup = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier() == "settings.ai.provider" } as? NSPopUpButton)
        popup.selectItem(withTitle: LibreReverseAIProfile.Provider.openRouter.rawValue)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup))
        XCTAssertTrue(key.isEnabled)
        XCTAssertFalse(key.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults).provider, .local, "Editing must not select the cloud destination before Save")
    }

    func testLocalProfileSavesWithoutCredentialWrite() throws {
        let (defaults, suite) = try defaults(.local); defer { defaults.removePersistentDomain(forName: suite) }
        var writes = 0
        let controller = LibreReverseAISettingsViewController(apiKey: { nil }, updateAPIKey: { _ in writes += 1 }, defaults: defaults)
        try save(controller)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults).provider, .local)
        XCTAssertTrue(try field(controller, "settings.ai.status").stringValue.hasPrefix("Saved."))
    }
}
