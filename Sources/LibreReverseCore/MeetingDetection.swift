import Foundation

public enum LibreReverseMeetingProvider: String, Codable, CaseIterable, Sendable {
    case zoom
    case microsoftTeams
    case microsoftTeamsV2
    case slackHuddle
    case webex
    case googleMeet
    case localTest
    case microsoftTeamsWeb
    case zoomWeb
    case manual
    case calendar
    case faceTime
    case discord
    case signal
    case whatsApp
    case telegram
    case skype
    case skypeForBusiness
    case around
    case whereby
    case tuple
    case pop
    case tandem
    case riverside
    case gather
    case butter
    case ringCentral
    case blueJeans
    case goToMeeting
    case dialpad
    case lifesize
    case vonage
    case eightByEight
    case jitsi
    case chime
    case calVideo
    case daily
    case livestorm
    case ping

    public var displayName: String {
        switch self {
        case .zoom, .zoomWeb: "Zoom"
        case .microsoftTeams, .microsoftTeamsV2, .microsoftTeamsWeb: "Microsoft Teams"
        case .slackHuddle: "Slack Huddle"
        case .webex: "Webex"
        case .googleMeet: "Google Meet"
        case .localTest: "LibreReverse Test Meeting"
        case .manual: "Ad hoc"
        case .calendar: "Calendar"
        case .faceTime: "FaceTime"
        case .discord: "Discord"
        case .signal: "Signal"
        case .whatsApp: "WhatsApp"
        case .telegram: "Telegram"
        case .skype: "Skype"
        case .skypeForBusiness: "Skype for Business"
        case .around: "Around"
        case .whereby: "Whereby"
        case .tuple: "Tuple"
        case .pop: "Pop"
        case .tandem: "Tandem"
        case .riverside: "Riverside"
        case .gather: "Gather"
        case .butter: "Butter"
        case .ringCentral: "RingCentral"
        case .blueJeans: "BlueJeans"
        case .goToMeeting: "GoTo Meeting"
        case .dialpad: "Dialpad"
        case .lifesize: "Lifesize"
        case .vonage: "Vonage"
        case .eightByEight: "8x8"
        case .jitsi: "Jitsi Meet"
        case .chime: "Amazon Chime"
        case .calVideo: "Cal Video"
        case .daily: "Daily"
        case .livestorm: "Livestorm"
        case .ping: "Ping"
        }
    }

    /// Value stored in the meeting event details graph. Stored provider names
    /// distinguish native and browser cases with different capture lifecycles.
    public var legacyPersistenceValue: String {
        switch self {
        case .zoom, .zoomWeb: "zoom"
        case .microsoftTeams: "teams"
        case .microsoftTeamsV2: "teams2"
        case .slackHuddle: "slack"
        case .webex: "webex"
        case .googleMeet: "googleMeet"
        case .localTest: "localTest"
        case .microsoftTeamsWeb: "microsoftTeams"
        case .manual: "manual"
        case .calendar: "calendar"
        default: rawValue
        }
    }

    /// Decodes persisted provider names and the corresponding enum raw values.
    public init?(persistedValue: String) {
        switch persistedValue {
        case "zoom": self = .zoom
        case "teams": self = .microsoftTeams
        case "teams2": self = .microsoftTeamsV2
        case "slack": self = .slackHuddle
        case "webex": self = .webex
        case "googleMeet": self = .googleMeet
        case "microsoftTeams": self = .microsoftTeamsWeb
        case "manual": self = .manual
        case "calendar": self = .calendar
        default:
            guard let current = Self(rawValue: persistedValue) else { return nil }
            self = current
        }
    }
}

public enum LibreReverseMeetingCandidateSource: String, Codable, Sendable {
    case windowDetection
    case manual
    case calendar
}

/// One window observation at the meeting-detector boundary. The browser
/// accessibility provider supplies URLs and provider-specific probes supply
/// labels. Keeping the rule engine independent from AppKit makes tests
/// deterministic.
public struct LibreReverseMeetingWindowObservation: Equatable, Sendable {
    public let windowID: UInt32
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let title: String
    public let applicationName: String?
    public let url: URL?
    public let accessibilityLabels: [String]
    public let usesMicrophoneInput: Bool
    public let browserCallIsActive: Bool?

    public init(
        windowID: UInt32,
        processIdentifier: Int32,
        bundleIdentifier: String,
        title: String,
        applicationName: String? = nil,
        url: URL? = nil,
        accessibilityLabels: [String] = [],
        usesMicrophoneInput: Bool = false,
        browserCallIsActive: Bool? = nil
    ) {
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.applicationName = applicationName
        self.url = url
        self.accessibilityLabels = accessibilityLabels
        self.usesMicrophoneInput = usesMicrophoneInput
        self.browserCallIsActive = browserCallIsActive
    }
}

/// One raw WindowServer entry used only to supplement the ordinary visible-
/// window detector. Native meeting windows can remain alive while minimized or
/// completely covered; they must not disappear merely because the screenshot
/// selector correctly omits windows that contribute no pixels.
public struct LibreReverseMeetingWindowInventoryItem: Equatable, Sendable {
    public let observation: LibreReverseMeetingWindowObservation
    public let ownerName: String

    public init(
        observation: LibreReverseMeetingWindowObservation,
        ownerName: String
    ) {
        self.observation = observation
        self.ownerName = ownerName
    }
}

public struct LibreReverseMeetingCandidate: Codable, Equatable, Sendable {
    public let provider: LibreReverseMeetingProvider
    public let source: LibreReverseMeetingCandidateSource
    public let windowID: UInt32?
    public let processIdentifier: Int32?
    public let bundleIdentifier: String?
    public let title: String?
    public let url: URL?
    public let calendarEventID: String?
    public let calendarID: String?
    public let calendarSeriesID: String?
    public let calendarTitle: String?
    public let calendarParticipants: [String]?

    public init(
        provider: LibreReverseMeetingProvider,
        source: LibreReverseMeetingCandidateSource,
        windowID: UInt32? = nil,
        processIdentifier: Int32? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        url: URL? = nil,
        calendarEventID: String? = nil,
        calendarID: String? = nil,
        calendarSeriesID: String? = nil,
        calendarTitle: String? = nil,
        calendarParticipants: [String] = []
    ) {
        self.provider = provider
        self.source = source
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.url = url
        self.calendarEventID = calendarEventID
        self.calendarID = calendarID
        self.calendarSeriesID = calendarSeriesID
        self.calendarTitle = calendarTitle
        self.calendarParticipants = calendarParticipants
    }

