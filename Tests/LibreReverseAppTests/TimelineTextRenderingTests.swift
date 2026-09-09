import AppKit
import CoreText
import QuartzCore
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineTextRenderingTests: XCTestCase {
    func testNativeRunsPreserveMetricsAndOwnFontAcrossPoolDrainsAndEviction() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let renderer = LibreReverseTimelineText(font: font, color: .white, capacity: 16)
        let retained = autoreleasepool { renderer.run(for: "09:39:24") }
        XCTAssertTrue(retained.line === renderer.run(for: "09:39:24").line)
        let originalSize = ("09:39:24" as NSString).size(withAttributes: [.font: font])
        XCTAssertEqual(retained.size.width, originalSize.width, accuracy: 0.1)
        XCTAssertEqual(retained.size.height, originalSize.height, accuracy: 1)
        let attributes = CFAttributedStringGetAttributes(retained.attributedString, 0, nil) as NSDictionary
        let nativeFont = try XCTUnwrap(attributes[kCTFontAttributeName] as AnyObject?)
        XCTAssertEqual(CFGetTypeID(nativeFont), CTFontGetTypeID())

        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 40,
            bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for cycle in 0..<100 {
            autoreleasepool {
                for second in 0..<100 {
                    let text = String(format: "%02d:%02d:%02d", cycle % 24, second % 60, second)
                    let run = renderer.run(for: text)
                    XCTAssertGreaterThan(run.size.width, 0)
                    run.draw(at: NSPoint(x: 2, y: 2), in: context)
                    XCTAssertLessThanOrEqual(renderer.cachedRunCount, 16)
                }
            }
        }
        // The run remains drawable after its cache entry and all transient pools are gone.
        context.clear(CGRect(x: 0, y: 0, width: 200, height: 40))
        retained.draw(at: NSPoint(x: 2, y: 2), in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue(stride(from: 3, to: 800 * 40, by: 4).contains { bytes[$0] > 0 })
    }

    func testLocalizedAndEmptyLabelsProduceFiniteMetrics() {
        let renderer = LibreReverseTimelineText(font: .systemFont(ofSize: 11), color: .white)
        for text in ["", "NOW ›", "—:—:—", "٢١:٣٩:٢٤", "6 SEPT. 2026", "2026年9月6日"] {
            let run = renderer.run(for: text)
            XCTAssertTrue(run.size.width.isFinite)
            XCTAssertTrue(run.size.height.isFinite)
            XCTAssertEqual(CFAttributedStringGetLength(run.attributedString), text.utf16.count)
        }
    }

    func testHostedMeetingTimelineRedrawsAcrossPlaybackZoomResizeAndPoolDrains() {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segments = [
            TimelineSegment(startDate: start, endDate: start.addingTimeInterval(3600),
                bundleID: "test.capture", rawID: 1, rawType: .capturedScreen),
            TimelineSegment(startDate: start.addingTimeInterval(60), endDate: start.addingTimeInterval(3500),
                bundleID: "test.meeting", rawID: 2, rawType: .audio),
        ]
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: segments,
            validSeekInterval: DateInterval(start: start, duration: 3600))
        let overlay = LibreReverseTimelineOverlayView(snapshot: snapshot, currentDate: start)
        overlay.latestCapturedDate = start.addingTimeInterval(3600)
        overlay.playbackIsAdvancing = true
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 116),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let initialDraws = overlay.interactionTestRulerDrawCount
        let zoom = overlay.zoomLevel
        for frame in 0..<600 {
            autoreleasepool {
                overlay.currentDate = start.addingTimeInterval(Double(frame) * 5.7)
                if frame % 20 == 0 { overlay.setZoomLevel(zoom + Float((frame / 20) % 4) * 10) }
                if frame % 50 == 0 { window.setContentSize(NSSize(width: frame % 100 == 0 ? 1200 : 1400, height: 116)) }
                overlay.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
            }
        }
        XCTAssertGreaterThanOrEqual(overlay.interactionTestRulerDrawCount - initialDraws, 590,
            "Stress must execute the hosted ruler draw path, not just change its model")
    }
}
