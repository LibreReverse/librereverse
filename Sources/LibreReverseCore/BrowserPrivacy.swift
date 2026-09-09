#if os(macOS)
import Foundation

public enum ChromeTitleType: UInt8, Equatable, Sendable {
    case guest = 0
    case incognito = 1
    case normal = 2
    case profile = 3
}

public struct ChromeTitle: Equatable, Sendable {
    public let pageTitle: String?
    public let profile: String?
    public let type: ChromeTitleType

    public init(pageTitle: String?, profile: String?, type: ChromeTitleType) {
        self.pageTitle = pageTitle
        self.profile = profile
        self.type = type
    }
}

/// Browser title parsing and privacy classification. AX traversal and
/// cached toolbar element paths intentionally remain outside this type.
public enum BrowserPrivacy {
    private static let chromePatterns: [(String, ChromeTitleType)] = [
        (#"^(?<pageTitle>.+) (-|–) Google Chrome(|\s\w+) (-|–) (?<profile>.+)$"#, .profile),
        (#"^(?<pageTitle>.+) (-|–) Google Chrome(|\s\w+)$"#, .normal),
        (#"^(?<pageTitle>.+) (-|–) Google Chrome(|\s\w+) \(Incognito\)$"#, .incognito),
        (#"^(?<pageTitle>.+) (-|–) Google Chrome(|\s\w+) \(Guest\)$"#, .guest),
    ]

    /// Classifies Chrome titles in pattern order, then applies the fallback type.
    public static func chromeTitle(_ title: String?) -> ChromeTitle {
        guard let title else {
            return ChromeTitle(pageTitle: nil, profile: nil, type: .guest)
        }
        let wholeRange = NSRange(title.startIndex..<title.endIndex, in: title)
        for (pattern, type) in chromePatterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: title, range: wholeRange) else { continue }
            return ChromeTitle(
                pageTitle: substring(named: "pageTitle", match: match, in: title),
                profile: substring(named: "profile", match: match, in: title),
                type: type
            )
        }
        return ChromeTitle(pageTitle: nil, profile: nil, type: .guest)
    }

    /// Rejects New tab and values without a dot. Preserve an existing scheme;
    /// otherwise prepend http:// before Foundation URL parsing.
    public static func chromeURL(addressBarValue: String?) -> URL? {
        guard let addressBarValue,
              addressBarValue != "New tab",
              addressBarValue.contains(".") else {
            return nil
        }
        let normalized = addressBarValue.contains("://")
            ? addressBarValue
            : "http://" + addressBarValue
        return URL(string: normalized)
    }

    /// Firefox's complete producer uses case-sensitive String.contains.
    public static func firefoxState(windowTitle: String) -> BrowserWindowState {
        windowTitle.contains("Private Browsing") ? .privateMode : .capture
    }

    /// Brave's producer checks the AX window title with an exact,
    /// case-sensitive suffix before choosing reason 4 versus reason 7.
    public static func braveState(windowTitle: String) -> BrowserWindowState {
        windowTitle.hasSuffix("Brave (Private)") ? .privateMode : .capture
    }

    /// Brave uses the same dot/scheme normalization as Chrome, but has no
    /// separate `New tab` equality branch (that value fails the dot test).
    public static func braveURL(addressBarValue: String?) -> URL? {
        guard let addressBarValue, addressBarValue.contains(".") else {
            return nil
        }
        let normalized = addressBarValue.contains("://")
            ? addressBarValue
            : "http://" + addressBarValue
        return URL(string: normalized)
    }

    /// Arc's principal producer treats this internal AX window-title marker
    /// as private using case-sensitive `contains`.
    public static func arcState(windowTitle: String?) -> BrowserWindowState {
        guard let windowTitle, !windowTitle.isEmpty else { return .unresolved }
        return windowTitle.contains("bigIncognitoBrowserWindow") ? .privateMode : .capture
    }

    /// Safari's titled-window branch uses case-sensitive String.hasSuffix.
    /// The no-title branch instead uses a cached toolbar element path.
    public static func safariTitledWindowState(
        windowTitle: String
    ) -> BrowserWindowState {
        windowTitle.hasSuffix(", Private Browsing") ? .privateMode : .capture
    }

    /// Safari's string-valued address path ignores `Start Page`, then uses
    /// the same dot/scheme normalization as Chrome and Brave.
    public static func safariURL(addressBarValue: String?) -> URL? {
        guard let addressBarValue,
              addressBarValue != "Start Page",
              addressBarValue.contains(".") else {
            return nil
        }
        let normalized = addressBarValue.contains("://")
            ? addressBarValue
            : "http://" + addressBarValue
        return URL(string: normalized)
    }

    /// Slack's exact conversion from a web URL path into its native channel
    /// deep link. It removes exact "/" and "client" components, requires a
    /// second component beginning with uppercase C, then uses the first two.
    public static func slackChannelURL(from webURL: URL) -> URL? {
        let components = webURL.pathComponents.filter { $0 != "/" && $0 != "client" }
        guard components.count >= 2, components[1].hasPrefix("C") else { return nil }
        return URL(string: "slack://channel?team=\(components[0])&id=\(components[1])")
    }

    private static func substring(
        named name: String,
        match: NSTextCheckingResult,
        in string: String
    ) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else {
            return nil
        }
        return String(string[swiftRange])
    }
}

public struct CapturePrivacySettings: Equatable, Sendable {
    public let omittedAppBundleIdentifiers: Set<String>
    public let omittedOwnerNames: Set<String>
    public let excludeIncognito: Bool

    public init(
        omittedAppBundleIdentifiers: Set<String>,
        omittedOwnerNames: Set<String> = [],
        excludeIncognito: Bool
    ) {
        self.omittedAppBundleIdentifiers = omittedAppBundleIdentifiers
        self.omittedOwnerNames = omittedOwnerNames
        self.excludeIncognito = excludeIncognito
    }

    /// Privacy defaults must not depend on the user's preferred language.
    public static func defaultExcludeIncognito(
        preferredLanguages: [String]
    ) -> Bool {
        true
    }
}
#endif