    /// Stable across title changes and non-room URL changes while the same
    /// provider process/window is alive. Process ownership prevents a recycled
    /// WindowServer ID from inheriting state after the provider restarts.
    /// Browser candidates additionally bind the window to its canonical meeting
    /// room so a reused tab cannot inherit the prior room's consent, lifecycle,
    /// or crash continuation.
    /// Calendar and manual candidates use their durable source identity.
    public var identity: String {
        if let windowID {
            let windowIdentity =
                if let processIdentifier {
                    "window:\(provider.rawValue):\(processIdentifier):\(windowID)"
                } else {
                    // Pre-process-identity journals remain readable. They fail
                    // closed against production observations, which always carry
                    // their owning process identifier.
                    "window:\(provider.rawValue):legacy:\(windowID)"
                }
            guard isBrowserMeeting,
                let url,
                let roomIdentity = LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(url)
            else { return windowIdentity }
            return "\(windowIdentity):room:\(roomIdentity)"
        }
        if let calendarEventID { return "calendar:\(calendarEventID)" }
        return "source:\(source.rawValue):\(provider.rawValue)"
    }

    public var isBrowserMeeting: Bool {
        bundleIdentifier.map(
            LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains
        ) ?? false
    }

    /// Returns the same durable candidate identity and evidence with only its
    /// user-visible title replaced. Empty edits intentionally clear a detected
    /// window title so presentation can fall back to “Meeting recording.”
    public func updatingTitle(_ title: String?) -> Self {
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            provider: provider,
            source: source,
            windowID: windowID,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            title: normalized.flatMap { $0.isEmpty ? nil : $0 },
            url: url,
            calendarEventID: calendarEventID,
            calendarID: calendarID,
            calendarSeriesID: calendarSeriesID,
            calendarTitle: calendarTitle,
            calendarParticipants: calendarParticipants ?? []
        )
    }
}

/// Resolves detector multiplicity without depending on WindowServer ordering.
/// Multiple surfaces are one logical meeting only when they share an exact
/// canonical browser room or the same native provider process. Different rooms,
/// providers, and native processes remain ambiguous and cannot start capture.
public enum LibreReverseMeetingCandidateArbitration {
    public static func selectUnambiguous(
        _ candidates: [LibreReverseMeetingCandidate]
    ) -> LibreReverseMeetingCandidate? {
        guard let first = candidates.first else { return nil }
        let key = logicalMeetingKey(first)
        guard candidates.allSatisfy({ logicalMeetingKey($0) == key }) else {
            return nil
        }
        return candidates.min(by: representativePrecedes)
    }

    public static func areSameLogicalMeeting(
        _ lhs: LibreReverseMeetingCandidate,
        _ rhs: LibreReverseMeetingCandidate
    ) -> Bool {
        logicalMeetingKey(lhs) == logicalMeetingKey(rhs)
    }

    /// Module-internal so the redacted diagnostic can derive a per-run opaque
    /// equality token from the exact production arbitration key. The raw key
    /// must never be serialized by that diagnostic because it can contain a
    /// browser room identity or process identifier.
    static func logicalMeetingKey(_ candidate: LibreReverseMeetingCandidate) -> String {
        if candidate.isBrowserMeeting,
            let url = candidate.url,
            let room = LibreReverseMeetingCalendarCorrelation.meetingURLIdentity(url)
        {
            return "browser-room:\(room)"
        }
        if candidate.source == .windowDetection,
            !candidate.isBrowserMeeting,
            let processIdentifier = candidate.processIdentifier
        {
            return "native-process:\(candidate.provider.rawValue):\(processIdentifier)"
        }
        return "exact:\(candidate.identity)"
    }

    private static func representativePrecedes(
        _ lhs: LibreReverseMeetingCandidate,
        _ rhs: LibreReverseMeetingCandidate
    ) -> Bool {
        let lhsWindow = lhs.windowID ?? UInt32.max
        let rhsWindow = rhs.windowID ?? UInt32.max
        if lhsWindow != rhsWindow { return lhsWindow < rhsWindow }
        let lhsProcess = lhs.processIdentifier ?? Int32.max
        let rhsProcess = rhs.processIdentifier ?? Int32.max
        if lhsProcess != rhsProcess { return lhsProcess < rhsProcess }
        let lhsBundle = lhs.bundleIdentifier ?? ""
        let rhsBundle = rhs.bundleIdentifier ?? ""
        if lhsBundle != rhsBundle { return lhsBundle < rhsBundle }
        return lhs.identity < rhs.identity
    }
}

