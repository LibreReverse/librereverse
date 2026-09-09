#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class LibreReverseTimelineGlassTests: XCTestCase {
    func testEmptyGlassPassesInputToOverlayIncludingAtNonzeroOrigin() {
        let (window, overlay, glass) = makeSurface()
        defer { window.orderOut(nil) }
        let emptyPoint = NSPoint(x: glass.frame.midX, y: glass.frame.midY)
        XCTAssertNil(glass.hitTest(emptyPoint))
        XCTAssertTrue(overlay.hitTest(emptyPoint) === overlay)
        XCTAssertNil(glass.hitTest(NSPoint(x: glass.frame.minX - 1, y: glass.frame.midY)))
    }

    func testNestedNativeButtonReceivesInputAndRetainsItsAction() throws {
        let (window, overlay, glass) = makeSurface()
        defer { window.orderOut(nil) }
        let container = NSView(frame: NSRect(x: 83, y: 9, width: 150, height: 50))
        let target = ClickTarget()
        let button = NSButton(title: "Open meeting", target: target, action: #selector(ClickTarget.clicked(_:)))
        button.frame = NSRect(x: 11, y: 7, width: 110, height: 28)
        container.addSubview(button)
        glass.contentView.addSubview(container)
        overlay.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: overlay)
        let hit = try XCTUnwrap(overlay.hitTest(point) as? NSButton)
        XCTAssertTrue(hit === button)
        hit.performClick(nil)
        XCTAssertEqual(target.clicks, 1)
        glass.isHidden = true
        XCTAssertTrue(overlay.hitTest(point) === overlay)
    }

    func testContentCoordinatesTrackRepeatedResizeWithoutReplacingDescendants() {
        let (window, overlay, glass) = makeSurface()
        defer { window.orderOut(nil) }
        let content = glass.contentView
        let marker = NSView(frame: NSRect(x: 19, y: 13, width: 40, height: 20))
        content.addSubview(marker)
        for size in [NSSize(width: 740, height: 76), NSSize(width: 310, height: 90), NSSize(width: 600, height: 68)] {
            glass.setFrameSize(size)
            glass.needsLayout = true
            overlay.layoutSubtreeIfNeeded()
            XCTAssertTrue(glass.contentView === content)
            XCTAssertTrue(marker.superview === content)
            XCTAssertEqual(content.bounds.size.width, size.width, accuracy: 0.01)
            XCTAssertEqual(content.bounds.size.height, size.height, accuracy: 0.01)
            let origin = content.convert(content.bounds.origin, to: glass)
            XCTAssertEqual(origin.x, glass.bounds.minX, accuracy: 0.01)
            XCTAssertEqual(origin.y, glass.bounds.minY, accuracy: 0.01)
            XCTAssertEqual(marker.frame, NSRect(x: 19, y: 13, width: 40, height: 20))
        }
    }

    private func makeSurface() -> (NSWindow, NSView, LibreReverseTimelineGlassView) {
        _ = NSApplication.shared
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 300))
        let window = NSWindow(contentRect: overlay.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = overlay
        let glass = LibreReverseTimelineGlassView(frame: NSRect(x: 37, y: 29, width: 600, height: 68))
        glass.appearance = NSAppearance(named: .darkAqua)
        overlay.addSubview(glass)
        overlay.layoutSubtreeIfNeeded()
        return (window, overlay, glass)
    }
}

@MainActor
private final class ClickTarget: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: NSButton) { clicks += 1 }
}
#endif
