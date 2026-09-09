#if os(macOS)
import ApplicationServices
import AppKit
import Foundation

/// Snapshot metadata used to associate an AX window with a WindowServer ID.
/// An array index is never identity evidence: AX and WindowServer inventories
/// can have different order, hidden windows, or transiently missing entries.
public struct BrowserAXWindowIdentity: Equatable {
    public let title: String?
    public let bounds: CGRect?

    public init(title: String?, bounds: CGRect?) {
        self.title = title
        self.bounds = bounds
    }
}

public enum BrowserAXWindowResolver {
    public static func matchingIndex(title: String?, bounds: CGRect?,
                              candidates: [BrowserAXWindowIdentity]) -> Int? {
        guard let title, !title.isEmpty else { return nil }
        let matchingBounds: [Int]
        if let bounds {
            matchingBounds = candidates.indices.filter {
                candidates[$0].bounds.map { CGRectEqualToRect($0, bounds) } == true
            }
        } else {
            matchingBounds = Array(candidates.indices)
        }
        // An omitted AX window can leave a different window at the same bounds.
        // Geometry alone is therefore insufficient, even for a single match.
        // Chrome can add a trailing audible-tab indicator to its WindowServer
        // title while AX retains the page title plus browser/profile suffixes.
        // Preserve the raw identity too: if either spelling selects a sibling,
        // the result must remain ambiguous rather than borrowing its privacy.
        var windowServerTitles = [title]
        let audioIndicator = " 🔊"
        if title.hasSuffix(audioIndicator) {
            let undecorated = String(title.dropLast(audioIndicator.count))
            if !undecorated.isEmpty { windowServerTitles.append(undecorated) }
        }
        let matches = matchingBounds.filter { index in
            windowServerTitles.contains {
                titlesAreCompatible(windowServerTitle: $0, accessibilityTitle: candidates[index].title)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func titlesAreCompatible(windowServerTitle: String,
                                            accessibilityTitle: String?) -> Bool {
        guard let accessibilityTitle, !accessibilityTitle.isEmpty else { return false }
        if accessibilityTitle == windowServerTitle { return true }
        // Some browsers append their name/profile to the full page title in AX.
        // Match the complete WindowServer title at a delimiter, never a partial
        // prefix such as "Project" matching "Project secrets".
        return [" - ", " – ", " — ", ", Private Browsing"].contains {
            accessibilityTitle.hasPrefix(windowServerTitle + $0)
        }
    }

}

/// System accessibility implementation for the exact stateful provider. It
/// keeps AX objects behind stable per-instance tokens; all reusable topology
/// lives in the provider's `ElementPath` dictionaries, not in this registry.
public final class SystemBrowserAX: BrowserAXPrimitives {
    private var nextID = 1
    private var elements: [Int: AXUIElement] = [:]

    public init() {}

    public func beginSelection() {
        // AX element path values contain only child indexes. None of the
        // AXUIElement objects registered during the preceding snapshot need
        // to survive once a new WindowServer snapshot begins.
        elements.removeAll(keepingCapacity: true)
        nextID = 1
    }

    public func application(processIdentifier: pid_t, expectedName: String) -> AXElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let observed = NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
                ?? stringAttribute(application, kAXTitleAttribute as String)
                ?? stringAttribute(application, "AXName"),
              Self.applicationNameMatches(expected: expectedName, observed: observed) else { return nil }
        return register(application)
    }

    public func resolveWindow(
        application: AXElement,
        window: DesktopWindow,
        windowIndex: Int,
        cachedTopPath: inout AXElementPath?
    ) -> AXElement? {
        guard let application = element(application) else { return nil }
        // AXWindows is the authoritative app-window inventory. Chromium can
        // omit windows from AXChildren until its web accessibility tree wakes.
        var windows = attribute(application, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        if windows.isEmpty {
            let topPredicate: (AXUIElement) -> Bool = { element in
                self.childAXElements(element).contains { self.roleString($0) == "AXWindow" }
            }
            guard let top = cachedOrFresh(root: application, maxDepth: 5,
                cachedPath: &cachedTopPath, predicate: topPredicate) else { return nil }
            windows = childAXElements(top).filter { roleString($0) == "AXWindow" }
        }
        let identities = windows.map {
            BrowserAXWindowIdentity(title: stringAttribute($0, kAXTitleAttribute as String),
                                    bounds: frame(of: $0))
        }
        guard let index = BrowserAXWindowResolver.matchingIndex(
            title: window.name, bounds: window.bounds, candidates: identities) else { return nil }
        return register(windows[index])
    }

    static func applicationNameMatches(expected: String, observed: String) -> Bool {
        !observed.isEmpty && (expected.hasPrefix(observed) || observed == "Google " + expected)
    }

    static func browserRole(role: String?, subrole: String?) -> String? {
        role == "AXWindow" ? (subrole ?? role) : role
    }

    public func role(of element: AXElement) -> String? {
        guard let element = self.element(element) else { return nil }
        return Self.browserRole(role: roleString(element),
            subrole: stringAttribute(element, kAXSubroleAttribute as String))
    }

    public func title(of element: AXElement) -> String? {
        self.element(element).flatMap { stringAttribute($0, kAXTitleAttribute as String) }
    }

    public func stringValue(of element: AXElement) -> String? {
        self.element(element).flatMap { stringAttribute($0, kAXValueAttribute as String) }
    }

    public func urlValue(of element: AXElement) -> URL? {
        guard let element = self.element(element),
              let value = attribute(element, kAXURLAttribute as String) else {
            return nil
        }
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    public func children(of element: AXElement) -> [AXElement] {
        guard let element = self.element(element) else { return [] }
        return childAXElements(element).map(register)
    }

    public func findFirst(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate,
        cachedPath: inout AXElementPath?
    ) -> AXElement? {
        guard let root = element(root),
              let found = cachedOrFresh(
                  root: root,
                  maxDepth: maxDepth,
                  cachedPath: &cachedPath,
                  predicate: { self.matches($0, predicate) }
              ) else { return nil }
        return register(found)
    }

    public func findAll(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate
    ) -> [AXElement] {
        guard let root = element(root) else { return [] }
        return breadthFirst(
            root: root,
            maxDepth: maxDepth,
            firstOnly: false,
            excludingMenuBar: true,
            predicate: { self.matches($0, predicate) }
        ).map(register)
    }

    public func arcURLCandidate(
        in window: AXElement,
        processIdentifier: pid_t,
        peekOrSplitPath: inout AXElementPath?,
        normalPath: inout AXElementPath?
    ) -> AXElement? {
        guard let window = element(window) else { return nil }
        // Count split-group descendants at depth two: two or more indicate a split
        // or peek presentation, while one indicates a normal browser window.
        let peekOrSplitGroups = breadthFirst(
            root: window,
            maxDepth: 2,
            firstOnly: false,
            excludingMenuBar: true,
            predicate: { self.roleString($0) == "AXSplitGroup" }
        )
        if peekOrSplitGroups.count >= 2 {
            guard let found = cachedOrFresh(
                root: window,
                maxDepth: 5,
                cachedPath: &peekOrSplitPath,
                chooseLast: true,
                predicate: { self.urlAttribute($0) != nil }
            ) else { return nil }
            return register(found)
        }
        let normalGroups = breadthFirst(
            root: window,
            maxDepth: 2,
            firstOnly: false,
            excludingMenuBar: true,
            predicate: { self.roleString($0) == "AXSplitGroup" }
        )
        if normalGroups.count == 1 {
            guard let found = cachedOrFresh(
                root: window,
                maxDepth: 5,
                cachedPath: &normalPath,
                predicate: { self.urlAttribute($0) != nil }
            ) else { return nil }
            return register(found)
        }
        return nil
    }

    public func enableManualAccessibility(
        processIdentifier: pid_t,
        application: AXElement
    ) {
        guard let application = element(application) else { return }
        if let current = attribute(application, "AXManualAccessibility"),
           CFEqual(current, kCFBooleanTrue) {
            return
        }
        AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    private func matches(_ element: AXUIElement, _ predicate: BrowserAXPredicate) -> Bool {
        switch predicate {
        case .toolbar:
            return roleString(element) == "AXToolbar"
        case .chromeAddress:
            return stringAttribute(element, kAXTitleAttribute as String) == "Address and search bar"
                || stringAttribute(element, kAXDescriptionAttribute as String) == "Address and search bar"
        case .chromePrivate:
            return stringAttribute(element, kAXDescriptionAttribute as String)?.hasPrefix("Incognito") == true
                || stringAttribute(element, kAXTitleAttribute as String)?.hasPrefix("Incognito") == true
        case .safariAddress:
            return stringAttribute(element, kAXDescriptionAttribute as String)?.hasPrefix("smart search field") == true
        case .safariPrivate:
            return stringAttribute(element, kAXValueAttribute as String) == "Private"
        case .urlValue:
            return urlAttribute(element) != nil
        case let .webArea(excludingTitle):
            guard roleString(element) == "AXWebArea" else { return false }
            guard let excludingTitle else { return true }
            return stringAttribute(element, kAXTitleAttribute as String) != excludingTitle
        }
    }

    private func cachedOrFresh(
        root: AXUIElement,
        maxDepth: Int,
        cachedPath: inout AXElementPath?,
        chooseLast: Bool = false,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if let path = cachedPath,
           let cached = apply(path: path, to: root),
           predicate(cached) {
            return cached
        }
        let matches = breadthFirst(
            root: root,
            maxDepth: maxDepth,
            firstOnly: !chooseLast,
            excludingMenuBar: true,
            predicate: predicate
        )
        guard let fresh = chooseLast ? matches.last : matches.first,
              let path = path(from: root, to: fresh, maxDepth: maxDepth) else { return nil }
        cachedPath = path
        return fresh
    }

    private func breadthFirst(
        root: AXUIElement,
        maxDepth: Int,
        firstOnly: Bool,
        excludingMenuBar: Bool,
        predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var frontier = childAXElements(root).filter {
            !excludingMenuBar || roleString($0) != "AXMenuBar"
        }
        var depth = 1
        while !frontier.isEmpty, depth <= maxDepth {
            var next: [AXUIElement] = []
            for candidate in frontier {
                if predicate(candidate) {
                    result.append(candidate)
                    if firstOnly { return result }
                }
                next.append(contentsOf: childAXElements(candidate).filter {
                    !excludingMenuBar || roleString($0) != "AXMenuBar"
                })
            }
            frontier = next
            depth += 1
        }
        return result
    }

    private func path(
        from root: AXUIElement,
        to target: AXUIElement,
        maxDepth: Int
    ) -> AXElementPath? {
        var frontier: [(AXUIElement, [Int])] = [(root, [])]
        var depth = 0
        while !frontier.isEmpty, depth <= maxDepth {
            var next: [(AXUIElement, [Int])] = []
            for (candidate, path) in frontier {
                if CFEqual(candidate, target) { return AXElementPath(path) }
                for (index, child) in childAXElements(candidate).enumerated() {
                    next.append((child, path + [index]))
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }

    private func apply(path: AXElementPath, to root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path.childIndexes {
            let children = childAXElements(current)
            guard children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionObject = attribute(element, kAXPositionAttribute as String),
              let sizeObject = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(positionObject, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeObject, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func urlAttribute(_ element: AXUIElement) -> URL? {
        guard let value = attribute(element, kAXURLAttribute as String) else {
            return nil
        }
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func roleString(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as String)
    }

    private func childAXElements(_ element: AXUIElement) -> [AXUIElement] {
        guard let values = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return values
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func register(_ element: AXUIElement) -> AXElement {
        let id = nextID
        nextID += 1
        elements[id] = element
        return AXElement(id)
    }

    private func element(_ token: AXElement) -> AXUIElement? {
        elements[token.rawValue]
    }
}
#endif