/// Recognizes supported meeting apps and web rooms. Ordinary browser media
/// never qualifies from a title alone; youtube.com is a hard negative.
public enum LibreReverseMeetingDetector {
    public static let supportedNativeBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.webex.meetingmanager",
        "com.apple.FaceTime",
    ]

    public static let supportedBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.dev",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]
    public static let browserPopOutBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.dev",
        "com.google.Chrome.beta",
        "company.thebrowser.Browser",
    ]

    /// Current macOS Zoom builds can move their only live-call affordances to
    /// the application menu bar when the call window is unfocused/minimized.
    /// Keep this allowlist narrow: scanning arbitrary app menus would expand
    /// the detector's accessibility and false-positive surface.
    public static let menuBarScanBundleIdentifiers: Set<String> = ["us.zoom.xos"]

    public static let zoomActiveCallMarkers = [
        "Zoom Meeting",
        "Leave Meeting",
        "End Meeting",
        "Stop Share",
        "Pause Share",
        "You are screen sharing",
    ]
    public static let teamsActiveCallMarkers = ["Microsoft Teams Call in progress"]
    public static let slackActiveCallMarkers = ["Leave Huddle"]
    public static let canonicalAccessibilityMarkers =
        teamsActiveCallMarkers + zoomActiveCallMarkers + slackActiveCallMarkers
        + MeetingProviderCatalog.activeCallMarkers + MeetingProviderCatalog.supportingCallMarkers + MeetingProviderCatalog.endedCallMarkers + [MeetingProviderCatalog.activeIdentifierMarker]

    private static let teamsMainWindowExpression = try! NSRegularExpression(
        pattern:
            #"^(((Chat|Teams and Channels)( \| .+)?)|(Activity|Calendar|Files|Admin|Communities)) \| Microsoft Teams( classic)?$"#,
        options: [.caseInsensitive]
    )
    private static let meetCodeExpression = try! NSRegularExpression(
        pattern: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}(?:/|$)"#,
        options: [.caseInsensitive]
    )
    private static let googleMeetPopOutTitleExpression = try! NSRegularExpression(
        pattern:
            #"^(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|(?:Google )?Meet\s*[-–—|·]\s*[a-z]{3}-[a-z]{4}-[a-z]{3}|[a-z]{3}-[a-z]{4}-[a-z]{3}\s*[-–—|·]\s*(?:Google )?Meet)$"#,
        options: [.caseInsensitive]
    )
    private static let googleMeetCodeInTitleExpression = try! NSRegularExpression(
        pattern: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#,
        options: [.caseInsensitive]
    )

    /// An observed meeting URL identifies the provider, not whether the user joined.
    /// Nil means this window has no recognized URL; false means a recognized lobby/idle page.
    public static func browserCallActivity(url: URL?, accessibilityLabels: [String]) -> Bool? {
        guard let url, browserProvider(for: url) != nil else { return nil }
        return MeetingProviderCatalog.hasActiveCallControl(accessibilityLabels)
    }

    public static func candidate(
        from observation: LibreReverseMeetingWindowObservation
    ) -> LibreReverseMeetingCandidate? {
        if supportedBrowserBundleIdentifiers.contains(observation.bundleIdentifier) {
            guard observation.browserCallIsActive != false else { return nil }
            let provider: LibreReverseMeetingProvider
            let candidateURL: URL
            if let url = observation.url {
                // An ordinary, non-meeting URL is authoritative even if its
                // browser process happens to be using the microphone.
                guard let urlProvider = browserProvider(for: url) else { return nil }
                if MeetingProviderCatalog.browserProvider(for: url) != nil {
                    guard observation.browserCallIsActive == true,
                        MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels) else { return nil }
                }
                provider = urlProvider
                candidateURL = url
            } else {
                // Chrome/Arc meeting pop-outs can have no address-bar URL. A
                // strict Meet title is only a candidate when that exact browser
                // process is actively consuming microphone input.
                guard browserPopOutBundleIdentifiers.contains(observation.bundleIdentifier),
                    observation.usesMicrophoneInput,
                    let popOutURL = canonicalGoogleMeetPopOutURL(observation.title)
                else { return nil }
                provider = .googleMeet
                candidateURL = popOutURL
            }
            return makeCandidate(provider, observation, candidateURL: candidateURL)
        }

        switch observation.bundleIdentifier {
        case "us.zoom.xos":
            // A bare "Meeting" label is part of Zoom's idle Workplace chrome
            // and cannot distinguish a live call. Accept the dedicated meeting
            // window or controls that exist only while a call/share is active.
            guard
                containsAny(
                    [observation.title] + observation.accessibilityLabels,
                    needles: zoomActiveCallMarkers + [MeetingProviderCatalog.activeIdentifierMarker]
                )
                || MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels)
            else { return nil }
            return makeCandidate(.zoom, observation)
        case "com.microsoft.teams":
            return teamsCandidate(.microsoftTeams, observation)
        case "com.microsoft.teams2":
            return teamsCandidate(.microsoftTeamsV2, observation)
        case "com.tinyspeck.slackmacgap":
            let normalizedTitle = observation.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                normalizedTitle.compare(
                    "Huddle",
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
                    || containsAny(
                        observation.accessibilityLabels,
                        needles: slackActiveCallMarkers
                    )
            else { return nil }
            return makeCandidate(.slackHuddle, observation)
        case "com.webex.meetingmanager":
            // This bundle is Webex's separate meeting-manager process,
            // not its ordinary launcher or messaging window.
            return makeCandidate(.webex, observation)
        default:
            guard let provider = MeetingProviderCatalog.nativeProvider(
                bundleIdentifier: observation.bundleIdentifier, applicationName: observation.applicationName),
                MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels) else { return nil }
            return makeCandidate(provider, observation)
        }
    }

    public static func supportsNativeApplication(bundleIdentifier: String, applicationName: String?) -> Bool {
        supportedNativeBundleIdentifiers.contains(bundleIdentifier)
            || MeetingProviderCatalog.nativeProvider(bundleIdentifier: bundleIdentifier, applicationName: applicationName) != nil
    }

    private static func canonicalGoogleMeetPopOutURL(_ title: String) -> URL? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard
            googleMeetPopOutTitleExpression.firstMatch(
                in: normalized,
                options: [],
                range: range
            ) != nil,
            let codeMatch = googleMeetCodeInTitleExpression.firstMatch(
                in: normalized,
                options: [],
                range: range
            ),
            let codeRange = Range(codeMatch.range, in: normalized)
        else { return nil }
        return URL(
            string: "https://meet.google.com/\(normalized[codeRange].lowercased())"
        )
    }

    public static func explicitlyEndedCandidates(
        from observations: [LibreReverseMeetingWindowObservation]
    ) -> [LibreReverseMeetingCandidate] {
        observations.compactMap { observation in
            guard let url = observation.url, browserProvider(for: url) == .googleMeet,
                observation.accessibilityLabels.contains("Rejoin"),
                !MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels)
            else { return nil }
            return makeCandidate(.googleMeet, observation)
        }
    }

    public static func candidates(
        from observations: [LibreReverseMeetingWindowObservation]
    ) -> [LibreReverseMeetingCandidate] {
        var seen = Set<String>()
        return observations.compactMap(candidate).filter { seen.insert($0.identity).inserted }
    }

    /// Adds privacy-eligible native meeting windows that were absent from the
    /// visible capture selection. Browser windows deliberately do not enter
    /// through this path: their meeting identity requires a privacy-checked URL
    /// from the existing browser AX producer. A hidden native window must also
    /// carry provider-specific live-call evidence; stale Zoom/Slack titles are
    /// not enough. Visible observations win and the WindowServer ID keeps a
    /// candidate stable across minimize/restore.
    public static func mergingHiddenNativeObservations(
        visible: [LibreReverseMeetingWindowObservation],
        inventory: [LibreReverseMeetingWindowInventoryItem],
        ownBundleIdentifier: String?,
        omittedBundleIdentifiers: Set<String>,
        omittedOwnerNames: Set<String>
    ) -> [LibreReverseMeetingWindowObservation] {
        var merged = visible
        var seenWindowIDs = Set(visible.map(\.windowID))
        for item in privacyEligibleHiddenNativeInventory(
            inventory,
            ownBundleIdentifier: ownBundleIdentifier,
            omittedBundleIdentifiers: omittedBundleIdentifiers,
            omittedOwnerNames: omittedOwnerNames
        ) {
            let observation = item.observation
            guard hiddenNativeCallIsActive(observation),
                seenWindowIDs.insert(observation.windowID).inserted
            else { continue }
            merged.append(observation)
        }
        return merged
    }

    /// Applies privacy and provider allowlists before product code inspects an
    /// off-screen window's Accessibility tree. This keeps an omitted app or
    /// owner entirely outside the hidden-window evidence boundary.
    public static func privacyEligibleHiddenNativeInventory(
        _ inventory: [LibreReverseMeetingWindowInventoryItem],
        ownBundleIdentifier: String?,
        omittedBundleIdentifiers: Set<String>,
        omittedOwnerNames: Set<String>
    ) -> [LibreReverseMeetingWindowInventoryItem] {
        inventory.filter { item in
            let bundleIdentifier = item.observation.bundleIdentifier
            return supportsNativeApplication(bundleIdentifier: bundleIdentifier,
                applicationName: item.observation.applicationName ?? item.ownerName)
                && bundleIdentifier != ownBundleIdentifier
                && !omittedBundleIdentifiers.contains(bundleIdentifier)
                && !omittedOwnerNames.contains(item.ownerName)
        }
    }

    private static func hiddenNativeCallIsActive(
        _ observation: LibreReverseMeetingWindowObservation
    ) -> Bool {
        let hasProviderEvidence: Bool
        switch observation.bundleIdentifier {
        case "us.zoom.xos":
            hasProviderEvidence = containsAny(
                observation.accessibilityLabels,
                needles: zoomActiveCallMarkers + [MeetingProviderCatalog.activeIdentifierMarker]
            )
        case "com.microsoft.teams", "com.microsoft.teams2":
            hasProviderEvidence = containsAny(
                observation.accessibilityLabels,
                needles: teamsActiveCallMarkers + [MeetingProviderCatalog.activeIdentifierMarker]
            )
        case "com.tinyspeck.slackmacgap":
            hasProviderEvidence = containsAny(
                observation.accessibilityLabels,
                needles: slackActiveCallMarkers
            )
        case "com.webex.meetingmanager":
            // Webex isolates live calls in this dedicated process.
            hasProviderEvidence = true
        default:
            hasProviderEvidence = MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels)
        }
        return (hasProviderEvidence || MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels))
            && candidate(from: observation) != nil
    }

    public static func browserProvider(for url: URL) -> LibreReverseMeetingProvider? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Deliberately narrow, user-controlled local meeting fixture. Ordinary
        // localhost pages and the fixture lobby never start recording.
        if url.scheme == "http", host == "127.0.0.1", url.port == 8768,
           path == "librereverse-meeting-test.html",
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
             .contains(where: { $0.name == "active" && $0.value == "1" }) == true {
            return .localTest
        }

        // Explicitly retain the validation/product boundary: YouTube proves A/V
        // fidelity, but never provides a production meeting signal.
        if host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be")
        {
            return nil
        }
        if host == "meet.google.com" {
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return meetCodeExpression.firstMatch(in: path, range: range) == nil
                ? nil : .googleMeet
        }
        if host == "teams.live.com" {
            let lower = url.absoluteString.lowercased()
            return lower.contains("/_#/pre-join-calling/")
                || lower.contains("/_#/modern-calling/")
                || path.lowercased().hasPrefix("meet")
                ? .microsoftTeamsWeb : nil
        }
        if host == "teams.microsoft.com" {
            return path.lowercased().hasPrefix("l/meetup-join")
                ? .microsoftTeamsWeb : nil
        }
        if host == "app.slack.com" {
            return path.lowercased().hasPrefix("huddle/")
                ? .slackHuddle : nil
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first?.lowercased(), first == "j" || first == "my" || first == "wc",
                components.count >= 2
            else { return nil }
            return .zoomWeb
        }
        return MeetingProviderCatalog.browserProvider(for: url)
    }

    private static func teamsCandidate(
        _ provider: LibreReverseMeetingProvider,
        _ observation: LibreReverseMeetingWindowObservation
    ) -> LibreReverseMeetingCandidate? {
        let titleRange = NSRange(
            observation.title.startIndex..<observation.title.endIndex,
            in: observation.title
        )
        guard
            teamsMainWindowExpression.firstMatch(
                in: observation.title,
                range: titleRange
            ) == nil
        else { return nil }
        let evidence = [observation.title] + observation.accessibilityLabels
        guard
            containsAny(evidence, needles: teamsActiveCallMarkers + [MeetingProviderCatalog.activeIdentifierMarker])
                || MeetingProviderCatalog.hasActiveCallControl(observation.accessibilityLabels)
                || observation.url.flatMap(browserProvider) == .microsoftTeamsWeb
        else { return nil }
        return makeCandidate(provider, observation)
    }

    private static func makeCandidate(
        _ provider: LibreReverseMeetingProvider,
        _ observation: LibreReverseMeetingWindowObservation,
        candidateURL: URL? = nil
    ) -> LibreReverseMeetingCandidate {
        LibreReverseMeetingCandidate(
            provider: provider,
            source: .windowDetection,
            windowID: observation.windowID,
            processIdentifier: observation.processIdentifier,
            bundleIdentifier: observation.bundleIdentifier,
            title: observation.title.isEmpty ? nil : observation.title,
            url: candidateURL ?? observation.url
        )
    }

    private static func containsAny(_ values: [String], needles: [String]) -> Bool {
        values.contains { value in
            needles.contains { value.localizedCaseInsensitiveContains($0) }
        }
    }
}

