#if os(macOS)
import CoreGraphics
import Foundation

public struct RunningApplication: Equatable, Sendable {
    public let localizedName: String?
    public let bundleIdentifier: String?

    public init(localizedName: String?, bundleIdentifier: String?) {
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum BrowserWindowState: Equatable, Sendable {
    case capture
    case privateMode
    /// The browser accessibility tree could not be verified. Selection must not reinterpret that absence
    /// of evidence as either a private or a standard window.
    case unresolved
}

public struct BrowserWindowProperties: Equatable, Sendable {
    public let url: URL?
    public let profile: String?
    public let state: BrowserWindowState
    public let reason: BrowserCaptureReason?

    public init(
        url: URL?,
        profile: String?,
        state: BrowserWindowState,
        reason: BrowserCaptureReason? = nil
    ) {
        self.url = url
        self.profile = profile
        self.state = state
        self.reason = reason
    }
}

public struct DesktopWindow: Equatable, Sendable {
    public let id: CGWindowID
    public let name: String
    public let appName: String
    public let appBundleIdentifier: String?
    public let appProcessIdentifier: pid_t
    public let bounds: CGRect?
    public var browserProperties: BrowserWindowProperties?
    public let isFrontWindowEligible: Bool

    public init(
        id: CGWindowID,
        name: String,
        appName: String,
        appBundleIdentifier: String?,
        appProcessIdentifier: pid_t,
        bounds: CGRect?,
        browserProperties: BrowserWindowProperties? = nil,
        isFrontWindowEligible: Bool
    ) {
        self.id = id
        self.name = name
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appProcessIdentifier = appProcessIdentifier
        self.bounds = bounds
        self.browserProperties = browserProperties
        self.isFrontWindowEligible = isFrontWindowEligible
    }
}

public struct WindowSelectionResult: Equatable, Sendable {
    public let selectedWindows: [DesktopWindow]
    public let frontWindow: DesktopWindow?

    public init(selectedWindows: [DesktopWindow], frontWindow: DesktopWindow?) {
        self.selectedWindows = selectedWindows
        self.frontWindow = frontWindow
    }

    public var captureContext: LibreReverseCaptureContext {
        guard let frontWindow else {
            return LibreReverseCaptureContext(
                bundleID: "com.apple.finder",
                windowName: "Finder"
            )
        }
        return LibreReverseCaptureContext(
            bundleID: frontWindow.appBundleIdentifier ?? "com.apple.finder",
            windowName: frontWindow.name,
            browserURL: frontWindow.browserProperties?.url?.absoluteString,
            browserProfile: frontWindow.browserProperties?.profile
        )
    }
}

public enum DesktopWindowSelector {
    public static let builtInOmittedBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui"
    ]

    /// Admits normal windows and floating application windows.
    public static func isFrontWindowEligible(layer: Int) -> Bool {
        layer == 0 || layer == 9
    }

    /// Builds a window value from the CoreGraphics window-list dictionary.
    public static func constructWindow(
        from row: [CFString: Any],
        resolveApplication: (pid_t) -> RunningApplication?
    ) -> DesktopWindow? {
        guard let number = row[kCGWindowNumber] as? UInt32,
              row[kCGWindowOwnerName] is String,
              let ownerPID = row[kCGWindowOwnerPID] as? Int32,
              let layer = row[kCGWindowLayer] as? Int,
              let application = resolveApplication(ownerPID),
              let appName = application.localizedName else {
            return nil
        }

        let windowName = (row[kCGWindowName] as? String) ?? ""
        let bounds: CGRect?
        if let dictionary = row[kCGWindowBounds] as? NSDictionary {
            guard let x = dictionary["X"] as? Int,
                  let y = dictionary["Y"] as? Int,
                  let width = dictionary["Width"] as? Int,
                  let height = dictionary["Height"] as? Int else {
                return nil
            }
            let candidate = CGRect(
                x: Double(x),
                y: Double(y),
                width: Double(width),
                height: Double(height)
            )
            guard candidate.width != 0, candidate.height != 0 else { return nil }
            bounds = candidate
        } else {
            bounds = nil
        }

        return DesktopWindow(
            id: CGWindowID(number),
            name: windowName,
            appName: appName,
            appBundleIdentifier: application.bundleIdentifier,
            appProcessIdentifier: ownerPID,
            bounds: bounds,
            isFrontWindowEligible: isFrontWindowEligible(layer: layer)
        )
    }

    /// Applies the proven outer selection order. The callback remains
    /// injectable for order tests; production callers use `isFullyOccluded`.
    public static func select(
        windows: [DesktopWindow],
        displayBounds: CGRect,
        ownBundleIdentifier: String?,
        omittedBundleIdentifiers: Set<String>,
        omittedOwnerNames: Set<String>,
        excludeIncognito: Bool,
        browserProperties: (DesktopWindow) -> BrowserWindowProperties?,
        isFullyOccluded: (CGRect, [CGRect]) -> Bool
    ) -> WindowSelectionResult {
        let omittedBundles = builtInOmittedBundleIdentifiers.union(omittedBundleIdentifiers)
        var accepted: [DesktopWindow] = []
        var occludingBounds: [CGRect] = []

        for original in windows {
            if let bundleID = original.appBundleIdentifier,
               let ownBundleIdentifier,
               bundleID == ownBundleIdentifier {
                continue
            }
            if let bounds = original.bounds {
                guard bounds.intersects(displayBounds) else { continue }
                guard !isFullyOccluded(bounds, occludingBounds) else { continue }
            }
            if let bundleID = original.appBundleIdentifier,
               omittedBundles.contains(bundleID) {
                continue
            }
            guard !omittedOwnerNames.contains(original.appName) else { continue }

            var candidate = original
            if let properties = browserProperties(original) {
                if excludeIncognito, properties.state != .capture { continue }
                candidate.browserProperties = properties
            }

            if candidate.isFrontWindowEligible, let bounds = candidate.bounds {
                // The app accumulator is a native Set<CGRect>: duplicate
                // values compare with CGRectEqualToRect and are not inserted.
                if !occludingBounds.contains(where: { CGRectEqualToRect($0, bounds) }) {
                    occludingBounds.append(bounds)
                }
            }
            accepted.append(candidate)
        }

        return WindowSelectionResult(
            selectedWindows: accepted,
            frontWindow: accepted.first(where: \.isFrontWindowEligible)
        )
    }

    /// Tests each accepted rectangle independently for inclusive containment of
    /// both diagonal corners. Overlapping rectangles are not combined into a union.
    public static func isFullyOccluded(
        _ candidate: CGRect,
        previous: [CGRect]
    ) -> Bool {
        let candidateMinX = CGRectGetMinX(candidate)
        let candidateMinY = CGRectGetMinY(candidate)
        let candidateMaxX = CGRectGetMaxX(candidate)
        let candidateMaxY = CGRectGetMaxY(candidate)

        return previous.contains { prior in
            let priorMinX = CGRectGetMinX(prior)
            let priorMinY = CGRectGetMinY(prior)
            let priorMaxX = CGRectGetMaxX(prior)
            let priorMaxY = CGRectGetMaxY(prior)
            return priorMinX <= candidateMinX
                && candidateMinX <= priorMaxX
                && priorMinY <= candidateMinY
                && candidateMinY <= priorMaxY
                && priorMinX <= candidateMaxX
                && candidateMaxX <= priorMaxX
                && priorMinY <= candidateMaxY
                && candidateMaxY <= priorMaxY
        }
    }
}
#endif
