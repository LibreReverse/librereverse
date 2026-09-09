#if os(macOS)
import CoreGraphics
import Foundation
@testable import LibreReverseCore
import XCTest

final class WindowSelectionTests: XCTestCase {
    func testExactFrontWindowEligibleLayerSet() {
        XCTAssertFalse(DesktopWindowSelector.isFrontWindowEligible(layer: -1))
        XCTAssertTrue(DesktopWindowSelector.isFrontWindowEligible(layer: 0))
        XCTAssertFalse(DesktopWindowSelector.isFrontWindowEligible(layer: 1))
        XCTAssertFalse(DesktopWindowSelector.isFrontWindowEligible(layer: 8))
        XCTAssertTrue(DesktopWindowSelector.isFrontWindowEligible(layer: 9))
        XCTAssertFalse(DesktopWindowSelector.isFrontWindowEligible(layer: 10))
    }

    func testConstructWindowUsesExactCastsAndApplicationMetadata() {
        let row = windowDictionary(
            id: 42,
            ownerName: "WindowServer Owner",
            pid: 77,
            name: nil,
            layer: 9,
            bounds: ["X": 1, "Y": 2, "Width": 300, "Height": 200]
        )
        let window = DesktopWindowSelector.constructWindow(
            from: row,
            resolveApplication: { pid in
                XCTAssertEqual(pid, 77)
                return RunningApplication(
                    localizedName: "Resolved App",
                    bundleIdentifier: nil
                )
            }
        )

        XCTAssertEqual(window?.id, 42)
        XCTAssertEqual(window?.name, "")
        XCTAssertEqual(window?.appName, "Resolved App")
        XCTAssertNil(window?.appBundleIdentifier)
        XCTAssertEqual(window?.bounds, CGRect(x: 1, y: 2, width: 300, height: 200))
        XCTAssertEqual(window?.isFrontWindowEligible, true)
    }

    func testConstructWindowRejectsMissingRequiredAndZeroSizedRows() {
        let resolver: (pid_t) -> RunningApplication? = { _ in
            RunningApplication(localizedName: "App", bundleIdentifier: "com.example")
        }
        var missingOwner = windowDictionary()
        missingOwner.removeValue(forKey: kCGWindowOwnerName)
        XCTAssertNil(DesktopWindowSelector.constructWindow(
            from: missingOwner,
            resolveApplication: resolver
        ))

        var wrongNumber = windowDictionary()
        wrongNumber[kCGWindowNumber] = "1"
        XCTAssertNil(DesktopWindowSelector.constructWindow(
            from: wrongNumber,
            resolveApplication: resolver
        ))

        let zeroWidth = windowDictionary(
            bounds: ["X": 0, "Y": 0, "Width": 0, "Height": 100]
        )
        XCTAssertNil(DesktopWindowSelector.constructWindow(
            from: zeroWidth,
            resolveApplication: resolver
        ))

        XCTAssertNil(DesktopWindowSelector.constructWindow(
            from: windowDictionary(),
            resolveApplication: { _ in
                RunningApplication(localizedName: nil, bundleIdentifier: "com.example")
            }
        ))
    }

    func testConstructWindowAllowsAbsentBounds() {
        var row = windowDictionary()
        row.removeValue(forKey: kCGWindowBounds)
        let window = DesktopWindowSelector.constructWindow(
            from: row,
            resolveApplication: { _ in
                RunningApplication(localizedName: "App", bundleIdentifier: "com.example")
            }
        )
        XCTAssertNotNil(window)
        XCTAssertNil(window?.bounds)
    }

    func testConstructWindowAcceptsNSNumberBackedCoreGraphicsScalars() {
        var row = windowDictionary()
        row[kCGWindowNumber] = NSNumber(value: UInt32(91))
        row[kCGWindowOwnerPID] = NSNumber(value: Int32(17))
        row[kCGWindowLayer] = NSNumber(value: 9)
        let window = DesktopWindowSelector.constructWindow(
            from: row,
            resolveApplication: { _ in
                RunningApplication(localizedName: "App", bundleIdentifier: "com.example")
            }
        )
        XCTAssertEqual(window?.id, 91)
        XCTAssertEqual(window?.appProcessIdentifier, 17)
        XCTAssertEqual(window?.isFrontWindowEligible, true)
    }

