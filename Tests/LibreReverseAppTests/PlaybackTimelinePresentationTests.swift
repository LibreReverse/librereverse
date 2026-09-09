import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class PlaybackTimelinePresentationTests: XCTestCase {
    func testPrefetchUsesVisiblePlaybackDistanceBeforeTheCursorReachesAnEdge() throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        func date(_ value: Double) -> Date { origin.addingTimeInterval(value) }
        let segment = TimelineSegment(startDate: date(100), endDate: date(1100),
            bundleID: "screen", rawID: 1, rawType: .capturedScreen)
        let dates = stride(from: 100.0, through: 1100.0, by: 10).map(date)
        let presentation = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(
            segments: [segment], validSeekInterval: .init(start: date(0), end: date(1200)), playbackFrameDates: dates)))
        XCTAssertTrue(presentation.contains(date(110)))
        XCTAssertTrue(presentation.needsMoreHistory(around: date(110), padding: 5))
        XCTAssertTrue(presentation.needsMoreHistory(around: date(1090), padding: 5))
        XCTAssertFalse(presentation.needsMoreHistory(around: date(600), padding: 5))
        let complete = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(
            segments: [segment], validSeekInterval: .init(start: date(100), end: date(1100)), playbackFrameDates: dates)))
        XCTAssertFalse(complete.needsMoreHistory(around: date(110), padding: 5))
        XCTAssertFalse(complete.needsMoreHistory(around: date(1090), padding: 5))
    }

    func testPlaybackGeometryMovesAtEqualSpeedAndNavigationRestoresExactly() throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        let segments: [TimelineSegment] = [
            .init(startDate: date(0), endDate: date(600), bundleID: "screen", rawID: 1, rawType: .capturedScreen),
            .init(startDate: date(600), endDate: date(660), bundleID: "meeting", rawID: 2, rawType: .audio),
            .init(startDate: date(660), endDate: date(5000), bundleID: "screen", rawID: 3, rawType: .capturedScreen)
        ]
        let navigation = LibreReverseTimelineSnapshot(rawSegments: segments)
        let presentation = try XCTUnwrap(PlaybackTimelinePresentation(window: .init(
            segments: segments, validSeekInterval: navigation.validSeekInterval,
            playbackFrameDates: [date(0), date(600), date(900), date(5000)])))
        let view = LibreReverseTimelineOverlayView(snapshot: navigation, currentDate: date(600))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 1200, height: 220),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func collection(in node: NSView) -> NSCollectionView? {
            (node as? NSCollectionView) ?? node.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let layout = try XCTUnwrap(collection(in: view)?.collectionViewLayout)
        func position(_ seconds: Double) throws -> Double {
            view.currentDate = date(seconds)
            view.layoutSubtreeIfNeeded()
            return try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1))).frame.minX
        }
        let originalX = try position(600)
        view.playbackPresentationEnabled = true
        view.snapshot = presentation.snapshot
        let duringMeeting = try position(601) - position(600)
        let afterMeeting = try position(900) - position(660)
        XCTAssertEqual(duringMeeting, -24, accuracy: 1)
        XCTAssertEqual(afterMeeting, -6, accuracy: 1)
        view.setZoomLevel(70)
        XCTAssertEqual(try position(601) - position(600), -48, accuracy: 0.01)
        view.setZoomLevel(50)
        XCTAssertEqual(try position(601) - position(600), -12, accuracy: 0.01)
        view.setZoomLevel(60)
        view.playbackIsAdvancing = true
        _ = try position(601)
        let forward = try position(601.01)
        XCTAssertEqual(try position(601.005), forward, accuracy: 0.0001)
        view.playbackIsAdvancing = false
        XCTAssertGreaterThan(try position(600), forward)
        // The four-minute frame gap consumes one 0.25-second playback beat.
        // Restoring manual navigation recovers the exact prior geometry and units.
        view.playbackPresentationEnabled = false
        view.snapshot = navigation
        XCTAssertEqual(try position(600), originalX, accuracy: 0.001)
        XCTAssertEqual(navigation.contiguousDuration, 5000)
        XCTAssertEqual(navigation.contiguousOffset(atWallDate: date(900)), 900)
        XCTAssertTrue(presentation.contains(date(5000)))
        XCTAssertFalse(presentation.contains(date(5001)))
    }

    func testAppRunsCombineDifferentSitesButPreserveTheirDestinations() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let segments: [TimelineSegment] = [
            .init(startDate: start, endDate: start.addingTimeInterval(10), bundleID: "com.google.Chrome",
                browserURL: "https://one.example/page", rawID: 1, rawType: .capturedScreen),
            .init(startDate: start.addingTimeInterval(10), endDate: start.addingTimeInterval(20), bundleID: "com.google.Chrome",
                browserURL: "https://two.example/page", rawID: 2, rawType: .capturedScreen),
            .init(startDate: start.addingTimeInterval(20), endDate: start.addingTimeInterval(30), bundleID: "editor",
                rawID: 3, rawType: .capturedScreen)
        ]
        let groups = LibreReverseTimelinePresentationPolicy.appGroups(segments)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].segments.map(\.browserURL), ["https://one.example/page", "https://two.example/page"])
        XCTAssertEqual(groups[1].segments.map(\.rawID), [3])
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: segments)
        for (seconds, url) in [(5.0, "https://one.example/page"), (15.0, "https://two.example/page")] {
            let context = try XCTUnwrap(LibreReverseTimelineContextResolver.selectedContext(in: snapshot,
                selectedSegmentIDs: [], at: start.addingTimeInterval(seconds)))
            XCTAssertEqual(context.openAction?.url.absoluteString, url)
        }
    }
}