public enum LibreReverseMeetingStartPolicy: String, Codable, Sendable {
    case disabled
    case ask
    case automatic
}

public enum LibreReverseMeetingEndPolicy: String, Codable, Sendable {
    case manual
    case detected
    case calendarEvent
}

public struct LibreReverseMeetingLifecycleConfiguration: Equatable, Sendable {
    public let startPolicy: LibreReverseMeetingStartPolicy
    public let endPolicy: LibreReverseMeetingEndPolicy
    public let startObservationThreshold: Int
    public let endObservationThreshold: Int
    public let reentryObservationThreshold: Int
    public let promptDismissObservationThreshold: Int
    public let nativeEndGrace: TimeInterval
    public let browserEndGrace: TimeInterval

    public init(
        startPolicy: LibreReverseMeetingStartPolicy = .ask,
        endPolicy: LibreReverseMeetingEndPolicy = .detected,
        startObservationThreshold: Int = 2,
        endObservationThreshold: Int = 2,
        reentryObservationThreshold: Int = 2,
        promptDismissObservationThreshold: Int = 2,
        nativeEndGrace: TimeInterval = 30,
        browserEndGrace: TimeInterval = 300
    ) {
        self.startPolicy = startPolicy
        self.endPolicy = endPolicy
        self.startObservationThreshold = max(1, startObservationThreshold)
        self.endObservationThreshold = max(1, endObservationThreshold)
        self.reentryObservationThreshold = max(1, reentryObservationThreshold)
        self.promptDismissObservationThreshold = max(1, promptDismissObservationThreshold)
        self.nativeEndGrace = max(0, nativeEndGrace)
        self.browserEndGrace = max(0, browserEndGrace)
    }
}

