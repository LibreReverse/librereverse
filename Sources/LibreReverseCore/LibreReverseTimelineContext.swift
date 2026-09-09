import Foundation

/// Known browser identities. Unknown bundle identifiers remain
/// first-class application identities rather than generic browsers.
public enum LibreReverseRecordedApplication: Equatable, Sendable {
    case safari
    case chrome
    case chromeBeta
    case chromeDev
    case brave
    case arc
    case dia
    case firefox
    case other(bundleID: String?)

    public init(bundleID: String?) {
        switch bundleID {
        case "com.apple.Safari": self = .safari
        case "com.google.Chrome": self = .chrome
        case "com.google.Chrome.beta": self = .chromeBeta
        case "com.google.Chrome.dev": self = .chromeDev
        case "com.brave.Browser": self = .brave
        case "company.thebrowser.Browser": self = .arc
        case "company.thebrowser.dia": self = .dia
        case "org.mozilla.firefox": self = .firefox
        default: self = .other(bundleID: bundleID)
        }
    }

    public var bundleID: String? {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .chromeBeta: "com.google.Chrome.beta"
        case .chromeDev: "com.google.Chrome.dev"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .dia: "company.thebrowser.dia"
        case .firefox: "org.mozilla.firefox"
        case let .other(bundleID): bundleID
        }
    }

    public var fallbackDisplayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .chromeBeta: "Google Chrome Beta"
        case .chromeDev: "Google Chrome Dev"
        case .brave: "Brave Browser"
        case .arc: "Arc"
        case .dia: "Dia"
        case .firefox: "Firefox"
        case let .other(bundleID):
            bundleID?.split(separator: ".").last.map(String.init) ?? "Unknown application"
        }
    }

    public var isSupportedBrowser: Bool {
        switch self {
        case .safari, .chrome, .chromeBeta, .chromeDev, .brave, .arc, .dia, .firefox:
            true
        case .other:
            false
        }
    }
}

public struct LibreReverseContextualOpenAction: Equatable, Sendable {
    public let url: URL
    public let application: LibreReverseRecordedApplication
    public let browserProfile: String?

    public init(
        url: URL,
        application: LibreReverseRecordedApplication,
        browserProfile: String?
    ) {
        self.url = url
        self.application = application
        self.browserProfile = browserProfile
    }
}

/// Recorded URL metadata determines whether the timeline offers opening
/// a page. Resolve the installed browser only on activation; a missing
/// application must not hide the recorded link.
public enum LibreReverseContextualOpenContract {
    public static func presentsControl(for action: LibreReverseContextualOpenAction?) -> Bool {
        action != nil
    }
}

public struct LibreReverseTimelineSelectionContext: Equatable, Sendable {
    public let segmentID: Int64
    public let application: LibreReverseRecordedApplication
    public let windowName: String?
    public let websiteHost: String?
    public let openAction: LibreReverseContextualOpenAction?

    public init(segment: TimelineSegment) {
        segmentID = segment.rawID
        application = LibreReverseRecordedApplication(bundleID: segment.bundleID)
        windowName = segment.windowName
        websiteHost = TimelineSegmentProcessor.websiteHost(for: segment.browserURL)
        if application.isSupportedBrowser,
           let url = LibreReverseTimelineContextResolver.openableWebURL(segment.browserURL) {
            openAction = LibreReverseContextualOpenAction(
                url: url,
                application: application,
                browserProfile: segment.browserProfile
            )
        } else {
            openAction = nil
        }
    }

    public var accessibilityLabel: String {
        var components = [application.fallbackDisplayName]
        if let websiteHost, !websiteHost.isEmpty { components.append(websiteHost) }
        if let windowName, !windowName.isEmpty, windowName != websiteHost {
            components.append(windowName)
        }
        return components.joined(separator: ", ")
    }
}

public enum LibreReverseTimelineContextResolver {
    /// Resolves from the same selected raw IDs used to highlight the timeline.
    /// A date fallback exists for the live edge before a persisted frame ID is
    /// available. Processed records also match their accumulated raw IDs.
    public static func selectedContext(
        in snapshot: LibreReverseTimelineSnapshot,
        selectedSegmentIDs: Set<Int64>,
        at date: Date?
    ) -> LibreReverseTimelineSelectionContext? {
        let segments = snapshot.processedScreenshotSegments
        if !selectedSegmentIDs.isEmpty,
           let selected = segments.last(where: { segment in
               selectedSegmentIDs.contains(segment.rawID)
                   || (segment.mergedSegmentIDs?.contains(where: selectedSegmentIDs.contains) ?? false)
           }) {
            return LibreReverseTimelineSelectionContext(segment: selected)
        }
        guard let date else { return nil }
        if let containing = segments.last(where: {
            $0.startDate <= date && date < $0.endDate
        }) {
            return LibreReverseTimelineSelectionContext(segment: containing)
        }
        guard let preceding = segments.last(where: { $0.endDate <= date }) else { return nil }
        return LibreReverseTimelineSelectionContext(segment: preceding)
    }

    /// Contextual Open is deliberately limited to a recorded absolute HTTP(S)
    /// URL. Host-only values are useful for grouping but are not rewritten into
    /// a speculative destination.
    public static func openableWebURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}
