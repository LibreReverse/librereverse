import XCTest
@testable import LibreReverseCore

/// Covers the `FrameDetail.DisplayMode` cases.
final class FrameDetailDisplayTests: XCTestCase {
    private final class ImageToken {}

    func testRecoveredOrdinals() {
        XCTAssertEqual(FrameDetailDisplayMode.image.rawValue, 0)
        XCTAssertEqual(FrameDetailDisplayMode.loading.rawValue, 1)
        XCTAssertEqual(FrameDetailDisplayMode.video.rawValue, 2)
        XCTAssertEqual(FrameDetailDisplayMode.allCases.count, 3)
    }

    func testDerivedHiddenStateHidesTheSurface() {
        let live = FrameDetailDisplay.presentation(
            isHidden: true, hasVideo: true, hasImage: true
        )
        XCTAssertTrue(live.isHidden)
    }

    func testVideoWinsOverStill() {
        let presentation = FrameDetailDisplay.presentation(
            isHidden: false, hasVideo: true, hasImage: true
        )
        XCTAssertFalse(presentation.isHidden)
        XCTAssertEqual(presentation.displayMode, .video)
    }

    func testStillWhenNoVideo() {
        let presentation = FrameDetailDisplay.presentation(
            isHidden: false, hasVideo: false, hasImage: true
        )
        XCTAssertEqual(presentation.displayMode, .image)
    }

    /// Unresolved must hold in `loading`, never blank the surface.
    func testUnresolvedHoldsInLoadingRatherThanBlanking() {
        let presentation = FrameDetailDisplay.presentation(
            isHidden: false, hasVideo: false, hasImage: false
        )
        XCTAssertFalse(presentation.isHidden)
        XCTAssertEqual(presentation.displayMode, .loading)
    }

    func testExactFrameDetailVisibilityCutoffAndSegmentGate() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(FrameDetailVisibility.isHidden(
            segmentType: nil, currentSeekPosition: now.addingTimeInterval(-100), now: now
        ))
        XCTAssertTrue(FrameDetailVisibility.isHidden(
            segmentType: .audio, currentSeekPosition: now.addingTimeInterval(-100), now: now
        ))
        XCTAssertTrue(FrameDetailVisibility.isHidden(
            segmentType: .capturedScreen,
            currentSeekPosition: now.addingTimeInterval(-2.999),
            now: now
        ))
        XCTAssertFalse(FrameDetailVisibility.isHidden(
            segmentType: .capturedScreen,
            currentSeekPosition: now.addingTimeInterval(-3.0),
            now: now
        ))
        XCTAssertTrue(FrameDetailVisibility.isHidden(
            segmentType: .capturedScreen,
            currentSeekPosition: now.addingTimeInterval(2.999),
            now: now
        ))
    }

    func testMeetingMediaKeepsSharedPlayerVisibleWithoutCapturedScreenSegment() {
        XCTAssertFalse(LibreReverseTimelineSurfaceVisibility.isHidden(
            frameDetailHidden: true,
            hasSelectedMeetingMedia: true
        ))
        XCTAssertTrue(LibreReverseTimelineSurfaceVisibility.isHidden(
            frameDetailHidden: true,
            hasSelectedMeetingMedia: false
        ))
        XCTAssertFalse(LibreReverseTimelineSurfaceVisibility.isHidden(
            frameDetailHidden: false,
            hasSelectedMeetingMedia: false
        ))
    }

    func testFrameDetailRetainsExactlyOneLastImage() {
        let retention = FrameDetailImageRetention<ImageToken>()
        var first: ImageToken? = ImageToken()
        weak let releasedFirst = first
        let second = ImageToken()

        XCTAssertTrue(retention.update(with: first))
        XCTAssertTrue(retention.lastImage === first)

        first = nil
        XCTAssertNotNil(releasedFirst, "the current _lastImage must remain retained")
        XCTAssertTrue(retention.update(with: second))
        XCTAssertNil(releasedFirst, "replacing _lastImage must release the prior frame")
        XCTAssertTrue(retention.lastImage === second)
    }

    func testLoadingHoldsLastImageWithoutCreatingAnotherOwner() {
        let retention = FrameDetailImageRetention<ImageToken>()
        let image = ImageToken()
        XCTAssertTrue(retention.update(with: image))

        XCTAssertFalse(retention.update(with: nil))
        XCTAssertTrue(retention.lastImage === image)
        XCTAssertFalse(retention.update(with: image))
    }

    func testClearViewReleasesLastImage() {
        let retention = FrameDetailImageRetention<ImageToken>()
        var image: ImageToken? = ImageToken()
        weak let releasedImage = image
        retention.update(with: image)
        image = nil

        retention.clear()
        XCTAssertNil(releasedImage)
        XCTAssertNil(retention.lastImage)
    }
}