/// Settings may persist a new detection policy at any time, but the reducer can
/// be rebuilt only when no capture boundary owns its state. A pending restart
/// is logically still the same active meeting even though its prior capture
/// session has already closed.
public enum LibreReverseMeetingPolicyTransition {
    public static func canResetLifecycle(
        hasActiveSession: Bool,
        hasOperationInFlight: Bool,
        hasPendingRestart: Bool
    ) -> Bool {
        !hasActiveSession && !hasOperationInFlight && !hasPendingRestart
    }
}

public enum LibreReverseMeetingStartAdmission {
    public static func canBegin(
        terminating: Bool,
        hasActiveSession: Bool,
        hasOperationInFlight: Bool,
        systemCaptureSuspended: Bool,
        captureRecoveryInProgress: Bool = false
    ) -> Bool {
        !terminating && !hasActiveSession && !hasOperationInFlight
            && !systemCaptureSuspended && !captureRecoveryInProgress
    }
}

/// Serializes privacy-sensitive system-session boundaries with asynchronous
/// meeting startup. A lock/fast-user-switch can arrive while ScreenCaptureKit
/// is still starting; retaining the stop reason until that operation releases
/// ownership prevents the newly started session from escaping finalization.
public enum LibreReverseMeetingSystemBoundary: Equatable, Sendable {
    case sleep
    case sessionInactive

    fileprivate var stopReason: LibreReverseMeetingStopReason {
        switch self {
        case .sleep: .systemSleep
        case .sessionInactive: .systemSessionInactive
        }
    }
}

public struct LibreReverseMeetingSystemBoundaryTracker: Equatable, Sendable {
    private var systemIsSleeping = false
    private var sessionIsInactive = false
    public private(set) var pendingStopReason: LibreReverseMeetingStopReason?

    public var captureIsSuspended: Bool {
        systemIsSleeping || sessionIsInactive
    }

    public init() {}

    public mutating func suspend(
        _ boundary: LibreReverseMeetingSystemBoundary,
        ownsCaptureBoundary: Bool
    ) {
        switch boundary {
        case .sleep: systemIsSleeping = true
        case .sessionInactive: sessionIsInactive = true
        }
        if ownsCaptureBoundary {
            pendingStopReason = boundary.stopReason
        }
    }

    public mutating func resume(_ boundary: LibreReverseMeetingSystemBoundary) {
        switch boundary {
        case .sleep: systemIsSleeping = false
        case .sessionInactive: sessionIsInactive = false
        }
    }

    /// A boundary arriving while an already-requested stop is finalizing is
    /// satisfied by that finalization; it must not stop an unrelated meeting
    /// that begins after unlock.
    public mutating func captureBoundaryDidEnd() {
        pendingStopReason = nil
    }

    public mutating func consumePendingStop(
        hasActiveSession: Bool,
        hasOperationInFlight: Bool
    ) -> LibreReverseMeetingStopReason? {
        guard hasActiveSession else {
            if !hasOperationInFlight {
                pendingStopReason = nil
            }
            return nil
        }
        guard !hasOperationInFlight, let pendingStopReason else { return nil }
        self.pendingStopReason = nil
        return pendingStopReason
    }
}

/// Remembers an explicit "Not Now" or stop decision across transient detector
/// misses. A different candidate is never suppressed, but the ignored meeting
/// must be absent for the same observation/grace boundary used to end capture
/// before it may prompt again.
public struct LibreReverseMeetingIgnoreTracker: Equatable, Sendable {
    public private(set) var ignoredCandidate: LibreReverseMeetingCandidate?
    private var missingSince: Date?
    private var missingObservationCount = 0

    public init() {}

    public mutating func ignore(_ candidate: LibreReverseMeetingCandidate) {
        ignoredCandidate = candidate
        missingSince = nil
        missingObservationCount = 0
    }

    public mutating func reset() {
        ignoredCandidate = nil
        missingSince = nil
        missingObservationCount = 0
    }

    public mutating func candidatesExcludingIgnoredMeeting(
        _ candidates: [LibreReverseMeetingCandidate],
        at date: Date,
        configuration: LibreReverseMeetingLifecycleConfiguration
    ) -> [LibreReverseMeetingCandidate] {
        guard let ignoredCandidate else { return candidates }
        if candidates.contains(where: {
            LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting(
                $0,
                ignoredCandidate
            )
        }) {
            missingSince = nil
            missingObservationCount = 0
            return candidates.filter {
                !LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting(
                    $0,
                    ignoredCandidate
                )
            }
        }

        if missingSince == nil { missingSince = date }
        missingObservationCount += 1
        let grace =
            ignoredCandidate.provider == .localTest ? 5 : ignoredCandidate.isBrowserMeeting
            ? configuration.browserEndGrace
            : configuration.nativeEndGrace
        if missingObservationCount >= configuration.endObservationThreshold,
            date.timeIntervalSince(missingSince ?? date) >= grace
        {
            reset()
        }
        return candidates
    }
}

