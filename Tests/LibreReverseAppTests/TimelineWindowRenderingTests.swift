import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineWindowRenderingTests: XCTestCase {
    func testReplacingPageWithSameItemCountRebindsVisibleHistory() async throws {
        _ = NSApplication.shared
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        func snapshot(firstID: Int64) -> LibreReverseTimelineSnapshot {
            .init(rawSegments: (0..<6).map { index in
                .init(startDate: origin.addingTimeInterval(Double(index) * 10),
                      endDate: origin.addingTimeInterval(Double(index + 1) * 10),
                      bundleID: "app.\(index)", rawID: firstID + Int64(index), rawType: .capturedScreen)
            })
        }
        let view = LibreReverseTimelineOverlayView(snapshot: snapshot(firstID: 1), currentDate: origin.addingTimeInterval(30))
        let window = NSWindow(contentRect: .init(x: -3000, y: -3000, width: 1200, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(view.interactionTestVisibleGroupIDs.isEmpty)
        view.snapshot = snapshot(firstID: 101)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        for (index, ids) in view.interactionTestVisibleGroupIDs {
            XCTAssertEqual(ids, [101 + Int64(index)], "A reused cell must bind to the new page before any scroll or selection change")
        }
    }
}
