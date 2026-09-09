#if os(macOS)
import CoreGraphics
import Foundation
@testable import LibreReverseCore
import XCTest

final class BrowserProviderTests: XCTestCase {
    func testSystemChromeIdentityUsesGoogleAppNameAndStandardWindowSubrole() {
        XCTAssertTrue(SystemBrowserAX.applicationNameMatches(expected: "Chrome", observed: "Google Chrome"))
        XCTAssertFalse(SystemBrowserAX.applicationNameMatches(expected: "Chrome", observed: ""))
        XCTAssertFalse(SystemBrowserAX.applicationNameMatches(expected: "Chrome", observed: "Safari"))
        XCTAssertEqual(SystemBrowserAX.browserRole(role: "AXWindow", subrole: "AXStandardWindow"), "AXStandardWindow")
        XCTAssertEqual(SystemBrowserAX.browserRole(role: "AXWindow", subrole: "AXDialog"), "AXDialog")
        XCTAssertEqual(SystemBrowserAX.browserRole(role: "AXToolbar", subrole: nil), "AXToolbar")
    }

    func testOrderedSnapshotUsesIndependentProviderIndexesAndResetsOnlyIndexes() {
        let ax = FakeBrowserAX()
        ax.roles[2] = "AXStandardWindow"
        ax.titles[2] = "Page - Google Chrome"
        ax.firstResults[.chromeAddress] = AXElement(3)
        ax.stringValues[3] = "example.com"
        let provider = BrowserProviderController(ax: ax)

        _ = provider.properties(for: window(id: 11, bundle: "com.google.Chrome", pid: 101), frontmostBundleIdentifier: { nil })
        _ = provider.properties(for: window(id: 12, bundle: "com.google.Chrome", pid: 101), frontmostBundleIdentifier: { nil })
        _ = provider.properties(for: window(id: 13, bundle: "org.mozilla.firefox", pid: 102), frontmostBundleIdentifier: { nil })
        XCTAssertEqual(ax.resolvedIndexes, [0, 1, 0])

        provider.resetWindowIndexes()
        _ = provider.properties(for: window(id: 14, bundle: "com.google.Chrome", pid: 101), frontmostBundleIdentifier: { nil })
        _ = provider.properties(for: window(id: 15, bundle: "org.mozilla.firefox", pid: 102), frontmostBundleIdentifier: { nil })
        XCTAssertEqual(Array(ax.resolvedIndexes.suffix(2)), [0, 0])
        XCTAssertEqual(ax.beginSelectionCount, 1)
    }

    func testStatefulProviderExcludesPrivateSelectedIDAndPreservesItWhenDisabled() {
        let ax = FakeBrowserAX()
        ax.roles[2] = "AXStandardWindow"
        ax.titles[2] = "Secret - Google Chrome (Incognito)"
        ax.firstResults[.chromeAddress] = AXElement(3)
        ax.stringValues[3] = "private.example/path"
        let provider = BrowserProviderController(ax: ax)
        let windows = [
            window(id: 31, bundle: "com.google.Chrome", pid: 301),
            window(id: 32, bundle: "com.example.Editor", pid: 302),
        ]

        func selectedIDs(exclude: Bool) -> [CGWindowID] {
            provider.resetWindowIndexes()
            return DesktopWindowSelector.select(
                windows: windows,
                displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                ownBundleIdentifier: "com.librereverse",
                omittedBundleIdentifiers: [],
                omittedOwnerNames: [],
                excludeIncognito: exclude,
                browserProperties: { window in
                    provider.properties(for: window, frontmostBundleIdentifier: { "com.google.Chrome" })
                },
                isFullyOccluded: { _, _ in false }
            ).selectedWindows.map(\.id)
        }

        XCTAssertEqual(selectedIDs(exclude: true), [32])
        XCTAssertEqual(selectedIDs(exclude: false), [31, 32])
        XCTAssertEqual(ax.resolvedIndexes, [0, 0])
    }

    func testMatchedOnlyFrontMismatchAndProducerFailureIncrementExactlyOnce() {
        let ax = FakeBrowserAX()
        ax.applicationAvailable = false
        let provider = BrowserProviderController(ax: ax)

        XCTAssertNil(provider.properties(
            for: window(id: 41, bundle: "com.tinyspeck.slackmacgap", pid: 401),
            frontmostBundleIdentifier: { "com.example.Other" }
        ))
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.tinyspeck.slackmacgap"), 1)

        XCTAssertEqual(provider.properties(
            for: window(id: 42, bundle: "com.google.Chrome", pid: 402),
            frontmostBundleIdentifier: { "com.google.Chrome" }
        )?.state, .unresolved)
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.google.Chrome"), 1)

        XCTAssertNil(provider.properties(
            for: window(id: 43, bundle: "com.example.Unsupported", pid: 403),
            frontmostBundleIdentifier: { nil }
        ))
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.google.Chrome"), 1)
    }

