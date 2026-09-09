import AppKit
import QuartzCore
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineStaticGuideTests: XCTestCase {
    func testWaveformColumnsKeepTheSameMediaWindowsAcrossFractionalPans() {
        let pitch: CGFloat = 4
        // Different dirty/visible regions can omit leading columns, but their
        // overlapping columns keep the same segment-local sampling centers.
        func centers(_ minX: CGFloat) -> [CGFloat] {
            stride(from: LibreReverseTimelineWaveformColumns.firstCenter(visibleMinX: minX, pitch: pitch),
                   to: 50, by: pitch).map { $0 }
        }
        let full = centers(0)
        for edge: CGFloat in [0.25, 1.25, 3.7, 8.1, 15.9] {
            XCTAssertTrue(centers(edge).allSatisfy { full.contains($0) })
        }
    }

    func testGuideBackingSurvivesSelectionAndZoomButInvalidatesOnResize() throws {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(600),
            bundleID: "test.guide", rawID: 1, rawType: .capturedScreen)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [segment],
            validSeekInterval: DateInterval(start: start, duration: 600))
        let overlay = LibreReverseTimelineOverlayView(snapshot: snapshot, currentDate: start)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 116),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func renderPending() {
            overlay.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        renderPending()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let guide = try XCTUnwrap(descendants(overlay).first { $0.identifier?.rawValue == "timeline.staticGuide" })
        XCTAssertTrue(guide.wantsLayer)
        XCTAssertEqual(guide.layerContentsRedrawPolicy, .onSetNeedsDisplay)
        let frame = guide.frame
        let initialDraws = overlay.interactionTestStaticGuideDrawCount
        XCTAssertGreaterThan(initialDraws, 0, "A hosted guide must have actually rendered before testing retention")
        overlay.currentDate = start.addingTimeInterval(20)
        renderPending()
        XCTAssertEqual(guide.frame, frame)
        XCTAssertEqual(overlay.interactionTestStaticGuideDrawCount, initialDraws,
            "Changing selection must reuse the rendered guide backing")
        overlay.setZoomLevel(overlay.zoomLevel + 10)
        renderPending()
        XCTAssertEqual(overlay.interactionTestStaticGuideDrawCount, initialDraws,
            "Zoom redraws the ruler, not the invariant white guide")
        guide.viewDidChangeBackingProperties()
        renderPending()
        let backingChangeDraws = overlay.interactionTestStaticGuideDrawCount
        XCTAssertGreaterThan(backingChangeDraws, initialDraws,
            "A display backing change must actually regenerate the guide pixels")
        window.setContentSize(NSSize(width: 1300, height: 116))
        renderPending()
        XCTAssertNotEqual(guide.frame, frame)
        XCTAssertGreaterThan(overlay.interactionTestStaticGuideDrawCount, backingChangeDraws,
            "Viewport resize must actually repaint the guide")
    }
}