/// Owns the logical meeting across a short device/permission split where no
/// capture session exists. A user Stop during that interval must suppress the
/// still-visible meeting just like Stop during active capture; otherwise an
/// automatic policy can immediately start it again on the next detector tick.
public struct LibreReverseMeetingRestartIntentTracker: Equatable, Sendable {
    public private(set) var candidate: LibreReverseMeetingCandidate?

    public init() {}

    public mutating func schedule(_ candidate: LibreReverseMeetingCandidate) {
        self.candidate = candidate
    }

    /// Returns the pending logical meeting so the caller can feed it to the
    /// ordinary explicit-stop ignore tracker before releasing capture ownership.
    public mutating func cancelForUserStop() -> LibreReverseMeetingCandidate? {
        defer { candidate = nil }
        return candidate
    }

    public mutating func cancel() {
        candidate = nil
    }

    /// A cancelled predecessor must not consume a newer restart intent.
    public mutating func consume(_ expected: LibreReverseMeetingCandidate) -> Bool {
        guard let candidate,
            LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting(candidate, expected)
        else { return false }
        self.candidate = nil
        return true
    }
}

public enum LibreReverseMeetingStopReason: String, Equatable, Sendable {
    case meetingWindowClosed
    case calendarEventEnded
    case userRequested
    case applicationTermination
    case systemSleep
    case systemSessionInactive
    case audioDeviceChanged
    case audioSourceChanged
    case microphonePermissionChanged
    case storagePressure
    case captureFailure
}

public enum LibreReverseRecoveredMeetingContinuationDecision: Equatable, Sendable {
    case waiting
    case resume(LibreReverseMeetingCandidate)
    case expired
}

/// A hard app exit must not strand the rest of a meeting after its readable
/// partial MP4 is recovered. The prior explicit recording decision is reused
/// only when the same live provider window reappears within a short bound;
/// manual recordings and unrelated meetings never resume automatically.
public struct LibreReverseRecoveredMeetingContinuation: Equatable, Sendable {
    public static let maximumRecoveryAge: TimeInterval = 10 * 60
    public static let futureClockTolerance: TimeInterval = 30

    public let candidate: LibreReverseMeetingCandidate
    public let expiresAt: Date

    public init?(
        candidate: LibreReverseMeetingCandidate,
        captureFinishedAt: Date,
        recoveredAt: Date,
        maximumRecoveryAge: TimeInterval = Self.maximumRecoveryAge
    ) {
        let age = recoveredAt.timeIntervalSince(captureFinishedAt)
        guard candidate.source != .manual,
            maximumRecoveryAge > 0,
            age >= -Self.futureClockTolerance,
            age <= maximumRecoveryAge
        else { return nil }
        self.candidate = candidate
        expiresAt = captureFinishedAt.addingTimeInterval(maximumRecoveryAge)
    }

    public func decision(
        liveCandidates: [LibreReverseMeetingCandidate],
        at date: Date
    ) -> LibreReverseRecoveredMeetingContinuationDecision {
        guard date <= expiresAt else { return .expired }
        guard liveCandidates.contains(where: { $0.identity == candidate.identity }) else {
            return .waiting
        }
        return .resume(candidate)
    }
}

public struct LibreReverseRecoveredMeetingContinuationRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let publicationXID: String
    public let candidate: LibreReverseMeetingCandidate
    public let captureFinishedAt: Date
    public let createdAt: Date

    public init?(
        publicationXID: String,
        candidate: LibreReverseMeetingCandidate,
        captureFinishedAt: Date,
        createdAt: Date
    ) {
        guard !publicationXID.isEmpty,
            LibreReverseRecoveredMeetingContinuation(
                candidate: candidate,
                captureFinishedAt: captureFinishedAt,
                recoveredAt: createdAt
            ) != nil
        else { return nil }
        schemaVersion = 1
        self.publicationXID = publicationXID
        self.candidate = candidate
        self.captureFinishedAt = captureFinishedAt
        self.createdAt = createdAt
    }

    public func continuation(at date: Date) -> LibreReverseRecoveredMeetingContinuation? {
        guard schemaVersion == 1 else { return nil }
        return LibreReverseRecoveredMeetingContinuation(
            candidate: candidate,
            captureFinishedAt: captureFinishedAt,
            recoveredAt: date
        )
    }
}

/// Persists the short-lived post-crash continuation outside the recovered
/// staging directory. Publication can then remove that directory without
/// reopening a crash window before the replacement capture actually starts.
public struct LibreReverseRecoveredMeetingContinuationStore: Sendable {
    public static let fileName = "recovered-continuation.json"
    public let root: URL

    public init(root: URL) { self.root = root }

    public func persist(_ record: LibreReverseRecoveredMeetingContinuationRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = try? decode(),
            existing.captureFinishedAt > record.captureFinishedAt
        {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func load(at date: Date) throws -> LibreReverseRecoveredMeetingContinuation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let record = try? decode(), let continuation = record.continuation(at: date) else {
            try clear()
            return nil
        }
        return continuation
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private var url: URL { root.appendingPathComponent(Self.fileName) }

    private func decode() throws -> LibreReverseRecoveredMeetingContinuationRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            LibreReverseRecoveredMeetingContinuationRecord.self,
            from: Data(contentsOf: url)
        )
    }
}

public enum LibreReverseMeetingStartupFailurePolicy {
    public static func retainsStaging(captureReachedRecording: Bool) -> Bool {
        captureReachedRecording
    }
}

/// Launch recovery is a publication boundary, not a best-effort cleanup pass.
/// A transient database or filesystem failure must keep detector polling gated
/// while retries back off, otherwise a second capture can begin before the
/// recovered media and transcript job become canonical.
public struct LibreReverseMeetingRecoveryRetryPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60
    ) {
        self.initialDelay = max(0.001, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    public func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        let exponent = min(max(0, failureCount - 1), 20)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }
}