    func testChromeDevUsesMostSpecificProviderAndMutatesExactlyOneMatchingIndex() {
        let ax = FakeBrowserAX()
        ax.roles[2] = "AXStandardWindow"
        ax.firstResults[.chromeAddress] = AXElement(3)
        ax.stringValues[3] = "example.com"
        let provider = BrowserProviderController(ax: ax)

        XCTAssertNotNil(provider.properties(
            for: window(id: 44, bundle: "com.google.Chrome.dev", pid: 404),
            frontmostBundleIdentifier: { "com.google.Chrome.dev" }
        ))
        let stableIndex = provider.windowIndex(bundleIdentifier: "com.google.Chrome") ?? -1
        let devIndex = provider.windowIndex(bundleIdentifier: "com.google.Chrome.dev") ?? -1
        XCTAssertEqual(stableIndex, 0)
        XCTAssertEqual(devIndex, 1)
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.google.Chrome.beta"), 0)
        XCTAssertEqual(ax.resolvedIndexes, [0])
    }

    func testResetClearsIndexesButRetainsProviderOwnedPathCaches() {
        let ax = FakeBrowserAX()
        ax.roles[2] = "AXStandardWindow"
        ax.titles[2] = "Page - Google Chrome"
        ax.firstResults[.chromeAddress] = AXElement(3)
        ax.stringValues[3] = "example.com"
        let provider = BrowserProviderController(ax: ax)
        let chrome = window(id: 51, bundle: "com.google.Chrome", pid: 501)

        _ = provider.properties(for: chrome, frontmostBundleIdentifier: { "com.google.Chrome" })
        provider.resetWindowIndexes()
        _ = provider.properties(for: chrome, frontmostBundleIdentifier: { "com.google.Chrome" })

        XCTAssertEqual(ax.resolvedIndexes, [0, 0])
        XCTAssertEqual(ax.addressCacheWasPresent, [false, true])
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.google.Chrome"), 1)
    }

    func testChromeTypedFailureReasonsAreRetainedWithoutPrivateExclusion() {
        let ax = FakeBrowserAX()
        let provider = BrowserProviderController(ax: ax)
        let chrome = window(id: 61, bundle: "com.google.Chrome", pid: 601)

        ax.resolvedAvailable = false
        XCTAssertEqual(
            provider.properties(for: chrome, frontmostBundleIdentifier: { nil })?.reason,
            .noChildElement
        )

        ax.resolvedAvailable = true
        ax.roles[2] = "AXDialog"
        XCTAssertEqual(
            provider.properties(for: chrome, frontmostBundleIdentifier: { nil })?.reason,
            .nonStandardWindow
        )

        ax.roles[2] = "AXStandardWindow"
        XCTAssertEqual(
            provider.properties(for: chrome, frontmostBundleIdentifier: { nil })?.reason,
            .addressBarNotFound
        )
        XCTAssertEqual(provider.windowIndex(bundleIdentifier: "com.google.Chrome"), 3)
    }

    func testSafariUntitledPrivateMarkerSearchIsToolbarRelative() {
        let ax = FakeBrowserAX()
        ax.roles[2] = "AXStandardWindow"
        ax.firstResults[.toolbar] = AXElement(7)
        ax.firstResults[.safariAddress] = AXElement(8)
        ax.firstResults[.safariPrivate] = AXElement(9)
        ax.stringValues[8] = "private.example"
        let provider = BrowserProviderController(ax: ax)

        let result = provider.properties(
            for: window(id: 71, bundle: "com.apple.Safari", pid: 701),
            frontmostBundleIdentifier: { nil }
        )

        XCTAssertEqual(result?.reason, .privateMode)
        XCTAssertEqual(result?.url?.absoluteString, "http://private.example")
        XCTAssertEqual(
            ax.findCalls,
            [
                .init(root: 2, depth: 6, predicate: .toolbar),
                .init(root: 7, depth: 5, predicate: .safariPrivate),
                .init(root: 7, depth: 5, predicate: .safariAddress),
            ]
        )
    }

