import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

/// Observe native item coordinates, not a copy of the projection formula. A
/// saved star at the selected instant must stay beneath the fixed playhead.
@MainActor
final class TimelineAnchorProjectionTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }

    private var segments: [TimelineSegment] {
        [segment(0, 600, 1), segment(900, 960, 2, .audio), segment(1200, 1800, 3)]
    }

    private func segment(_ from: Double, _ to: Double, _ id: Int64,
                         _ type: SegmentType = .capturedScreen) -> TimelineSegment {
        .init(startDate: date(from), endDate: date(to), bundleID: "test.app.\(id)",
              rawID: id, rawType: type)
    }

    private func snapshot(selected: Date, playback: Bool,
                          segments: [TimelineSegment]? = nil) -> LibreReverseTimelineSnapshot {
        .init(rawSegments: segments ?? self.segments,
              validSeekInterval: DateInterval(start: date(-600), end: date(2000)),
              starredDates: [selected],
              playbackFrameDates: playback ? [-600.0, 0, 120, 300, 600, 900, 960, 1200, 1500, 1800, 2000].map(date) : nil)
    }

    private func host(_ snapshot: LibreReverseTimelineSnapshot, selected: Date) ->
        (LibreReverseTimelineOverlayView, NSWindow) {
        _ = NSApplication.shared
        let overlay = LibreReverseTimelineOverlayView(snapshot: snapshot, currentDate: selected)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1200, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        window.orderFront(nil)
        overlay.layoutSubtreeIfNeeded()
        return (overlay, window)
    }

    private func collection(in view: NSView) -> NSCollectionView? {
        if let collection = view as? NSCollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }

    private func assertAnchored(_ overlay: LibreReverseTimelineOverlayView, selected: Date,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        overlay.layoutSubtreeIfNeeded()
        let collection = try XCTUnwrap(collection(in: overlay), file: file, line: line)
        let scroll = try XCTUnwrap(collection.enclosingScrollView, file: file, line: line)
        let star = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 2)), file: file, line: line)
        XCTAssertEqual(overlay.currentDate, selected, file: file, line: line)
        XCTAssertEqual(star.frame.midX, floor(scroll.frame.width / 2), accuracy: 0.001,
                       "The selected instant moved away from the fixed playhead", file: file, line: line)
        let selectedX = collection.convert(NSPoint(x: star.frame.midX, y: 0), to: overlay).x
        XCTAssertEqual(selectedX,
                       MemoryExplorerVisualShell.playheadFrame(viewportWidth: overlay.bounds.width).midX,
                       accuracy: 0.51,
                       "Reparenting into glass must preserve the selected marker's screen coordinate", file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 0.001,
                       "Native scrolling must not become a second navigation owner", file: file, line: line)
    }

    func testPinnedAppIdentityStaysPixelStableAcrossFractionalScrollAndRedrawsOnTranslation() throws {
        let selected = date(300)
        let fixture = LibreReverseTimelineSnapshot(rawSegments: [segment(0, 600, 1)],
            validSeekInterval: .init(start: date(0), end: date(600)))
        let (overlay, window) = host(fixture, selected: selected)
        defer { window.orderOut(nil) }
        overlay.setZoomLevel(100)
        overlay.layoutSubtreeIfNeeded()
        let collection = try XCTUnwrap(collection(in: overlay))
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)))
        let originalFrame = item.view.frame
        XCTAssertLessThan(originalFrame.minX, 0, "The fixture must pin the identity of a left-clipped app run")
        let pinned = try XCTUnwrap(overlay.interactionTestAppIdentityFrames[0])

        // AppKit can translate a retained collection item without laying out
        // its contents. Its pinned icon needs a new local x and fresh backing
        // pixels even though the item size and model are unchanged.
        for delta: CGFloat in [0.125, 0.375, 0.625, 1.125, 0.25, 0] {
            item.view.needsDisplay = false
            let next = originalFrame.offsetBy(dx: -delta, dy: 0)
            let changed = item.view.frame != next
            item.view.frame = next
            if changed {
                XCTAssertTrue(item.view.needsDisplay,
                    "Position-only updates must not translate a stale bitmap of a pinned app identity")
            }
            let icon = try XCTUnwrap(overlay.interactionTestAppIdentityFrames[0])
            XCTAssertEqual(icon.minX, pinned.minX, accuracy: 0.0001)
            XCTAssertEqual(icon.minY, pinned.minY, accuracy: 0.0001)
        }

        var seeks: [TimelineSeekRequest] = []
        overlay.onSeekRequest = { seeks.append($0) }
        for step in 1...32 {
            overlay.currentDate = date(300 + Double(step) * 0.013)
            overlay.layoutSubtreeIfNeeded()
            let retained = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)))
            XCTAssertTrue(retained === item, "Scrolling within an app run should reuse its identity")
            let icon = try XCTUnwrap(overlay.interactionTestAppIdentityFrames[0])
            XCTAssertEqual(icon.minX, pinned.minX, accuracy: 0.0001)
            XCTAssertEqual(icon.minY, pinned.minY, accuracy: 0.0001)
        }
        XCTAssertTrue(seeks.isEmpty)
    }

    func testZoomAndResizePreserveSelectedInstantAtBothHistoryEndsAndMeetingInterior() throws {
        for playback in [false, true] {
            for second in [0.0, 240, 930, 1800] {
                let selected = date(second)
                let (overlay, window) = host(snapshot(selected: selected, playback: playback), selected: selected)
                defer { window.orderOut(nil) }
                overlay.playbackPresentationEnabled = playback
                overlay.isPinnedToEnd = second == 1800
                var seeks: [TimelineSeekRequest] = []
                overlay.onSeekRequest = { seeks.append($0) }
                for width in [1200.0, 800, 1500] {
                    window.setContentSize(NSSize(width: width, height: 260))
                    for zoom: Float in [0, 35, 60, 100, 20, 60] {
                        overlay.setZoomLevel(zoom)
                        try assertAnchored(overlay, selected: selected)
                        XCTAssertEqual(overlay.isPinnedToEnd, second == 1800)
                    }
                }
                XCTAssertTrue(seeks.isEmpty, "Zoom/layout must never emit a seek or restart media resolution")
            }
        }
    }

    func testNavigationAndPlaybackProjectionSwitchRebasesTheSameWallDate() throws {
        let selected = date(930)
        let navigation = snapshot(selected: selected, playback: false)
        let playback = snapshot(selected: selected, playback: true)
        XCTAssertNotEqual(navigation.contiguousOffset(atWallDate: selected),
                          playback.contiguousOffset(atWallDate: selected), "Fixture must exercise different axes")
        let (overlay, window) = host(navigation, selected: selected)
        defer { window.orderOut(nil) }
        var seeks: [TimelineSeekRequest] = []
        overlay.onSeekRequest = { seeks.append($0) }
        for mode in [true, false, true, false] {
            overlay.currentOffsetOverride = overlay.snapshot.contiguousOffset(atWallDate: selected)
            overlay.playbackPresentationEnabled = mode
            overlay.snapshot = mode ? playback : navigation
            try assertAnchored(overlay, selected: selected)
            XCTAssertEqual(overlay.currentOffsetOverride, overlay.snapshot.contiguousOffset(atWallDate: selected))
        }
        XCTAssertTrue(seeks.isEmpty)
    }

    func testPrependingHistoryRebasesGestureOffsetWithoutMovingSelection() throws {
        let selected = date(930)
        let initial = snapshot(selected: selected, playback: true)
        let expanded = snapshot(selected: selected, playback: true,
                                segments: [segment(-600, -1, 4)] + segments)
        let oldOffset = try XCTUnwrap(initial.contiguousOffset(atWallDate: selected))
        let newOffset = try XCTUnwrap(expanded.contiguousOffset(atWallDate: selected))
        XCTAssertGreaterThan(newOffset, oldOffset)
        let (overlay, window) = host(initial, selected: selected)
        defer { window.orderOut(nil) }
        overlay.playbackPresentationEnabled = true
        overlay.currentOffsetOverride = oldOffset
        overlay.snapshot = expanded
        try assertAnchored(overlay, selected: selected)
        XCTAssertEqual(overlay.currentOffsetOverride, newOffset)
    }

    func testLiveAdmissionKeepsStationaryHistoricalSelectionAnchored() throws {
        let selected = date(240)
        let initial = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(
            segments: segments, validSeekInterval: .init(start: date(0), end: date(1800)),
            playbackFrameDates: [date(0), date(120), date(300), date(600), date(1200), date(1800)]),
            starredDates: [selected]))
        let (overlay, window) = host(initial.snapshot, selected: selected)
        defer { window.orderOut(nil) }
        overlay.playbackPresentationEnabled = true
        overlay.isPinnedToEnd = false
        let extended = initial.appending(admittedFrame: .init(id: 999, segmentID: 3,
            segment: segment(1200, 2200, 3), createdAt: date(2200),
            imageFileName: "", context: nil, encodingStatus: "pending"),
            starredDates: [selected], retaining: selected)
        overlay.snapshot = extended.snapshot
        try assertAnchored(overlay, selected: selected)
        XCTAssertEqual(extended.interval.end, date(2200))
        XCTAssertFalse(overlay.isPinnedToEnd)
    }

    func testExplicitGlobalBoundaryDoesNotRewriteRetainedSegmentGeometry() throws {
        // A mismatched/stale publication can supply a newer segment with an
        // older global boundary. Drawing may clip it; navigation must retain
        // the original axis rather than shortening the underlying record.
        let latest = date(600)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [segment(0, 900, 1)],
            validSeekInterval: .init(start: date(0), end: latest),
            starredDates: [latest, date(800)])
        XCTAssertEqual(snapshot.validSeekInterval?.end, latest)
        XCTAssertEqual(snapshot.processedScreenshotSegments.first?.endDate, date(900))
        XCTAssertEqual(snapshot.contiguousDuration, 900)
        XCTAssertEqual(snapshot.contiguousOffset(atWallDate: latest), 600)
        XCTAssertEqual(snapshot.starredFrames.map(\.date), [latest],
                       "Stars outside the published seek interval remain excluded")
        let (overlay, window) = host(snapshot, selected: latest)
        defer { window.orderOut(nil) }
        overlay.latestCapturedDate = latest
        try assertAnchored(overlay, selected: latest)
        let collection = try XCTUnwrap(collection(in: overlay))
        let app = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 0)))
        let star = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(
            at: IndexPath(item: 0, section: 2)))
        XCTAssertGreaterThan(app.frame.maxX, star.frame.midX,
                             "Clipping future ink must not change item geometry or the hit-testing axis")
    }

    func testStarAccessiblePressSeeksItsExactSavedInstant() throws {
        let selected = date(930.125)
        let (overlay, window) = host(snapshot(selected: selected, playback: true), selected: date(920))
        defer { window.orderOut(nil) }
        overlay.playbackPresentationEnabled = true
        overlay.layoutSubtreeIfNeeded()
        var requests: [TimelineSeekRequest] = []
        overlay.onSeekRequest = { requests.append($0) }
        let collection = try XCTUnwrap(collection(in: overlay))
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 2)))
        XCTAssertTrue(item.view.accessibilityPerformPress())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.date, selected,
                       "The star must open its saved instant, including fractional seconds")
        XCTAssertEqual(requests.first?.source, .click)
    }

    func testRulerClickTraversesGlassHitPathAndSeeksProjectedTime() throws {
        let selected = date(930)
        let (overlay, window) = host(snapshot(selected: selected, playback: true), selected: selected)
        defer { window.orderOut(nil) }
        overlay.playbackPresentationEnabled = true
        overlay.latestCapturedDate = date(940)
        overlay.layoutSubtreeIfNeeded()
        var requests: [TimelineSeekRequest] = []
        overlay.onSeekRequest = { requests.append($0) }
        let belt = MemoryExplorerVisualShell.timelineShellFrame(viewportWidth: overlay.bounds.width)
        let scale = LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: overlay.zoomLevel)
        // The ruler lies below collection items. Dispatch to the native hit
        // view, allowing the glass/content responder chain to deliver it.
        for (delta, expected) in [(6.0, 936.0), (16.0, 940.0)] {
            requests.removeAll()
            let point = NSPoint(x: floor(belt.midX) + delta * scale, y: belt.minY + 8)
            XCTAssertTrue(belt.contains(point))
            let hit = try XCTUnwrap(overlay.hitTest(overlay.convert(point, to: overlay.superview)))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
            hit.mouseDown(with: event)
            XCTAssertEqual(requests.count, 1, "An empty ruler hit must reach the overlay through native glass")
            XCTAssertEqual(requests.first?.source, .click)
            let sought = try XCTUnwrap(requests.first?.date)
            XCTAssertEqual(sought.timeIntervalSince(date(expected)), 0, accuracy: 0.001,
                           "Ruler clicks use the current projection and clamp at the latest published moment")
        }
    }

    func testZoomChangesDistanceOfOtherMomentsWhileSelectedMomentStaysFixed() throws {
        let selected = date(920)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: segments,
            starredDates: [selected, date(930)], playbackFrameDates: [date(0), date(600), date(1800)])
        let (overlay, window) = host(snapshot, selected: selected)
        defer { window.orderOut(nil) }
        overlay.playbackPresentationEnabled = true
        let collection = try XCTUnwrap(collection(in: overlay))
        var distances: [CGFloat] = []
        for zoom: Float in [40, 50, 60] {
            overlay.setZoomLevel(zoom)
            try assertAnchored(overlay, selected: selected)
            let first = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 0, section: 2)))
            let second = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 1, section: 2)))
            distances.append(second.frame.midX - first.frame.midX)
        }
        XCTAssertGreaterThan(distances[0], 0)
        XCTAssertEqual(distances[1] / distances[0], 2, accuracy: 0.001)
        XCTAssertEqual(distances[2] / distances[1], 2, accuracy: 0.001)
    }
}
