#if os(macOS)
import CoreGraphics
import XCTest
@testable import LibreReverseCore

final class LiveTextContractTests: XCTestCase {
    func testRecoveredAnalysisDelays() {
        XCTAssertEqual(LiveTextContract.fullFrameDelayMilliseconds, 500)
    }

    func testRuntimeRecoveredAreaPresentationConstants() {
        XCTAssertEqual(LiveTextContract.areaCornerRadius, 16)
        XCTAssertEqual(LiveTextContract.areaBackgroundOpacity, 0.5)
        XCTAssertEqual(LiveTextContract.maximumAreaZoom, 2)
        XCTAssertEqual(LiveTextContract.dismissAnimationDuration, 0.2)
        XCTAssertEqual(LiveTextContract.overlayPaddingTop, 75)
        XCTAssertEqual(LiveTextContract.overlayPaddingLeading, 75)
        XCTAssertEqual(LiveTextContract.overlayPaddingBottom, 75)
        XCTAssertEqual(LiveTextContract.overlayPaddingTrailing, 50)
        XCTAssertEqual(LiveTextContract.springResponse, 0.33)
        XCTAssertEqual(LiveTextContract.springDampingFraction, 0.9)
        XCTAssertEqual(LiveTextContract.imageBackgroundOpacity, 0.4)
        XCTAssertEqual(LiveTextContract.resultBannerGap, 16)
        XCTAssertEqual(LiveTextContract.resultBannerHeight, 33)
        XCTAssertTrue(LiveTextContract.allowsEveryNativeInteraction)
    }

    func testAreaOverlayUsesIndependentCapsRecoveredFromRuntimeSample() {
        let frame = LiveTextContract.areaOverlayFrame(
            selectionRect: CGRect(x: 400, y: 362, width: 330, height: 220),
            availableSize: CGSize(width: 711.5, height: 541)
        )
        XCTAssertEqual(frame.width, 586.5, accuracy: 0.001)
        XCTAssertEqual(frame.height, 391, accuracy: 0.001)
        XCTAssertEqual(frame.minX, 75, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 466, accuracy: 0.001)
    }

    func testAreaOverlayClampsIntoExplorerPadding() {
        let frame = LiveTextContract.areaOverlayFrame(
            selectionRect: CGRect(x: 1450, y: 900, width: 100, height: 80),
            availableSize: CGSize(width: 1512, height: 982)
        )
        XCTAssertEqual(frame.maxX, 1462, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 907, accuracy: 0.001)
    }

    func testAreaOverlayPreservesCenterWhenNoEdgeClampIsNeeded() {
        let frame = LiveTextContract.areaOverlayFrame(
            selectionRect: CGRect(x: 500, y: 300, width: 100, height: 80),
            availableSize: CGSize(width: 1512, height: 982)
        )
        XCTAssertEqual(frame, CGRect(x: 450, y: 260, width: 200, height: 160))
    }

    func testAspectFitRectCentersLetterboxedImage() {
        XCTAssertEqual(
            LiveTextContract.aspectFitRect(
                imageSize: CGSize(width: 200, height: 100),
                contentSize: CGSize(width: 300, height: 300)
            ),
            CGRect(x: 0, y: 75, width: 300, height: 150)
        )
    }

    /// `ImageAnalysisOverlayView`'s own default `contentsRect` is the unit
    /// rect, so the delegate must answer in the same space. Returning the
    /// point-space box multiplied every analysis bounding box by the content
    /// view's size and put every text item outside the reachable surface.
    func testContentsRectIsExpressedInUnitCoordinates() {
        XCTAssertEqual(
            LiveTextContract.aspectFitUnitRect(
                imageSize: CGSize(width: 200, height: 100),
                contentSize: CGSize(width: 300, height: 300)
            ),
            CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
        )
    }

    /// The recorded frame and the explorer surface share the display's aspect
    /// ratio, which is the case that has to resolve to the full unit rect.
    func testMatchingAspectRatioFillsTheWholeUnitRect() {
        XCTAssertEqual(
            LiveTextContract.aspectFitUnitRect(
                imageSize: CGSize(width: 3024, height: 1964),
                contentSize: CGSize(width: 1512, height: 982)
            ),
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    /// A frame whose size is not yet known must not collapse the overlay to an
    /// empty box; VisionKit's own default is the full unit rect.
    func testUnresolvedSizesFallBackToTheFullUnitRect() {
        XCTAssertEqual(
            LiveTextContract.aspectFitUnitRect(
                imageSize: .zero,
                contentSize: CGSize(width: 1512, height: 982)
            ),
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        XCTAssertEqual(
            LiveTextContract.aspectFitUnitRect(
                imageSize: CGSize(width: 3024, height: 1964),
                contentSize: .zero
            ),
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func testRecoveredAreaCropUsesAspectFillScaleAndCenteredOrigin() {
        XCTAssertEqual(
            LiveTextContract.sourceCropRect(
                imageSize: CGSize(width: 400, height: 300),
                contentSize: CGSize(width: 200, height: 100),
                selectionRect: CGRect(x: 20, y: 10, width: 80, height: 40)
            ),
            CGRect(x: -60, y: -30, width: 240, height: 120)
        )
    }

    func testAreaSelectionStandardizesEveryDragDirectionAndOwnsResult() {
        var state = LiveTextSelectionState()
        state.beginAreaSelection(at: CGPoint(x: 90, y: 80))
        state.updateAreaSelection(to: CGPoint(x: 20, y: 10))
        XCTAssertEqual(state.selectionRect, CGRect(x: 20, y: 10, width: 70, height: 70))
        XCTAssertEqual(
            state.finishAreaSelection(at: CGPoint(x: 10, y: 30)),
            CGRect(x: 10, y: 30, width: 80, height: 50)
        )
        XCTAssertEqual(
            state.phase,
            .analyzingArea(CGRect(x: 10, y: 30, width: 80, height: 50))
        )
        state.areaAnalysisCompleted()
        XCTAssertEqual(
            state.phase,
            .areaSelection(CGRect(x: 10, y: 30, width: 80, height: 50))
        )
    }

    func testFrameReplacementAndZeroAreaReturnToFullBleed() {
        var state = LiveTextSelectionState()
        state.beginAreaSelection(at: CGPoint(x: 4, y: 4))
        XCTAssertNil(state.finishAreaSelection(at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(state.phase, .fullBleed)
        state.beginAreaSelection(at: .zero)
        state.updateAreaSelection(to: CGPoint(x: 10, y: 20))
        state.representedFrameChanged()
        XCTAssertEqual(state.phase, .fullBleed)
        XCTAssertNil(state.selectionRect)
    }
}
#endif
