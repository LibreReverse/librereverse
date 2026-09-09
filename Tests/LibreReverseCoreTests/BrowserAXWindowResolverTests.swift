#if os(macOS)
import CoreGraphics
import XCTest
@testable import LibreReverseCore

final class BrowserAXWindowResolverTests: XCTestCase {
    private let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)

    func testSameBoundsDoNotSubstituteNormalWindowForPrivateTitle() {
        let ordinary = BrowserAXWindowIdentity(title: "Ordinary - Google Chrome", bounds: bounds)
        let privateWindow = BrowserAXWindowIdentity(title: "Secret - Google Chrome (Incognito)", bounds: bounds)
        for candidates in [[ordinary, privateWindow], [privateWindow, ordinary]] {
            let index = BrowserAXWindowResolver.matchingIndex(
                title: privateWindow.title, bounds: bounds, candidates: candidates)
            XCTAssertEqual(index.map { candidates[$0] }, privateWindow)
        }
    }

    func testAmbiguousGeometryAndTitlesFailClosed() {
        let candidates = [
            BrowserAXWindowIdentity(title: "Same page", bounds: bounds),
            BrowserAXWindowIdentity(title: "Same page", bounds: bounds),
        ]
        for title in [nil, "", "Same page", "Unmatched WindowServer title"] as [String?] {
            XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
                title: title, bounds: bounds, candidates: candidates))
        }
    }

    func testMissingOrMovedWindowCannotFallBackToArrayOrder() {
        let candidate = BrowserAXWindowIdentity(title: "Other window", bounds: bounds)
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Other window",
            bounds: bounds.offsetBy(dx: 100, dy: 0), candidates: [candidate]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Missing window",
            bounds: nil, candidates: [candidate]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: nil,
            bounds: nil, candidates: [candidate]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Other window",
            bounds: bounds, candidates: []))
    }

    func testUniqueBoundsRemainUsableWithBrowserTitleSuffix() {
        let candidates = [
            BrowserAXWindowIdentity(title: "Page - Google Chrome", bounds: bounds),
            BrowserAXWindowIdentity(title: "Other - Google Chrome",
                bounds: bounds.offsetBy(dx: 50, dy: 50)),
        ]
        XCTAssertEqual(BrowserAXWindowResolver.matchingIndex(
            title: "Page", bounds: bounds, candidates: candidates), 0)
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: "", bounds: bounds, candidates: candidates))
    }

    func testMissingPrivateAXWindowCannotUseOrdinaryWindowAtSameBounds() {
        let ordinary = BrowserAXWindowIdentity(title: "Ordinary - Google Chrome", bounds: bounds)
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: "Secret - Google Chrome (Incognito)", bounds: bounds, candidates: [ordinary]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: "Secret", bounds: bounds, candidates: [ordinary]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Secret", bounds: bounds,
            candidates: [.init(title: nil, bounds: bounds)]))
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Project", bounds: bounds,
            candidates: [.init(title: "Project secrets - Google Chrome", bounds: bounds)]))
    }

    func testMultipleCompatibleBrowserSuffixesRemainAmbiguous() {
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(title: "Same page", bounds: bounds,
            candidates: [
                .init(title: "Same page - Google Chrome", bounds: bounds),
                .init(title: "Same page - Google Chrome (Incognito)", bounds: bounds),
            ]))
    }

    func testChromeTrailingAudioIndicatorUsesCompletePageTitle() {
        let title = "Meet - abc-defg-hij"
        let joined = BrowserAXWindowIdentity(
            title: title + " - Microphone recording - Google Chrome - Work", bounds: bounds)
        XCTAssertEqual(BrowserAXWindowResolver.matchingIndex(
            title: title + " 🔊", bounds: bounds, candidates: [joined]), 0)
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: title + " 🔊", bounds: bounds.offsetBy(dx: 1, dy: 0), candidates: [joined]))
        for incompatible in ["Meet - abc", title + " 🔊 extra", "🔊 " + title, " 🔊"] {
            XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
                title: incompatible, bounds: bounds, candidates: [joined]))
        }
    }

    func testAudioIndicatorNormalizationPreservesPrivateAndRawTitleAmbiguity() {
        let title = "Meet - abc-defg-hij"
        let ordinary = BrowserAXWindowIdentity(title: title + " - Google Chrome", bounds: bounds)
        let privateCopy = BrowserAXWindowIdentity(title: title + " - Google Chrome (Incognito)", bounds: bounds)
        let rawCopy = BrowserAXWindowIdentity(title: title + " 🔊 - Google Chrome", bounds: bounds)
        for sibling in [privateCopy, rawCopy] {
            for candidates in [[ordinary, sibling], [sibling, ordinary]] {
                XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
                    title: title + " 🔊", bounds: bounds, candidates: candidates))
            }
        }
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: "Secret 🔊", bounds: bounds, candidates: [ordinary]))
    }

    func testMissingGeometryRequiresUniqueNonemptyTitle() {
        let first = BrowserAXWindowIdentity(title: "Known", bounds: nil)
        XCTAssertEqual(BrowserAXWindowResolver.matchingIndex(
            title: "Known", bounds: nil, candidates: [first]), 0)
        XCTAssertNil(BrowserAXWindowResolver.matchingIndex(
            title: "Known", bounds: nil, candidates: [first, first]))
    }
}
#endif
