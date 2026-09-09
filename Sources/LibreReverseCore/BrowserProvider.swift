#if os(macOS)
import Foundation

public struct AXElement: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public struct AXElementPath: Hashable, Sendable {
    public let childIndexes: [Int]
    public init(_ childIndexes: [Int]) { self.childIndexes = childIndexes }
}

public enum BrowserCaptureReason: UInt8, Equatable, Sendable {
    case addressBarNotFound = 0
    case blockingFrontmostURL = 1
    case noChildElement = 2
    case nonStandardWindow = 3
    case privateMode = 4
    case toolbarNotFound = 5
    case webAreaNotFound = 6
    case capture = 7
    case privacyUnavailable = 8
}

public enum BrowserAXPredicate: Hashable, Sendable {
    case toolbar
    case chromeAddress
    case chromePrivate
    case safariAddress
    case safariPrivate
    case urlValue
    case webArea(excludingTitle: String?)
}

/// Injectable accessibility boundary. The provider owns every path cache;
/// implementations perform the exact cached-path validation/fresh-search
/// operation requested here and update `cachedPath` only after fresh success.
public protocol BrowserAXPrimitives: AnyObject {
    /// Starts one ordered WindowServer-selection pass. Implementations may
    /// discard transient AX object handles here; provider-owned ElementPaths
    /// deliberately survive this boundary.
    func beginSelection()
    func application(processIdentifier: pid_t, expectedName: String) -> AXElement?
    func resolveWindow(
        application: AXElement,
        window: DesktopWindow,
        windowIndex: Int,
        cachedTopPath: inout AXElementPath?
    ) -> AXElement?
    func role(of element: AXElement) -> String?
    func title(of element: AXElement) -> String?
    func stringValue(of element: AXElement) -> String?
    func urlValue(of element: AXElement) -> URL?
    func children(of element: AXElement) -> [AXElement]
    func findFirst(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate,
        cachedPath: inout AXElementPath?
    ) -> AXElement?
    func findAll(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate
    ) -> [AXElement]
    func arcURLCandidate(
        in window: AXElement,
        processIdentifier: pid_t,
        peekOrSplitPath: inout AXElementPath?,
        normalPath: inout AXElementPath?
    ) -> AXElement?
    func enableManualAccessibility(processIdentifier: pid_t, application: AXElement)
}

public final class BrowserProviderController {
    private enum Kind: Int, CaseIterable {
        case chrome, chromeDev, chromeBeta, safari, arc, dia, firefox, brave
        case slack, linear, notion, figma
    }