    func testArcModeSeparatedPathsSurviveIndexResetWithoutCollision() {
        let ax = FakeBrowserAX()
        ax.arcResult = AXElement(10)
        ax.urls[10] = URL(string: "https://arc.example")
        let provider = BrowserProviderController(ax: ax)
        let arc = window(id: 81, bundle: "company.thebrowser.Browser", pid: 801)

        _ = provider.properties(for: arc, frontmostBundleIdentifier: { nil })
        provider.resetWindowIndexes()
        _ = provider.properties(for: arc, frontmostBundleIdentifier: { nil })

        XCTAssertEqual(ax.arcCachePresence, [[false, false], [true, true]])
        XCTAssertEqual(ax.beginSelectionCount, 1)
    }

    func testConclusivePrivateTitlesSurviveMissingAddressAndToolbar() {
        let examples = [
            ("com.google.Chrome", "Secret - Google Chrome (Incognito)"),
            ("com.brave.Browser", "Secret - Brave (Private)"),
            ("com.apple.Safari", "Secret, Private Browsing"),
        ]
        for (bundle, title) in examples {
            let ax = FakeBrowserAX()
            ax.roles[2] = "AXStandardWindow"
            ax.titles[2] = title
            let result = BrowserProviderController(ax: ax).properties(
                for: window(id: 91, bundle: bundle, pid: 901), frontmostBundleIdentifier: { bundle })
            XCTAssertEqual(result?.state, .privateMode, bundle)
            XCTAssertNil(result?.url)
        }
    }

    func testPrivateAXMarkersPrecedeMissingAddressSearchEvenWithNormalTitle() {
        for bundle in ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari"] {
            let ax = FakeBrowserAX()
            ax.roles[2] = "AXStandardWindow"
            ax.titles[2] = "An ordinary page title"
            let safari = bundle == "com.apple.Safari"
            let privatePredicate: BrowserAXPredicate = safari ? .safariPrivate : .chromePrivate
            let addressPredicate: BrowserAXPredicate = safari ? .safariAddress : .chromeAddress
            ax.firstResults[privatePredicate] = AXElement(9)
            if safari { ax.firstResults[.toolbar] = AXElement(7) }
            let result = BrowserProviderController(ax: ax).properties(
                for: window(id: 92, bundle: bundle, pid: 902), frontmostBundleIdentifier: { bundle })
            XCTAssertEqual(result?.state, .privateMode, bundle)
            let predicates = ax.findCalls.map(\.predicate)
            XCTAssertLessThan(predicates.firstIndex(of: privatePredicate)!, predicates.firstIndex(of: addressPredicate)!)
        }
    }

    func testRecognizedBrowserAXFailuresAreExcludedButOtherAppsRemain() {
        let ax = FakeBrowserAX()
        ax.applicationAvailable = false
        let provider = BrowserProviderController(ax: ax)
        let windows = [
            window(id: 1, bundle: "com.google.Chrome", pid: 100),
            window(id: 2, bundle: "com.example.Editor", pid: 101),
            window(id: 3, bundle: "com.google.ChromeLookalike", pid: 102),
        ]
        for exclude in [true, false] {
            let selected = DesktopWindowSelector.select(windows: windows,
                displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                ownBundleIdentifier: nil, omittedBundleIdentifiers: [], omittedOwnerNames: [],
                excludeIncognito: exclude,
                browserProperties: { provider.properties(for: $0, frontmostBundleIdentifier: { nil }) },
                isFullyOccluded: { _, _ in false }).selectedWindows.map(\.id)
            XCTAssertEqual(selected, exclude ? [2, 3] : [1, 2, 3])
        }
    }

    func testMissingAXTitleCannotCertifyFirefoxOrArcAndArcRetainsKnownURL() {
        for bundle in ["org.mozilla.firefox", "company.thebrowser.Browser"] {
            let ax = FakeBrowserAX()
            ax.arcResult = AXElement(10)
            ax.urls[10] = URL(string: "https://known.example")
            let result = BrowserProviderController(ax: ax).properties(
                for: window(id: 93, bundle: bundle, pid: 903), frontmostBundleIdentifier: { bundle })
            XCTAssertEqual(result?.state, .unresolved)
            if bundle == "company.thebrowser.Browser" {
                XCTAssertEqual(result?.url?.absoluteString, "https://known.example")
            }
        }
    }

    func testDiaURLDoesNotCertifyPrivacyOrEscapeFailedWindowResolution() {
        let ax = FakeBrowserAX()
        ax.firstResults[.urlValue] = AXElement(10)
        ax.urls[10] = URL(string: "https://known.example")
        let provider = BrowserProviderController(ax: ax)
        let dia = window(id: 94, bundle: "company.thebrowser.dia", pid: 904)
        let result = provider.properties(for: dia, frontmostBundleIdentifier: { nil })
        XCTAssertEqual(result?.state, .unresolved)
        XCTAssertEqual(result?.url?.absoluteString, "https://known.example")
        ax.resolvedAvailable = false
        let unresolved = provider.properties(for: dia, frontmostBundleIdentifier: { nil })
        XCTAssertEqual(unresolved?.state, .unresolved)
        XCTAssertNil(unresolved?.url)
    }

    func testNormalBrowserWindowsRemainCapturableWithTheirKnownURLs() {
        for bundle in ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari"] {
            let ax = FakeBrowserAX()
            ax.roles[2] = "AXStandardWindow"
            ax.titles[2] = "Page - Google Chrome"
            ax.firstResults[.chromeAddress] = AXElement(3)
            ax.firstResults[.toolbar] = AXElement(7)
            ax.firstResults[.safariAddress] = AXElement(3)
            ax.stringValues[3] = "https://known.example/path"
            let result = BrowserProviderController(ax: ax).properties(
                for: window(id: 95, bundle: bundle, pid: 905), frontmostBundleIdentifier: { nil })
            XCTAssertEqual(result?.state, .capture, bundle)
            XCTAssertEqual(result?.url?.absoluteString, "https://known.example/path")
        }
    }

    private func window(
        id: CGWindowID,
        bundle: String,
        pid: pid_t
    ) -> DesktopWindow {
        DesktopWindow(
            id: id,
            name: "Window \(id)",
            appName: bundle,
            appBundleIdentifier: bundle,
            appProcessIdentifier: pid,
            bounds: CGRect(x: CGFloat(id), y: 0, width: 1, height: 1),
            isFrontWindowEligible: true
        )
    }
}

