import Foundation

/// Public application names and URL identifiers for supported meeting providers.
/// This catalog identifies possible providers; active-call controls are a separate gate.
public enum MeetingProviderCatalog {
    public static let nativeApplicationNames: [String: LibreReverseMeetingProvider] = [
        "zoom.us": .zoom,
        "zoom": .zoom,
        "microsoft teams": .microsoftTeams,
        "teams": .microsoftTeams,
        "msteams": .microsoftTeams,
        "slack": .slackHuddle,
        "facetime": .faceTime,
        "discord": .discord,
        "signal": .signal,
        "whatsapp": .whatsApp,
        "telegram": .telegram,
        "skype": .skype,
        "skype for business": .skypeForBusiness,
        "around": .around,
        "whereby": .whereby,
        "tuple": .tuple,
        "pop": .pop,
        "tandem": .tandem,
        "riverside": .riverside,
        "gather": .gather,
        "butter": .butter,
        "ringcentral": .ringCentral,
        "ringcentral meetings": .ringCentral,
        "bluejeans": .blueJeans,
        "gotomeeting": .goToMeeting,
        "goto meeting": .goToMeeting,
        "dialpad": .dialpad,
        "lifesize": .lifesize,
        "vonage": .vonage,
        "8x8 meet": .eightByEight,
        "8x8 work": .eightByEight,
        "jitsi meet": .jitsi,
        "chime": .chime,
        "amazon chime": .chime,
        "google meet": .googleMeet,
        "cal.com": .calVideo,
        "daily.co": .daily,
        "webex": .webex,
        "cisco webex meetings": .webex,
    ]

    public static func nativeProvider(bundleIdentifier: String, applicationName: String?) -> LibreReverseMeetingProvider? {
        switch bundleIdentifier.lowercased() {
        case "us.zoom.xos": return .zoom
        case "com.microsoft.teams": return .microsoftTeams
        case "com.microsoft.teams2": return .microsoftTeamsV2
        case "com.tinyspeck.slackmacgap": return .slackHuddle
        case "com.webex.meetingmanager": return .webex
        case "com.apple.facetime": return .faceTime
        default: break
        }
        guard let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return nativeApplicationNames[name]
    }

    public struct BrowserRule: Sendable {
        public let host: String
        public let pathComponent: String
        public let provider: LibreReverseMeetingProvider
    }

    public static let browserRules: [BrowserRule] = [
        .init(host: "webex.com", pathComponent: "", provider: .webex),
        .init(host: "discord.com", pathComponent: "", provider: .discord),
        .init(host: "discordapp.com", pathComponent: "", provider: .discord),
        .init(host: "web.whatsapp.com", pathComponent: "", provider: .whatsApp),
        .init(host: "web.telegram.org", pathComponent: "", provider: .telegram),
        .init(host: "meet.jit.si", pathComponent: "", provider: .jitsi),
        .init(host: "riverside.fm", pathComponent: "", provider: .riverside),
        .init(host: "gather.town", pathComponent: "", provider: .gather),
        .init(host: "butter.us", pathComponent: "", provider: .butter),
        .init(host: "livestorm.co", pathComponent: "", provider: .livestorm),
        .init(host: "ping.gg", pathComponent: "", provider: .ping),
        .init(host: "cal.com", pathComponent: "video", provider: .calVideo),
        .init(host: "daily.co", pathComponent: "", provider: .daily),
        .init(host: "pop.com", pathComponent: "", provider: .pop),
        .init(host: "tuple.app", pathComponent: "", provider: .tuple),
        .init(host: "tandem.chat", pathComponent: "", provider: .tandem),
        .init(host: "meet.ringcentral.com", pathComponent: "", provider: .ringCentral),
        .init(host: "bluejeans.com", pathComponent: "", provider: .blueJeans),
        .init(host: "gotomeeting.com", pathComponent: "", provider: .goToMeeting),
        .init(host: "app.chime.aws", pathComponent: "", provider: .chime),
        .init(host: "dialpad.com", pathComponent: "meetings", provider: .dialpad),
        .init(host: "8x8.vc", pathComponent: "", provider: .eightByEight),
    ]

    public static func browserProvider(for url: URL) -> LibreReverseMeetingProvider? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let firstPath = url.path.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        return browserRules.first { rule in
            (host == rule.host || host.hasSuffix("." + rule.host))
                && (rule.pathComponent.isEmpty || firstPath == rule.pathComponent)
        }?.provider
    }

    public static let activeIdentifierMarker = "Active meeting control"

    /// Exact control ID for Teams; provider-scoped ID fragments for other apps.
    public static func hasActiveCallIdentifier(_ identifier: String, provider: LibreReverseMeetingProvider?) -> Bool {
        let identifier = identifier.lowercased()
        switch provider {
        case .microsoftTeams, .microsoftTeamsV2, .microsoftTeamsWeb:
            return identifier == "hangup-button"
        case .zoom, .zoomWeb:
            return identifier.contains("leave")
        case .webex:
            return identifier.contains("callcontrol")
        case .whatsApp:
            return identifier.contains("calling_window")
        default: return false
        }
    }

    public static func hasProviderCallButtonLabel(_ label: String, provider: LibreReverseMeetingProvider?, role: String?) -> Bool {
        guard role == "AXButton" else { return false }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .faceTime: return label == "end" || label == "leave"
        case .webex: return label == "leave"
        default: return false
        }
    }

    public static let activeCallMarkers = [
        "Leave call", "Leave meeting", "Leave Huddle", "Hang up", "Hangup", "End call", "End meeting", "Disconnect"
    ]
    public static let endedCallMarkers = ["Rejoin"]
    public static let supportingCallMarkers = ["Voice Connected", "Mute microphone", "Unmute microphone", "Mute mic", "Unmute mic", "Deafen", "Undeafen"]

    /// Reduce Accessibility text to known evidence before it leaves the reader.
    /// Control roles exclude chat messages; supporting controls never start a call alone.
    public static func callEvidence(label: String, role: String?, provider: LibreReverseMeetingProvider?) -> [String] {
        let controls: Set<String> = ["AXButton", "AXMenuItem", "AXCheckBox", "AXSwitch"]
        let isControl = controls.contains(role ?? "")
        var result: [String] = []
        if provider == .googleMeet, role == "AXButton",
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rejoin" {
            result.append("Rejoin")
        }
        if isControl {
            result += activeCallMarkers.filter { label.localizedCaseInsensitiveContains($0) }
            result += supportingCallMarkers.filter { $0 != "Voice Connected" && label.localizedCaseInsensitiveContains($0) }
            if provider == .discord,
                ["mute", "unmute"].contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                result.append("Mute microphone")
            }
        }
        if provider == .discord, ["AXStaticText", "AXStatus"].contains(role ?? ""),
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "voice connected" {
            result.append("Voice Connected")
        }
        if hasProviderCallButtonLabel(label, provider: provider, role: role) {
            result.append(activeIdentifierMarker)
        }
        return result
    }

    public static func hasActiveCallControl(_ labels: [String]) -> Bool {
        if labels.contains(activeIdentifierMarker) { return true }
        let matched = Set(labels.map { $0.lowercased() })
        // Explicit call-ending actions are sufficient even while the microphone is muted.
        if activeCallMarkers.filter({ $0 != "Disconnect" }).contains(where: { matched.contains($0.lowercased()) }) { return true }
        // Disconnect is also used for devices and accounts. Require independent call context.
        return matched.contains("disconnect") && supportingCallMarkers.contains { matched.contains($0.lowercased()) }
    }
}
