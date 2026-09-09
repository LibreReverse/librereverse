#if os(macOS)
import XCTest
import CoreGraphics
import LibreReverseCore
@testable import LibreReverseApp
final class MeetingWindowTitleTests: XCTestCase {
    @MainActor func testMeetControlsUseTheSameWindowAsPrivacyAndURL() throws {
        let bounds = CGRect(x: 20, y: 30, width: 1000, height: 700)
        let title = "Meet - abc-defg-hij"
        let joined = BrowserAXWindowIdentity(
            title: title + " - Microphone recording - Google Chrome - Work", bounds: bounds)
        let lobby = BrowserAXWindowIdentity(title: "Meet - xyz-abcd-efg - Google Chrome", bounds: bounds)
        for identities in [[lobby, joined], [joined, lobby]] {
            let selected = try XCTUnwrap(LibreReverseForegroundContextProvider.meetingWindowIndex(
                windowTitle: title + " 🔊", windowBounds: bounds, identities: identities, isBrowser: true))
            XCTAssertEqual(identities[selected], joined)
            // The old geometry-first resolver read the lobby's empty controls,
            // turning a privacy-approved joined room into an inactive candidate.
            let labels = identities[selected] == joined ? ["Leave call"] : []
            let url = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
            let observation = LibreReverseMeetingWindowObservation(
                windowID: 12, processIdentifier: 42, bundleIdentifier: "com.google.Chrome",
                title: title, url: url, accessibilityLabels: labels, usesMicrophoneInput: false,
                browserCallIsActive: LibreReverseMeetingDetector.browserCallActivity(url: url, accessibilityLabels: labels))
            XCTAssertEqual(LibreReverseMeetingDetector.candidate(from: observation)?.provider, .googleMeet)
        }
    }

    @MainActor func testMissingOrAmbiguousMeetWindowCannotBorrowSiblingCallControls() {
        let bounds = CGRect(x: 20, y: 30, width: 1000, height: 700)
        let title = "Meet - abc-defg-hij"
        let privateSibling = BrowserAXWindowIdentity(
            title: "Private room - Google Chrome (Incognito)", bounds: bounds)
        XCTAssertNil(LibreReverseForegroundContextProvider.meetingWindowIndex(
            windowTitle: title, windowBounds: bounds, identities: [privateSibling], isBrowser: true))
        let joined = BrowserAXWindowIdentity(title: title + " - Google Chrome", bounds: bounds)
        let privateCopy = BrowserAXWindowIdentity(title: title + " - Google Chrome (Incognito)", bounds: bounds)
        XCTAssertNil(LibreReverseForegroundContextProvider.meetingWindowIndex(
            windowTitle: title, windowBounds: bounds, identities: [joined, privateCopy], isBrowser: true))
        XCTAssertNil(LibreReverseForegroundContextProvider.meetingWindowIndex(
            windowTitle: "", windowBounds: bounds, identities: [joined], isBrowser: true))
        XCTAssertNil(LibreReverseForegroundContextProvider.meetingWindowIndex(
            windowTitle: title, windowBounds: bounds.offsetBy(dx: 80, dy: 0), identities: [joined], isBrowser: true))
    }

    @MainActor func testNativeMeetingWindowFallbackRemainsAvailable() {
        let identities = [BrowserAXWindowIdentity(title: "Native call", bounds: nil)]
        XCTAssertEqual(LibreReverseForegroundContextProvider.meetingWindowIndex(
            windowTitle: "WindowServer title", windowBounds: nil, identities: identities, isBrowser: false), 0)
    }

    @MainActor func testChromeCaptureIndicatorsDoNotHideJoinedCall() {
        let title = "Meet - wvf-bygz-xet"
        XCTAssertTrue(LibreReverseForegroundContextProvider.meetingWindowTitleMatches(
            title + " - Microphone recording - Google Chrome - Matthias", windowTitle: title, isBrowser: true))
        XCTAssertTrue(LibreReverseForegroundContextProvider.meetingWindowTitleMatches(title, windowTitle: title, isBrowser: true))
        XCTAssertFalse(LibreReverseForegroundContextProvider.meetingWindowTitleMatches(title, windowTitle: "", isBrowser: true))
        XCTAssertFalse(LibreReverseForegroundContextProvider.meetingWindowTitleMatches(title, windowTitle: "Meet - other-room", isBrowser: true))
        XCTAssertFalse(LibreReverseForegroundContextProvider.meetingWindowTitleMatches(title + " - extra", windowTitle: title, isBrowser: false))
    }
}
#endif
