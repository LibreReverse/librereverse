import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineBoundaryDrawingTests: XCTestCase {
    func testLiveSelectionBeforeLayoutAndDuringNarrowResizingDefersNowAccessibility() throws {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = start.addingTimeInterval(4)
        let segment = TimelineSegment(startDate: start, endDate: latest,
            bundleID: "test.capture", rawID: 1, rawType: .capturedScreen)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [segment],
            validSeekInterval: .init(start: start, end: latest))
        let overlay = LibreReverseTimelineOverlayView(snapshot: snapshot, currentDate: latest)
        func nowAction() -> NSAccessibilityElement? {
            overlay.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
                .first { $0.accessibilityLabel() == "Jump to Now" }
        }
        // showLiveFrame publishes latest date/selection before the window's
        // first layout. This sequence previously trapped building a range.
        overlay.latestCapturedDate = latest
        for width: CGFloat in [0, 1, 100, 300, 390, 405] {
            overlay.frame = NSRect(x: 0, y: 0, width: width, height: 116)
            overlay.selectedSegmentIDs = [1]
            XCTAssertNil(nowAction(), "Do not expose an offscreen control before it fits")
        }
        overlay.frame = NSRect(x: 0, y: 0, width: 1200, height: 116)
        overlay.selectedSegmentIDs = [1]
        var activated = false
        overlay.onJumpToNow = { activated = true }
        let action = try XCTUnwrap(nowAction())
        XCTAssertTrue(action.accessibilityPerformPress())
        XCTAssertTrue(activated, "Normal layout restores the actual Now action")
        overlay.frame = .zero
        overlay.selectedSegmentIDs = [1]
        XCTAssertNil(nowAction(), "Resizing back to a collapsed view must also be safe")
    }

    func testMeetingWaveformStopsAtPublishedBoundaryWithoutChangingItsRecordOrAction() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(4),
            bundleID: "test.meeting", contiguousStartOffset: 0, contiguousEndOffset: 4,
            windowName: "Boundary proof", rawID: 12, rawType: .audio)
        let view = LibreReverseAudioSegmentDrawingView(frame: NSRect(x: 0, y: 0, width: 400, height: 52))
        var openedID: Int64?
        view.presentation = .init(segment: segment, selected: false,
            waveform: .init(duration: 4, binDuration: 1, peaks: Data([255, 255, 255, 255])),
            lastVisibleOffset: 2, wallDateAtOffset: { start.addingTimeInterval($0) },
            onClick: { _, id in openedID = id })
        try assertInkStopsAtMiddle(view)
        XCTAssertEqual(view.presentation?.segment, segment)
        XCTAssertEqual(view.bounds.width, 400)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(openedID, 12)
    }

    func testAppDotsStopAtPublishedBoundary() throws {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(4)
        let latest = start.addingTimeInterval(2)
        let segment = TimelineSegment(startDate: start, endDate: end, bundleID: "test.capture",
                                      rawID: 1, rawType: .capturedScreen)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [segment],
                                                    validSeekInterval: .init(start: start, end: latest))
        let overlay = LibreReverseTimelineOverlayView(snapshot: snapshot, currentDate: latest)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        overlay.latestCapturedDate = latest
        overlay.layoutSubtreeIfNeeded()
        func findCollection(_ view: NSView) -> NSCollectionView? {
            if let result = view as? NSCollectionView { return result }
            for child in view.subviews { if let result = findCollection(child) { return result } }
            return nil
        }
        let collection = try XCTUnwrap(findCollection(overlay))
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)))
        try assertInkStopsAtMiddle(item.view)
        XCTAssertEqual(overlay.snapshot.processedScreenshotSegments.first?.endDate, end)
    }

    func testRulerReservesOffscreenNowActionEvenWhenLatestDateIsBeyondViewport() {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let timeSize = ("09:39:55" as NSString).size(withAttributes: [.font: font])
        let nowSize = ("NOW ›" as NSString).size(withAttributes: [.font: font])
        let now = NSRect(x: 1130 - nowSize.width, y: 30, width: nowSize.width, height: 12)
        let collidingTime = NSRect(x: 1100 - timeSize.width / 2, y: 31,
                                   width: timeSize.width, height: timeSize.height)
        XCTAssertFalse(LibreReverseTimelineOverlayView.rulerLabelAvoidsNow(collidingTime, nowLabelRect: now))
        XCTAssertTrue(LibreReverseTimelineOverlayView.rulerLabelAvoidsNow(collidingTime.offsetBy(dx: -90, dy: 0), nowLabelRect: now))
        XCTAssertTrue(LibreReverseTimelineOverlayView.rulerLabelAvoidsNow(collidingTime, nowLabelRect: nil))
    }

    private func assertInkStopsAtMiddle(_ view: NSView,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.black.setFill()
        view.bounds.fill()
        view.draw(view.bounds)
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var earlierInk = 0
        var laterInk = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      max(color.redComponent, color.greenComponent, color.blueComponent) > 0.05 else { continue }
                if x < bitmap.pixelsWide / 2 { earlierInk += 1 }
                if x > bitmap.pixelsWide / 2 + 2 { laterInk += 1 }
            }
        }
        XCTAssertGreaterThan(earlierInk, 0, "Real content before Now must remain visible", file: file, line: line)
        XCTAssertEqual(laterInk, 0, "App dots, waveform, labels, and gates must not paint after Now", file: file, line: line)
    }

}