    func testSelectionAppliesProvenOrderAndChoosesFirstEligibleSurvivor() {
        let windows = [
            window(id: 1, app: "Self", bundle: "com.librereverse", x: 1),
            window(id: 2, app: "Outside", bundle: "com.outside", x: 200),
            window(id: 3, app: "Notification", bundle: "com.apple.notificationcenterui", x: 3),
            window(id: 4, app: "Configured", bundle: "com.blocked", x: 4),
            window(id: 5, app: "Blocked Owner", bundle: "com.owner", x: 5),
            window(id: 6, app: "Occluded", bundle: "com.occluded", x: 6),
            window(id: 7, app: "Private Browser", bundle: "com.browser", x: 7),
            window(id: 8, app: "Overlay", bundle: "com.overlay", x: 8, eligible: false),
            window(id: 9, app: "Front", bundle: "com.front", x: 9),
            window(id: 10, app: "Back", bundle: "com.back", x: 10)
        ]
        var occlusionInputs: [Int] = []
        var browserInputs: [CGWindowID] = []
        let selection = DesktopWindowSelector.select(
            windows: windows,
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownBundleIdentifier: "com.librereverse",
            omittedBundleIdentifiers: ["com.blocked"],
            omittedOwnerNames: ["Blocked Owner"],
            excludeIncognito: true,
            browserProperties: { candidate in
                browserInputs.append(candidate.id)
                guard candidate.id == 7 else { return nil }
                return BrowserWindowProperties(
                    url: URL(string: "https://private.example/path"),
                    profile: "Private",
                    state: .privateMode
                )
            },
            isFullyOccluded: { bounds, _ in
                occlusionInputs.append(Int(bounds.minX))
                return bounds.minX == 6
            }
        )

        XCTAssertEqual(occlusionInputs, [3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(browserInputs, [7, 8, 9, 10])
        XCTAssertEqual(selection.selectedWindows.map(\.id), [8, 9, 10])
        XCTAssertEqual(selection.frontWindow?.id, 9)
    }

    func testPrivateModeIsRetainedWhenExcludeIncognitoIsFalse() {
        let properties = BrowserWindowProperties(
            url: URL(string: "https://private.example/a?b=1"),
            profile: "Profile 2",
            state: .privateMode
        )
        let selection = DesktopWindowSelector.select(
            windows: [window(id: 11, app: "Browser", bundle: "com.browser", x: 1)],
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownBundleIdentifier: "com.librereverse",
            omittedBundleIdentifiers: [],
            omittedOwnerNames: [],
            excludeIncognito: false,
            browserProperties: { _ in properties },
            isFullyOccluded: { _, _ in false }
        )

        XCTAssertEqual(selection.selectedWindows.count, 1)
        XCTAssertEqual(selection.captureContext.browserURL, "https://private.example/a?b=1")
        XCTAssertEqual(selection.captureContext.browserProfile, "Profile 2")
    }

    func testSelectedWindowIDsApplyExcludeIncognitoSettingExactly() {
        let windows = [
            window(id: 21, app: "Browser", bundle: "com.browser", x: 1),
            window(id: 22, app: "Editor", bundle: "com.editor", x: 2),
        ]
        let properties: (DesktopWindow) -> BrowserWindowProperties? = { window in
            guard window.id == 21 else { return nil }
            return BrowserWindowProperties(
                url: URL(string: "https://private.example/secret"),
                profile: nil,
                state: .privateMode
            )
        }
        func select(excludeIncognito: Bool) -> WindowSelectionResult {
            DesktopWindowSelector.select(
                windows: windows,
                displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                ownBundleIdentifier: "com.librereverse",
                omittedBundleIdentifiers: [],
                omittedOwnerNames: [],
                excludeIncognito: excludeIncognito,
                browserProperties: properties,
                isFullyOccluded: { _, _ in false }
            )
        }

        XCTAssertEqual(select(excludeIncognito: true).selectedWindows.map(\.id), [22])
        XCTAssertEqual(select(excludeIncognito: false).selectedWindows.map(\.id), [21, 22])
    }

    func testExactOcclusionUsesInclusiveSingleRectangleContainment() {
        let candidate = CGRect(x: 10, y: 20, width: 30, height: 40)

        XCTAssertTrue(DesktopWindowSelector.isFullyOccluded(
            candidate,
            previous: [CGRect(x: 10, y: 20, width: 30, height: 40)]
        ))
        XCTAssertTrue(DesktopWindowSelector.isFullyOccluded(
            candidate,
            previous: [CGRect(x: 0, y: 0, width: 100, height: 100)]
        ))
        XCTAssertFalse(DesktopWindowSelector.isFullyOccluded(
            candidate,
            previous: [CGRect(x: 10.01, y: 20, width: 100, height: 100)]
        ))
    }

    func testExactOcclusionDoesNotUnionPreviousRectangles() {
        let candidate = CGRect(x: 0, y: 0, width: 100, height: 100)
        let leftHalf = CGRect(x: 0, y: 0, width: 50, height: 100)
        let rightHalf = CGRect(x: 50, y: 0, width: 50, height: 100)

        XCTAssertFalse(DesktopWindowSelector.isFullyOccluded(
            candidate,
            previous: [leftHalf, rightHalf]
        ))
    }

    func testOccludingAccumulatorHasSetSemanticsForDuplicateRects() {
        let duplicateBounds = CGRect(x: 1, y: 1, width: 20, height: 20)
        let windows = (1...3).map { id in
            DesktopWindow(
                id: CGWindowID(id),
                name: "Window \(id)",
                appName: "App \(id)",
                appBundleIdentifier: "com.example.\(id)",
                appProcessIdentifier: pid_t(id),
                bounds: duplicateBounds,
                isFrontWindowEligible: true
            )
        }
        var priorCounts: [Int] = []

        _ = DesktopWindowSelector.select(
            windows: windows,
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            ownBundleIdentifier: nil,
            omittedBundleIdentifiers: [],
            omittedOwnerNames: [],
            excludeIncognito: false,
            browserProperties: { _ in nil },
            isFullyOccluded: { _, previous in
                priorCounts.append(previous.count)
                return false
            }
        )

        XCTAssertEqual(priorCounts, [0, 1, 1])
    }

    func testCaptureContextUsesExactFinderFallbacks() {
        let empty = WindowSelectionResult(selectedWindows: [], frontWindow: nil)
        XCTAssertEqual(empty.captureContext.bundleID, "com.apple.finder")
        XCTAssertEqual(empty.captureContext.windowName, "Finder")

        let noBundle = window(id: 12, app: "Agent", bundle: nil, x: 1)
        let selection = WindowSelectionResult(
            selectedWindows: [noBundle],
            frontWindow: noBundle
        )
        XCTAssertEqual(selection.captureContext.bundleID, "com.apple.finder")
        XCTAssertEqual(selection.captureContext.windowName, "Window 12")
    }

    private func windowDictionary(
        id: UInt32 = 1,
        ownerName: String = "Owner",
        pid: Int32 = 2,
        name: String? = "Window",
        layer: Int = 0,
        bounds: NSDictionary? = ["X": 0, "Y": 0, "Width": 100, "Height": 100]
    ) -> [CFString: Any] {
        var row: [CFString: Any] = [
            kCGWindowNumber: id,
            kCGWindowOwnerName: ownerName,
            kCGWindowOwnerPID: pid,
            kCGWindowLayer: layer
        ]
        if let name { row[kCGWindowName] = name }
        if let bounds { row[kCGWindowBounds] = bounds }
        return row
    }

    private func window(
        id: CGWindowID,
        app: String,
        bundle: String?,
        x: CGFloat,
        eligible: Bool = true
    ) -> DesktopWindow {
        DesktopWindow(
            id: id,
            name: "Window \(id)",
            appName: app,
            appBundleIdentifier: bundle,
            appProcessIdentifier: pid_t(id),
            bounds: CGRect(x: x, y: 0, width: 1, height: 1),
            isFrontWindowEligible: eligible
        )
    }
}
#endif
