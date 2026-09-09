#if os(macOS)
import XCTest
@testable import LibreReverseCore

final class BrowserPrivacyTests: XCTestCase {
    func testChromeTitleGrammarAndExactClassifierOrder() {
        XCTAssertEqual(
            BrowserPrivacy.chromeTitle("Docs - Google Chrome - Person 1"),
            ChromeTitle(pageTitle: "Docs", profile: "Person 1", type: .profile)
        )
        XCTAssertEqual(
            BrowserPrivacy.chromeTitle("Docs – Google Chrome Beta"),
            ChromeTitle(pageTitle: "Docs", profile: nil, type: .normal)
        )
        XCTAssertEqual(
            BrowserPrivacy.chromeTitle("Docs - Google Chrome Dev (Incognito)"),
            ChromeTitle(pageTitle: "Docs", profile: nil, type: .incognito)
        )
        XCTAssertEqual(
            BrowserPrivacy.chromeTitle("Docs – Google Chrome (Guest)"),
            ChromeTitle(pageTitle: "Docs", profile: nil, type: .guest)
        )
    }

    func testChromeURLNormalizationUsesExactNewTabDotAndSchemeRules() {
        XCTAssertNil(BrowserPrivacy.chromeURL(addressBarValue: nil))
        XCTAssertNil(BrowserPrivacy.chromeURL(addressBarValue: "New tab"))
        XCTAssertNil(BrowserPrivacy.chromeURL(addressBarValue: "localhost"))
        XCTAssertEqual(
            BrowserPrivacy.chromeURL(addressBarValue: "example.com")?.absoluteString,
            "http://example.com"
        )
        XCTAssertEqual(
            BrowserPrivacy.chromeURL(addressBarValue: "https://example.com/path")?.absoluteString,
            "https://example.com/path"
        )
        XCTAssertEqual(
            BrowserPrivacy.chromeURL(addressBarValue: "chrome://settings.example")?.absoluteString,
            "chrome://settings.example"
        )
    }

    func testFirefoxPrivateModeUsesCaseSensitiveContains() {
        XCTAssertEqual(
            BrowserPrivacy.firefoxState(windowTitle: "Example — Private Browsing"),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.firefoxState(windowTitle: "Private Browsing: Example"),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.firefoxState(windowTitle: "private browsing"),
            .capture
        )
    }

    func testBravePrivateSuffixAndURLNormalization() {
        XCTAssertEqual(
            BrowserPrivacy.braveState(windowTitle: "Docs - Brave (Private)"),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.braveState(windowTitle: "Brave (Private) - Docs"),
            .capture
        )
        XCTAssertEqual(
            BrowserPrivacy.braveState(windowTitle: "Docs - Brave (private)"),
            .capture
        )
        XCTAssertNil(BrowserPrivacy.braveURL(addressBarValue: "New tab"))
        XCTAssertEqual(
            BrowserPrivacy.braveURL(addressBarValue: "brave.com")?.absoluteString,
            "http://brave.com"
        )
        XCTAssertEqual(
            BrowserPrivacy.braveURL(addressBarValue: "https://brave.com")?.absoluteString,
            "https://brave.com"
        )
    }

    func testArcPrivateTitleMarkerIsCaseSensitiveContains() {
        XCTAssertEqual(BrowserPrivacy.arcState(windowTitle: nil), .unresolved)
        XCTAssertEqual(BrowserPrivacy.arcState(windowTitle: ""), .unresolved)
        XCTAssertEqual(
            BrowserPrivacy.arcState(windowTitle: "bigIncognitoBrowserWindow"),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.arcState(
                windowTitle: "prefix bigIncognitoBrowserWindow suffix"
            ),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.arcState(windowTitle: "bigincognitobrowserwindow"),
            .capture
        )
    }

    func testSafariTitledWindowUsesExactCaseSensitiveSuffix() {
        XCTAssertEqual(
            BrowserPrivacy.safariTitledWindowState(
                windowTitle: "Example, Private Browsing"
            ),
            .privateMode
        )
        XCTAssertEqual(
            BrowserPrivacy.safariTitledWindowState(
                windowTitle: "Private Browsing, Example"
            ),
            .capture
        )
        XCTAssertEqual(
            BrowserPrivacy.safariTitledWindowState(
                windowTitle: "Example, private browsing"
            ),
            .capture
        )
    }

    func testSafariURLNormalizationUsesExactStartPageDotAndSchemeRules() {
        XCTAssertNil(BrowserPrivacy.safariURL(addressBarValue: nil))
        XCTAssertNil(BrowserPrivacy.safariURL(addressBarValue: "Start Page"))
        XCTAssertNil(BrowserPrivacy.safariURL(addressBarValue: "localhost"))
        XCTAssertNil(BrowserPrivacy.safariURL(addressBarValue: "start page"))
        XCTAssertEqual(
            BrowserPrivacy.safariURL(addressBarValue: "apple.com")?.absoluteString,
            "http://apple.com"
        )
        XCTAssertEqual(
            BrowserPrivacy.safariURL(addressBarValue: "https://apple.com")?.absoluteString,
            "https://apple.com"
        )
    }

    func testSlackChannelDeepLinkUsesExactFilteredComponentsAndUppercaseC() {
        XCTAssertEqual(
            BrowserPrivacy.slackChannelURL(
                from: URL(string: "https://app.slack.com/client/T123/C456/thread")!
            )?.absoluteString,
            "slack://channel?team=T123&id=C456"
        )
        XCTAssertNil(BrowserPrivacy.slackChannelURL(
            from: URL(string: "https://app.slack.com/client/T123/c456")!
        ))
        XCTAssertNil(BrowserPrivacy.slackChannelURL(
            from: URL(string: "https://app.slack.com/client/T123")!
        ))
    }

    func testExcludeIncognitoDefaultProtectsEveryLocale() {
        XCTAssertTrue(CapturePrivacySettings.defaultExcludeIncognito(
            preferredLanguages: ["en-US", "fr-FR"]
        ))
        XCTAssertTrue(CapturePrivacySettings.defaultExcludeIncognito(
            preferredLanguages: ["en"]
        ))
        XCTAssertTrue(CapturePrivacySettings.defaultExcludeIncognito(
            preferredLanguages: ["fr-FR", "en-US"]
        ))
        XCTAssertTrue(CapturePrivacySettings.defaultExcludeIncognito(
            preferredLanguages: ["EN-US"]
        ))
        XCTAssertTrue(CapturePrivacySettings.defaultExcludeIncognito(
            preferredLanguages: []
        ))
    }
}
#endif