private final class FakeBrowserAX: BrowserAXPrimitives {
    struct FindCall: Equatable {
        let root: Int
        let depth: Int
        let predicate: BrowserAXPredicate
    }

    var applicationAvailable = true
    var resolvedAvailable = true
    var roles: [Int: String] = [:]
    var titles: [Int: String] = [:]
    var stringValues: [Int: String] = [:]
    var urls: [Int: URL] = [:]
    var childElements: [Int: [AXElement]] = [:]
    var firstResults: [BrowserAXPredicate: AXElement] = [:]
    var resolvedIndexes: [Int] = []
    var addressCacheWasPresent: [Bool] = []
    var beginSelectionCount = 0
    var findCalls: [FindCall] = []
    var arcResult: AXElement?
    var arcCachePresence: [[Bool]] = []

    func beginSelection() { beginSelectionCount += 1 }

    func application(processIdentifier: pid_t, expectedName: String) -> AXElement? {
        applicationAvailable ? AXElement(1) : nil
    }

    func resolveWindow(
        application: AXElement,
        window: DesktopWindow,
        windowIndex: Int,
        cachedTopPath: inout AXElementPath?
    ) -> AXElement? {
        resolvedIndexes.append(windowIndex)
        if cachedTopPath == nil { cachedTopPath = AXElementPath([0]) }
        return resolvedAvailable ? AXElement(2) : nil
    }

    func role(of element: AXElement) -> String? { roles[element.rawValue] }
    func title(of element: AXElement) -> String? { titles[element.rawValue] }
    func stringValue(of element: AXElement) -> String? { stringValues[element.rawValue] }
    func urlValue(of element: AXElement) -> URL? { urls[element.rawValue] }
    func children(of element: AXElement) -> [AXElement] {
        childElements[element.rawValue, default: []]
    }

    func findFirst(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate,
        cachedPath: inout AXElementPath?
    ) -> AXElement? {
        findCalls.append(.init(root: root.rawValue, depth: maxDepth, predicate: predicate))
        if predicate == .chromeAddress { addressCacheWasPresent.append(cachedPath != nil) }
        guard let result = firstResults[predicate] else { return nil }
        if cachedPath == nil { cachedPath = AXElementPath([result.rawValue]) }
        return result
    }

    func findAll(
        in root: AXElement,
        maxDepth: Int,
        predicate: BrowserAXPredicate
    ) -> [AXElement] { [] }

    func arcURLCandidate(
        in window: AXElement,
        processIdentifier: pid_t,
        peekOrSplitPath: inout AXElementPath?,
        normalPath: inout AXElementPath?
    ) -> AXElement? {
        arcCachePresence.append([peekOrSplitPath != nil, normalPath != nil])
        if peekOrSplitPath == nil { peekOrSplitPath = AXElementPath([1]) }
        if normalPath == nil { normalPath = AXElementPath([2]) }
        return arcResult
    }

    func enableManualAccessibility(processIdentifier: pid_t, application: AXElement) {}
}
#endif