/// Captures the microphone route identity at a recording boundary. A default
/// input switch or disappearance of an explicitly selected device requires a
/// new capture segment: silently continuing would leave the user with a UI
/// that says "recording" while the expected microphone is no longer present.
public struct LibreReverseMeetingAudioRouteSnapshot: Equatable, Sendable {
    public let defaultInputDeviceID: String?
    public let defaultInputRouteName: String?
    public let availableInputDeviceIDs: Set<String>

    public init(
        defaultInputDeviceID: String?,
        defaultInputRouteName: String? = nil,
        availableInputDeviceIDs: Set<String>
    ) {
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaultInputRouteName = defaultInputRouteName
        self.availableInputDeviceIDs = availableInputDeviceIDs
    }

    public func effectiveInputDeviceID(requestedDeviceID: String?) -> String? {
        if let requestedDeviceID {
            return availableInputDeviceIDs.contains(requestedDeviceID)
                ? requestedDeviceID : nil
        }
        guard let defaultInputDeviceID,
            availableInputDeviceIDs.contains(defaultInputDeviceID)
        else { return nil }
        // macOS 14+ may expose one logical microphone whose unique ID remains
        // stable while `localizedName` changes with the physical audio route.
        return defaultInputDeviceID + "\u{0}" + (defaultInputRouteName ?? "")
    }

    public func requiresCaptureRestart(
        from baseline: Self,
        requestedDeviceID: String?
    ) -> Bool {
        effectiveInputDeviceID(requestedDeviceID: requestedDeviceID)
            != baseline.effectiveInputDeviceID(requestedDeviceID: requestedDeviceID)
    }
}

/// Debounces transient CoreMedia/AVFoundation device-list gaps. Bluetooth route
/// changes commonly expose one empty or stale enumeration before stabilizing;
/// publishing a new meeting segment on that single tick creates needless splits.
public struct LibreReverseMeetingAudioRouteChangeTracker: Sendable {
    public let observationThreshold: Int
    public private(set) var mismatchObservationCount = 0

    public init(observationThreshold: Int = 2) {
        self.observationThreshold = max(1, observationThreshold)
    }

    public mutating func observe(
        _ current: LibreReverseMeetingAudioRouteSnapshot,
        baseline: LibreReverseMeetingAudioRouteSnapshot,
        requestedDeviceID: String?
    ) -> Bool {
        guard
            current.requiresCaptureRestart(
                from: baseline,
                requestedDeviceID: requestedDeviceID
            )
        else {
            reset()
            return false
        }
        mismatchObservationCount += 1
        return mismatchObservationCount >= observationThreshold
    }

    public mutating func reset() {
        mismatchObservationCount = 0
    }
}

public enum LibreReverseMeetingLifecycleState: Equatable, Sendable {
    case idle
    case candidate(LibreReverseMeetingCandidate, observations: Int)
    case prompt(LibreReverseMeetingCandidate)
    case starting(LibreReverseMeetingCandidate)
    case recording(LibreReverseMeetingCandidate, startedAt: Date)
    case ending(
        LibreReverseMeetingCandidate,
        startedAt: Date,
        missingSince: Date,
        reentryObservations: Int
    )
    case stopping(LibreReverseMeetingCandidate, reason: LibreReverseMeetingStopReason)
    case completed(LibreReverseMeetingCandidate, segmentID: Int64?)
    case failed(LibreReverseMeetingCandidate?, message: String)
}

public enum LibreReverseMeetingLifecycleCommand: Equatable, Sendable {
    case none
    case presentPrompt(LibreReverseMeetingCandidate)
    case dismissPrompt
    case startCapture(LibreReverseMeetingCandidate)
    case stopCapture(LibreReverseMeetingStopReason)
}

/// Deterministic reducer around side-effectful capture. The reducer never calls
/// ScreenCaptureKit or persistence itself: product code acknowledges start,
/// stop, and failure only after those boundaries actually succeed. This prevents
/// a failed writer from becoming a completed canonical meeting.
public struct LibreReverseMeetingLifecycleCoordinator: Sendable {
    public private(set) var state: LibreReverseMeetingLifecycleState = .idle
    private var confirmedExitObservationCount = 0
    public let configuration: LibreReverseMeetingLifecycleConfiguration
    private var missingObservationCount = 0