    private struct Definition: Hashable {
        let kind: Kind
        let expectedName: String
        let bundleIdentifier: String
        let onlyFront: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.expectedName == rhs.expectedName
                && lhs.bundleIdentifier == rhs.bundleIdentifier
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(expectedName)
            hasher.combine(bundleIdentifier)
        }
    }

    private struct Runtime {
        var windowIndex = 0
        var topPaths: [pid_t: AXElementPath] = [:]
        var toolbarPaths: [pid_t: AXElementPath] = [:]
        var addressPaths: [pid_t: AXElementPath] = [:]
        var privatePaths: [pid_t: AXElementPath] = [:]
        var arcPaths: [UInt64: AXElementPath] = [:]
        var webAreaPaths: [Int: AXElementPath] = [:]
        var lastManualAccessibilityPID: pid_t?
    }

    private static let definitions: Set<Definition> = [
        .init(kind: .chrome, expectedName: "Chrome", bundleIdentifier: "com.google.Chrome", onlyFront: false),
        .init(kind: .chromeDev, expectedName: "Chrome Dev", bundleIdentifier: "com.google.Chrome.dev", onlyFront: false),
        .init(kind: .chromeBeta, expectedName: "Chrome Beta", bundleIdentifier: "com.google.Chrome.beta", onlyFront: false),
        .init(kind: .safari, expectedName: "Safari", bundleIdentifier: "com.apple.Safari", onlyFront: false),
        .init(kind: .arc, expectedName: "Arc", bundleIdentifier: "company.thebrowser.Browser", onlyFront: false),
        .init(kind: .dia, expectedName: "Dia", bundleIdentifier: "company.thebrowser.dia", onlyFront: false),
        .init(kind: .firefox, expectedName: "Firefox", bundleIdentifier: "org.mozilla.firefox", onlyFront: false),
        .init(kind: .brave, expectedName: "Brave", bundleIdentifier: "com.brave.Browser", onlyFront: false),
        .init(kind: .slack, expectedName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", onlyFront: true),
        .init(kind: .linear, expectedName: "Linear", bundleIdentifier: "com.linear", onlyFront: true),
        .init(kind: .notion, expectedName: "Notion", bundleIdentifier: "notion.id", onlyFront: true),
        .init(kind: .figma, expectedName: "Figma", bundleIdentifier: "com.figma.Desktop", onlyFront: true),
    ]

    private let ax: BrowserAXPrimitives
    private var runtimes = Array(repeating: Runtime(), count: Kind.allCases.count)

    public init(ax: BrowserAXPrimitives) { self.ax = ax }

    public func resetWindowIndexes() {
        ax.beginSelection()
        for index in runtimes.indices { runtimes[index].windowIndex = 0 }
    }

    public func windowIndex(bundleIdentifier: String) -> Int? {
        guard let definition = Self.definitions.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        return runtimes[definition.kind.rawValue].windowIndex
    }

    /// Exact provider match/gate/index boundary. Every matched-provider exit
    /// increments once; no-provider exits never increment.
    public func properties(
        for window: DesktopWindow,
        frontmostBundleIdentifier: () -> String?
    ) -> BrowserWindowProperties? {
        guard let bundle = window.appBundleIdentifier else { return nil }
        guard let definition = Self.definitions.filter({
            bundle == $0.bundleIdentifier || bundle.hasPrefix($0.bundleIdentifier + ".")
        }).max(by: { $0.bundleIdentifier.count < $1.bundleIdentifier.count }) else { return nil }

        let runtimeIndex = definition.kind.rawValue
        let currentIndex = runtimes[runtimeIndex].windowIndex
        defer { runtimes[runtimeIndex].windowIndex += 1 }

        if definition.onlyFront,
           frontmostBundleIdentifier() != definition.bundleIdentifier {
            return nil
        }
        guard let application = ax.application(
            processIdentifier: window.appProcessIdentifier,
            expectedName: definition.expectedName
        ) else {
            // AX failure is unavailable privacy evidence for a recognized browser.
            // Electron metadata providers are ordinary apps, not privacy classifiers.
            return definition.onlyFront ? nil : properties(reason: .privacyUnavailable)
        }

        var runtime = runtimes[runtimeIndex]
        let result = produce(
            definition.kind,
            application: application,
            window: window,
            windowIndex: currentIndex,
            runtime: &runtime
        )
        runtime.windowIndex = runtimes[runtimeIndex].windowIndex
        runtimes[runtimeIndex] = runtime
        return result
    }

    private func produce(
        _ kind: Kind,
        application: AXElement,
        window: DesktopWindow,
        windowIndex: Int,
        runtime: inout Runtime
    ) -> BrowserWindowProperties {
        let pid = window.appProcessIdentifier
        var topPath = runtime.topPaths[pid]
        let resolved = ax.resolveWindow(
            application: application,
            window: window,
            windowIndex: windowIndex,
            cachedTopPath: &topPath
        )
        runtime.topPaths[pid] = topPath

        switch kind {
        case .dia:
            guard let resolved else { return properties(reason: .noChildElement) }
            var unused: AXElementPath?
            let element = ax.findFirst(in: resolved, maxDepth: 5, predicate: .urlValue, cachedPath: &unused)
            // URL extraction does not establish whether a Dia window is private.
            // Keep useful metadata when exclusion is disabled, but do not certify
            // capture until a validated private-window classifier is available.
            return properties(url: element.flatMap(ax.urlValue), reason: .privacyUnavailable)
        case .firefox:
            guard let resolved else { return properties(reason: .noChildElement) }
            guard let title = ax.title(of: resolved), !title.isEmpty else {
                return properties(reason: .privacyUnavailable)
            }
            let state = BrowserPrivacy.firefoxState(windowTitle: title)
            return properties(reason: state == .privateMode ? .privateMode : .capture)
        case .chrome, .chromeDev, .chromeBeta, .brave:
            guard let resolved else { return properties(reason: .noChildElement) }
            // Private markers have priority over optional address metadata and
            // window shape. A missing address cannot undo positive evidence.
            let windowTitle = ax.title(of: resolved)
            let chromeTitle = BrowserPrivacy.chromeTitle(windowTitle)
            let titleIsPrivate = kind == .brave
                ? BrowserPrivacy.braveState(windowTitle: windowTitle ?? "") == .privateMode
                : chromeTitle.type == .incognito
            var privatePath = runtime.privatePaths[pid]
            let privateMarker = ax.findFirst(
                in: resolved, maxDepth: 1, predicate: .chromePrivate, cachedPath: &privatePath
            ) != nil
            runtime.privatePaths[pid] = privatePath
            let isPrivate = titleIsPrivate || privateMarker
            guard ax.role(of: resolved) == "AXStandardWindow" else {
                return properties(reason: isPrivate ? .privateMode : .nonStandardWindow)
            }
            var addressPath = runtime.addressPaths[pid]
            let address = ax.findFirst(
                in: resolved, maxDepth: 10, predicate: .chromeAddress, cachedPath: &addressPath
            )
            runtime.addressPaths[pid] = addressPath
            let addressValue = address.flatMap(ax.stringValue)
            return properties(
                url: kind == .brave
                    ? BrowserPrivacy.braveURL(addressBarValue: addressValue)
                    : BrowserPrivacy.chromeURL(addressBarValue: addressValue),
                profile: kind == .brave ? nil : chromeTitle.profile,
                reason: isPrivate ? .privateMode : (address == nil ? .addressBarNotFound : .capture)
            )
        case .safari:
            guard let resolved else { return properties(reason: .noChildElement) }
            let titleIsPrivate = ax.title(of: resolved).map {
                BrowserPrivacy.safariTitledWindowState(windowTitle: $0) == .privateMode
            } ?? false
            var toolbarPath = runtime.toolbarPaths[pid]
            guard let toolbar = ax.findFirst(
                in: resolved, maxDepth: 6, predicate: .toolbar, cachedPath: &toolbarPath
            ) else {
                runtime.toolbarPaths[pid] = toolbarPath
                return properties(reason: titleIsPrivate ? .privateMode : .toolbarNotFound)
            }
            runtime.toolbarPaths[pid] = toolbarPath
            var privatePath = runtime.privatePaths[pid]
            let privateMarker = ax.findFirst(
                in: toolbar, maxDepth: 5, predicate: .safariPrivate, cachedPath: &privatePath
            ) != nil
            runtime.privatePaths[pid] = privatePath
            let isPrivate = titleIsPrivate || privateMarker
            var addressPath = runtime.addressPaths[pid]
            let address = ax.findFirst(
                in: toolbar, maxDepth: 5, predicate: .safariAddress, cachedPath: &addressPath
            )
            runtime.addressPaths[pid] = addressPath
            return properties(
                url: BrowserPrivacy.safariURL(addressBarValue: address.flatMap(ax.stringValue)),
                reason: isPrivate ? .privateMode : (address == nil ? .addressBarNotFound : .capture)
            )
        case .arc:
            guard let resolved else { return properties(reason: .noChildElement) }
            let peekKey = UInt64(UInt32(bitPattern: pid))
            let normalKey = peekKey | 0x1_0000_0000
            var peekPath = runtime.arcPaths[peekKey]
            var normalPath = runtime.arcPaths[normalKey]
            let urlElement = ax.arcURLCandidate(
                in: resolved,
                processIdentifier: pid,
                peekOrSplitPath: &peekPath,
                normalPath: &normalPath
            )
            runtime.arcPaths[peekKey] = peekPath
            runtime.arcPaths[normalKey] = normalPath
            let privacy = BrowserPrivacy.arcState(windowTitle: ax.title(of: resolved))
            let ordinary: BrowserCaptureReason = privacy == .unresolved
                ? .privacyUnavailable
                : (urlElement == nil && ax.children(of: resolved).isEmpty ? .blockingFrontmostURL : .capture)
            return properties(url: urlElement.flatMap(ax.urlValue),
                reason: privacy == .privateMode ? .privateMode : ordinary)
        case .slack, .linear, .notion, .figma:
            if runtime.lastManualAccessibilityPID != pid {
                ax.enableManualAccessibility(processIdentifier: pid, application: application)
                runtime.lastManualAccessibilityPID = pid
            }
            guard let resolved else { return properties(reason: .noChildElement) }
            guard ax.role(of: resolved) == "AXStandardWindow" else {
                return properties(reason: .nonStandardWindow)
            }
            let excluded = kind == .figma ? "Figma" : (kind == .notion ? "Notion Tabs" : nil)
            var path = runtime.webAreaPaths[windowIndex]
            let webArea = ax.findFirst(
                in: resolved, maxDepth: 8, predicate: .webArea(excludingTitle: excluded), cachedPath: &path
            )
            runtime.webAreaPaths[windowIndex] = path
            var url = webArea.flatMap(ax.urlValue)
            if kind == .slack, let source = url { url = BrowserPrivacy.slackChannelURL(from: source) }
            return properties(url: url, reason: .capture)
        }
    }

    private func properties(
        url: URL? = nil,
        profile: String? = nil,
        reason: BrowserCaptureReason
    ) -> BrowserWindowProperties {
        let state: BrowserWindowState
        switch reason {
        case .privateMode: state = .privateMode
        case .capture: state = .capture
        default: state = .unresolved
        }
        return BrowserWindowProperties(url: url, profile: profile, state: state, reason: reason)
    }
}
#endif
