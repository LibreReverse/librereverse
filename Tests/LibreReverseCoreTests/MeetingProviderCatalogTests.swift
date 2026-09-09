import XCTest
@testable import LibreReverseCore

final class MeetingProviderCatalogTests: XCTestCase {
    func testNativeCatalogRecognizesEveryAliasOnlyWithActiveCallEvidence() {
        for (name, provider) in MeetingProviderCatalog.nativeApplicationNames {
            func observation(_ labels: [String]) -> LibreReverseMeetingWindowObservation {
                .init(windowID: 1, processIdentifier: 2, bundleIdentifier: "app.catalog.fixture",
                      title: "Call", applicationName: name.uppercased(), accessibilityLabels: labels,
                      usesMicrophoneInput: true)
            }
            XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation([])), name)
            XCTAssertEqual(LibreReverseMeetingDetector.candidate(from: observation(["End call"]))?.provider, provider, name)
        }
        XCTAssertNil(MeetingProviderCatalog.nativeProvider(bundleIdentifier: "app.unknown", applicationName: "Signal Notes"))
        XCTAssertEqual(MeetingProviderCatalog.nativeProvider(bundleIdentifier: "com.apple.FaceTime", applicationName: nil), .faceTime)
    }

    func testBrowserCatalogRequiresCallControlsAndRejectsLookalikeHosts() throws {
        for rule in MeetingProviderCatalog.browserRules {
            let path = rule.pathComponent.isEmpty ? "room" : "\(rule.pathComponent)/room"
            let url = try XCTUnwrap(URL(string: "https://\(rule.host)/\(path)"))
            func observation(active: Bool?, labels: [String]) -> LibreReverseMeetingWindowObservation {
                .init(windowID: 1, processIdentifier: 2, bundleIdentifier: "com.google.Chrome",
                      title: "Meeting", url: url, accessibilityLabels: labels, browserCallIsActive: active)
            }
            XCTAssertEqual(LibreReverseMeetingDetector.browserProvider(for: url), rule.provider)
            XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation(active: nil, labels: [])))
            XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation(active: false, labels: ["Leave call"])))
            XCTAssertEqual(LibreReverseMeetingDetector.candidate(from: observation(active: true, labels: ["Leave call"]))?.provider, rule.provider)
            XCTAssertNil(MeetingProviderCatalog.browserProvider(for: URL(string: "https://\(rule.host).unrelated.test/\(path)")!))
        }
        for value in ["https://app.cal.com/event-types", "https://cal.com/person/booking", "https://dialpad.com/meetings-sales", "https://github.com/jitsi/jitsi-meet"] {
            XCTAssertNil(MeetingProviderCatalog.browserProvider(for: URL(string: value)!))
        }
        XCTAssertEqual(MeetingProviderCatalog.browserProvider(for: URL(string: "https://app.cal.com/video/room")!), .calVideo)
        XCTAssertEqual(LibreReverseMeetingDetector.browserProvider(for: URL(string: "https://zoom.us/wc/123/join")!), .zoomWeb)
    }

    func testAccessibilityIDsAreScopedToTheirProvider() {
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallIdentifier("hangup-button", provider: .microsoftTeamsV2))
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallIdentifier("Calling_Window_123", provider: .whatsApp))
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallIdentifier("callControl_end", provider: .webex))
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallIdentifier("Calling_Window_123", provider: .telegram))
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallIdentifier("hangup-button", provider: nil))
        XCTAssertTrue(MeetingProviderCatalog.hasProviderCallButtonLabel("End", provider: .faceTime, role: "AXButton"))
        XCTAssertFalse(MeetingProviderCatalog.hasProviderCallButtonLabel("End", provider: .faceTime, role: "AXStaticText"))
        XCTAssertFalse(MeetingProviderCatalog.hasProviderCallButtonLabel("Leave the space", provider: .webex, role: "AXMenuItem"))
        let call = LibreReverseMeetingWindowObservation(windowID: 1, processIdentifier: 2,
            bundleIdentifier: "app.whatsapp.fixture", title: "Call", applicationName: "WhatsApp",
            accessibilityLabels: [MeetingProviderCatalog.activeIdentifierMarker])
        XCTAssertEqual(LibreReverseMeetingDetector.candidate(from: call)?.provider, .whatsApp)
    }

    func testAmbiguousDisconnectNeedsIndependentCallEvidence() {
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallControl(["Disconnect"]))
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallControl(["Disconnect", "Disconnect"]))
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallControl(["Mute microphone"]))
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallControl(["Disconnect", "Unmute microphone"]))
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallControl(["Disconnect", "Voice Connected"]))
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallControl(["End call"]))
    }

    func testAccessibilityEvidenceRejectsChatTextAndSupportsMutedDiscord() {
        XCTAssertEqual(MeetingProviderCatalog.callEvidence(label: "End call", role: "AXStaticText", provider: .telegram), [])
        XCTAssertEqual(MeetingProviderCatalog.callEvidence(label: "Message says Voice Connected", role: "AXStaticText", provider: .discord), [])
        XCTAssertEqual(MeetingProviderCatalog.callEvidence(label: "Voice Connected", role: "AXButton", provider: .discord), [])
        let disconnect = MeetingProviderCatalog.callEvidence(label: "Disconnect", role: "AXButton", provider: .discord)
        let muted = MeetingProviderCatalog.callEvidence(label: "Unmute", role: "AXCheckBox", provider: .discord)
        XCTAssertTrue(MeetingProviderCatalog.hasActiveCallControl(disconnect + muted))
        XCTAssertFalse(MeetingProviderCatalog.hasActiveCallControl(muted))
    }

    func testNativeTeamsAcceptsCallControlsWithoutMicrophoneOrSpecialTitle() {
        for bundle in ["com.microsoft.teams", "com.microsoft.teams2", "us.zoom.xos"] {
            let observation = LibreReverseMeetingWindowObservation(windowID: 1, processIdentifier: 2,
                bundleIdentifier: bundle, title: "Project discussion", accessibilityLabels: ["End call"], usesMicrophoneInput: false)
            XCTAssertNotNil(LibreReverseMeetingDetector.candidate(from: observation), bundle)
            let inventory = [LibreReverseMeetingWindowInventoryItem(observation: observation, ownerName: "Meeting")]
            XCTAssertEqual(LibreReverseMeetingDetector.mergingHiddenNativeObservations(visible: [], inventory: inventory,
                ownBundleIdentifier: nil, omittedBundleIdentifiers: [], omittedOwnerNames: []), [observation], bundle)
        }
    }

    func testBrowserLobbiesDoNotStartCallsEvenWithMicrophoneInput() {
        for address in ["https://meet.google.com/abc-defg-hij", "https://zoom.us/wc/123/join",
                        "https://teams.microsoft.com/l/meetup-join/123", "https://meet.jit.si/Room"] {
            let url = URL(string: address)!
            let idle = LibreReverseMeetingDetector.browserCallActivity(url: url, accessibilityLabels: ["Mute microphone"])
            XCTAssertEqual(idle, false, address)
            let observation = LibreReverseMeetingWindowObservation(windowID: 1, processIdentifier: 2,
                bundleIdentifier: "com.google.Chrome", title: "Meeting", url: url,
                accessibilityLabels: ["Mute microphone"], usesMicrophoneInput: true, browserCallIsActive: idle)
            XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation), address)
            XCTAssertEqual(LibreReverseMeetingDetector.browserCallActivity(url: url, accessibilityLabels: ["End call"]), true)
        }
        XCTAssertNil(LibreReverseMeetingDetector.browserCallActivity(url: nil, accessibilityLabels: []))
        XCTAssertNil(LibreReverseMeetingDetector.browserCallActivity(url: URL(string: "https://example.com"), accessibilityLabels: ["End call"]))
    }

    func testHiddenNewProviderRetainsPrivacyFiltering() {
        let observation = LibreReverseMeetingWindowObservation(windowID: 1, processIdentifier: 2,
            bundleIdentifier: "app.tuple.fixture", title: "Call", applicationName: "Tuple",
            accessibilityLabels: ["End call"])
        let inventory = [LibreReverseMeetingWindowInventoryItem(observation: observation, ownerName: "Tuple")]
        XCTAssertEqual(LibreReverseMeetingDetector.mergingHiddenNativeObservations(visible: [], inventory: inventory,
            ownBundleIdentifier: nil, omittedBundleIdentifiers: [], omittedOwnerNames: []), [observation])
        XCTAssertTrue(LibreReverseMeetingDetector.mergingHiddenNativeObservations(visible: [], inventory: inventory,
            ownBundleIdentifier: nil, omittedBundleIdentifiers: ["app.tuple.fixture"], omittedOwnerNames: []).isEmpty)
    }

    func testNewRoomIdentitiesRemainDistinctAndProviderPersistenceRoundTrips() {
        let a = URL(string: "https://meet.jit.si/RoomA")!
        let b = URL(string: "https://meet.jit.si/RoomB")!
        XCTAssertNotNil(LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(a))
        XCTAssertNotEqual(LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(a), LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(b))
        for provider in Set(MeetingProviderCatalog.nativeApplicationNames.values).union(MeetingProviderCatalog.browserRules.map(\.provider)) {
            XCTAssertNotNil(LibreReverseMeetingProvider(persistedValue: provider.legacyPersistenceValue))
        }
    }
}