    public init(configuration: LibreReverseMeetingLifecycleConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func observe(
        _ candidates: [LibreReverseMeetingCandidate]
    ) -> LibreReverseMeetingLifecycleCommand {
        observe(candidates, at: Date())
    }

    /// Advances one detector tick. `outputVoiceActivity` must represent an
    /// actual voice/activity gate, not merely the existence of an output audio
    /// buffer: audio may sustain an already confirmed meeting but can never
    /// create one. This avoids both music false positives and premature stops
    /// while a native call is minimized or a browser tab is switched.
    public mutating func observe(
        _ candidates: [LibreReverseMeetingCandidate],
        at date: Date,
        outputVoiceActivity: Bool = false,
        calendarEventActive: Bool = false,
        explicitlyEndedCandidates: [LibreReverseMeetingCandidate] = []
    ) -> LibreReverseMeetingLifecycleCommand {
        // Positive exit evidence overrides unrelated system audio, but a live
        // instance of the same room in another tab always wins. Debounce exit
        // evidence separately from ordinary missing/occluded observations.
        let active: LibreReverseMeetingCandidate?
        switch state {
        case .recording(let candidate, _), .ending(let candidate, _, _, _): active = candidate
        default: active = nil
        }
        if let active, active.source != .manual, configuration.endPolicy == .detected,
            !candidates.contains(where: { LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, active) }),
            explicitlyEndedCandidates.contains(where: { LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, active) }) {
            confirmedExitObservationCount += 1
            if confirmedExitObservationCount >= max(2, configuration.endObservationThreshold) {
                return requestStop(.meetingWindowClosed)
            }
            return .none
        }
        confirmedExitObservationCount = 0
        switch state {
        case .idle:
            guard
                let candidate = LibreReverseMeetingCandidateArbitration.selectUnambiguous(
                    candidates
                )
            else { return .none }
            state = .candidate(candidate, observations: 1)
            return stabilize(candidate, observations: 1)
        case .candidate(let current, let observations):
            guard
                let candidate = LibreReverseMeetingCandidateArbitration.selectUnambiguous(
                    candidates
                ),
                LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting(
                    candidate,
                    current
                )
            else {
                state = .idle
                return .none
            }
            let next = observations + 1
            state = .candidate(candidate, observations: next)
            return stabilize(candidate, observations: next)
        case .prompt(let current):
            guard
                candidates.contains(where: {
                    LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, current)
                })
            else {
                missingObservationCount += 1
                guard
                    missingObservationCount
                        >= configuration.promptDismissObservationThreshold
                else { return .none }
                missingObservationCount = 0
                state = .idle
                return .dismissPrompt
            }
            missingObservationCount = 0
            return .none
        case .recording(let current, let startedAt):
            // An ad-hoc recording has no detector identity to rediscover. It
            // remains user-controlled until an explicit safety/lifecycle stop
            // (sleep, storage, capture failure, termination, or Stop) arrives.
            guard current.source != .manual else { return .none }
            guard configuration.endPolicy == .detected else { return .none }
            if candidates.contains(where: {
                LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, current)
            }) {
                missingObservationCount = 0
                return .none
            }
            if outputVoiceActivity || calendarEventActive {
                missingObservationCount = 0
                return .none
            }
            missingObservationCount += 1
            state = .ending(
                current,
                startedAt: startedAt,
                missingSince: date,
                reentryObservations: 0
            )
            return maybeStopEnding(current, missingSince: date, at: date)
        case .ending(let current, let startedAt, let missingSince, let reentryObservations):
            if current.source == .manual {
                missingObservationCount = 0
                state = .recording(current, startedAt: startedAt)
                return .none
            }
            if outputVoiceActivity || calendarEventActive {
                missingObservationCount = 0
                state = .recording(current, startedAt: startedAt)
                return .none
            }
            let matchingCandidates = candidates.filter {
                LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, current)
            }
            if let refreshed = LibreReverseMeetingCandidateArbitration.selectUnambiguous(
                matchingCandidates
            ) {
                missingObservationCount = 0
                let next = reentryObservations + 1
                if next >= configuration.reentryObservationThreshold {
                    state = .recording(refreshed, startedAt: startedAt)
                } else {
                    state = .ending(
                        refreshed,
                        startedAt: startedAt,
                        missingSince: missingSince,
                        reentryObservations: next
                    )
                }
                return .none
            }
            missingObservationCount += 1
            state = .ending(
                current,
                startedAt: startedAt,
                missingSince: missingSince,
                reentryObservations: 0
            )
            return maybeStopEnding(current, missingSince: missingSince, at: date)
        case .starting, .stopping, .completed, .failed:
            return .none
        }
    }

    public mutating func acceptPrompt() -> LibreReverseMeetingLifecycleCommand {
        guard case .prompt(let candidate) = state else { return .none }
        missingObservationCount = 0
        state = .starting(candidate)
        return .startCapture(candidate)
    }

    public mutating func ignorePrompt() -> LibreReverseMeetingLifecycleCommand {
        guard case .prompt = state else { return .none }
        missingObservationCount = 0
        state = .idle
        return .dismissPrompt
    }

    public mutating func startManual(
        title: String? = nil
    ) -> LibreReverseMeetingLifecycleCommand {
        guard case .idle = state else { return .none }
        let candidate = LibreReverseMeetingCandidate(
            provider: .manual,
            source: .manual,
            title: title
        )
        state = .starting(candidate)
        return .startCapture(candidate)
    }

    /// Device changes split one logical meeting into two durable media segments
    /// without re-prompting. This is valid only after the prior capture has
    /// fully finalized and the coordinator has returned to idle.
    public mutating func resumeAfterCaptureBoundary(
        _ candidate: LibreReverseMeetingCandidate
    ) -> LibreReverseMeetingLifecycleCommand {
        guard case .idle = state else { return .none }
        state = .starting(candidate)
        return .startCapture(candidate)
    }

    public mutating func captureDidStart(at date: Date) {
        guard case .starting(let candidate) = state else { return }
        missingObservationCount = 0
        state = .recording(candidate, startedAt: date)
    }

    public mutating func requestStop(
        _ reason: LibreReverseMeetingStopReason
    ) -> LibreReverseMeetingLifecycleCommand {
        let candidate: LibreReverseMeetingCandidate
        switch state {
        case .recording(let value, _), .ending(let value, _, _, _):
            candidate = value
        default:
            return .none
        }
        state = .stopping(candidate, reason: reason)
        return .stopCapture(reason)
    }

    public mutating func captureDidFinish(segmentID: Int64?) {
        guard case .stopping(let candidate, _) = state else { return }
        state = .completed(candidate, segmentID: segmentID)
    }

    public mutating func captureDidFail(_ error: Error) {
        let candidate: LibreReverseMeetingCandidate?
        switch state {
        case .candidate(let value, _), .prompt(let value), .starting(let value),
            .recording(let value, _), .ending(let value, _, _, _),
            .stopping(let value, _), .completed(let value, _):
            candidate = value
        case .idle, .failed:
            candidate = nil
        }
        state = .failed(candidate, message: error.localizedDescription)
    }

    public mutating func reset() {
        confirmedExitObservationCount = 0
        missingObservationCount = 0
        state = .idle
    }

    private mutating func stabilize(
        _ candidate: LibreReverseMeetingCandidate,
        observations: Int
    ) -> LibreReverseMeetingLifecycleCommand {
        guard observations >= configuration.startObservationThreshold else { return .none }
        switch configuration.startPolicy {
        case .disabled:
            state = .idle
            return .none
        case .ask:
            missingObservationCount = 0
            state = .prompt(candidate)
            return .presentPrompt(candidate)
        case .automatic:
            state = .starting(candidate)
            return .startCapture(candidate)
        }
    }

    private mutating func maybeStopEnding(
        _ candidate: LibreReverseMeetingCandidate,
        missingSince: Date,
        at date: Date
    ) -> LibreReverseMeetingLifecycleCommand {
        let grace =
            candidate.provider == .localTest ? 5 : candidate.isBrowserMeeting
            ? configuration.browserEndGrace
            : configuration.nativeEndGrace
        guard missingObservationCount >= configuration.endObservationThreshold,
            date.timeIntervalSince(missingSince) >= grace
        else { return .none }
        state = .stopping(candidate, reason: .meetingWindowClosed)
        return .stopCapture(.meetingWindowClosed)
    }
}
