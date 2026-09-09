import XCTest
@testable import LibreReverseApp
import LibreReverseCore

final class AIProfileTests: XCTestCase {
    func testNamedRoutesPersistWithoutCredentialsAndKeepProviderKeysSeparate() throws {
        let suite = "AIProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var route = LibreReverseAIProfile.deepSeek
        route.preferredProviders = ["DeepSeek"]
        route.allowFallbacks = false
        try LibreReverseAIProfiles.save([.openAI, route], selected: route.id, defaults: defaults)
        XCTAssertEqual(LibreReverseAIProfiles.selected(defaults), route)
        let keyAccount = route.credentialAccount
        route.provider = .openAI
        XCTAssertNotEqual(keyAccount, route.credentialAccount)
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: LibreReverseAIProfiles.profilesKey)), encoding: .utf8)!.contains("api-key"))
    }

    func testOpenRouterRequestUsesSelectedModelAndRoutingPolicy() throws {
        var profile = LibreReverseAIProfile.deepSeek
        profile.preferredProviders = ["DeepSeek"]
        profile.allowFallbacks = false
        let request = try LibreReverseOpenRouterProvider(profile: profile)
            .request(question: "What was decided?", citations: [], apiKey: "synthetic-test-key")
        XCTAssertEqual(request.url?.host, "openrouter.ai")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, profile.model)
        let routing = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(routing["order"] as? [String], ["DeepSeek"])
        XCTAssertEqual(routing["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(routing["data_collection"] as? String, "deny")
    }

    func testOptInSyntheticOpenRouterConnectionUsesIsolatedPersistence() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_SETUP_OPENROUTER"] == "1" else {
            throw XCTSkip("Opt-in synthetic provider connection only")
        }
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["OPEN_ROUTER_API_KEY"])
        let profile = LibreReverseAIProfile.deepSeek
        // No library content goes to the provider in this connection test.
        let response = try await LibreReverseOpenRouterProvider(profile: profile).answer(
            question: "What is the test result?", citations: [.init(instant: Date(timeIntervalSince1970: 0),
                title: "Synthetic connection test", excerpt: "The test result is CONNECTED.", source: "Synthetic")], apiKey: key)
        XCTAssertFalse(response.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIProfileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"), mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(library)
        try LibreReverseArchiveStore.setCredentialData(Data(key.utf8), account: profile.credentialAccount, configuration: library)
        let suite = "AIProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var profiles = LibreReverseAIProfiles.load(defaults)
        if !profiles.contains(where: { $0.id == profile.id }) { profiles.append(profile) }
        try LibreReverseAIProfiles.save(profiles, selected: profile.id, defaults: defaults)
    }
}
