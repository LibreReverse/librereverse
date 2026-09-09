import AppKit
import AVFoundation
import XCTest
@testable import LibreReverseApp

@MainActor
final class PlayerLayerReadinessTests: XCTestCase {
    func testSeekCompletionDoesNotPublishUntilLayerHasPixels() {
        let view = LibreReversePlayerLayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.interactionTestReadyForDisplay = false
        let first = view.prepare(player: AVPlayer())
        view.complete(first)
        XCTAssertEqual(view.alphaValue, 0)
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 0)
        view.interactionTestReadyForDisplay = true
        view.interactionTestPublishReadySurface()
        XCTAssertEqual(view.alphaValue, 1)
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 1)
    }

    func testReusedPendingPlayerRequiresTheNewSeekToComplete() {
        let view = LibreReversePlayerLayerView(frame: .zero)
        let player = AVPlayer()
        view.interactionTestReadyForDisplay = false
        let original = view.prepare(player: player)
        view.complete(original)
        let reused = view.pendingPresentation(for: player)
        XCTAssertNotNil(reused)
        view.interactionTestReadyForDisplay = true
        view.interactionTestPublishReadySurface()
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 0)
        if let reused { view.complete(reused) }
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 1)
        view.clear()
        XCTAssertEqual(view.alphaValue, 0, "Clearing must not leave the empty player backdrop over a retained still")
    }

    func testSupersededAndClearedTransitionsCannotRemoveReadyFallback() {
        let view = LibreReversePlayerLayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.interactionTestReadyForDisplay = true
        view.complete(view.prepare(player: AVPlayer()))
        view.interactionTestReadyForDisplay = false
        let superseded = view.prepare(player: AVPlayer())
        view.complete(superseded)
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 1)
        let current = view.prepare(player: AVPlayer())
        view.complete(superseded)
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 1)
        // One background plus one ready outgoing host and one pending host.
        XCTAssertEqual(view.subviews.count, 3)
        view.complete(current)
        view.interactionTestReadyForDisplay = true
        view.interactionTestPublishReadySurface()
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 1)
        XCTAssertEqual(view.subviews.count, 2)
        view.clear()
        view.complete(current)
        view.interactionTestPublishReadySurface()
        XCTAssertEqual(view.interactionTestVisibleSurfaceCount, 0)
        XCTAssertEqual(view.subviews.count, 1)
    }
}
