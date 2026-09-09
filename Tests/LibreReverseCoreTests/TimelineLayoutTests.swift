import XCTest
@testable import LibreReverseCore

final class TimelineLayoutTests: XCTestCase {

    func testTrackGeometryAndLayering() {
        XCTAssertEqual(TimelineLayout.contentHeight, 140)
        XCTAssertEqual(TimelineMediaType.audio.bottomInset, 77.5)
        XCTAssertEqual(TimelineMediaType.screenshot.bottomInset, 75)
        XCTAssertEqual(TimelineMediaType.star.bottomInset, 71)
        XCTAssertEqual(TimelineMediaType.audio.height, 55)
        XCTAssertEqual(TimelineMediaType.screenshot.height, 30)
        XCTAssertEqual(TimelineMediaType.star.height, 16)
        XCTAssertEqual(TimelineMediaType.allCases.map(\.zIndex), [0, 1, 2])
    }

    func testPlayheadCenteredItemProjectionUsesFloor() {
        let frame = TimelineLayout.itemFrame(
            offset: -2.25,
            duration: 3.75,
            mediaType: .screenshot,
            viewportWidth: 101,
            logZoomRange: 10
        )
        XCTAssertEqual(frame.x, 27)
        XCTAssertEqual(frame.y, 65)
        XCTAssertEqual(frame.width, 37)
        XCTAssertEqual(frame.height, 30)

        XCTAssertEqual(
            TimelineLayout.itemFrame(
                offset: 0,
                duration: 200,
                mediaType: .star,
                viewportWidth: 101,
                logZoomRange: 10
            ),
            .init(x: 50, y: 69, width: 16, height: 16)
        )
    }

    func testCenteredContentWidthUsesSymmetricFlooredHalfViewportPadding() {
        XCTAssertEqual(
            TimelineLayout.contentWidth(
                contiguousDuration: 25,
                viewportWidth: 101,
                logZoomRange: 10
            ),
            352
        )
    }

    func testRecoveredScrollOriginMappingExcludesCenteredContentPadding() throws {
        let origin = try XCTUnwrap(TimelineLayout.scrollOriginX(
            contiguousOffset: 25,
            viewportWidth: 101,
            logZoomRange: 10
        ))
        XCTAssertEqual(origin, 252.5)
        XCTAssertEqual(
            try XCTUnwrap(TimelineLayout.contiguousOffset(
                scrollOriginX: origin,
                viewportWidth: 101,
                logZoomRange: 10
            )),
            25
        )
    }

    func testRawAppSegmentsProjectByContiguousOffsetAndCannotOverlap() throws {
        let first = try XCTUnwrap(TimelineLayout.rawSegmentFrame(
            segmentStartOffset: 0,
            segmentEndOffset: 20,
            groupStartOffset: 0,
            groupDuration: 100,
            boundsWidth: 100
        ))
        XCTAssertEqual(first, .init(x: 0, y: 0, width: 20, height: 30))

        let overlapping = try XCTUnwrap(TimelineLayout.rawSegmentFrame(
            segmentStartOffset: 10,
            segmentEndOffset: 15,
            groupStartOffset: 0,
            groupDuration: 100,
            boundsWidth: 100,
            priorFrame: first
        ))
        XCTAssertEqual(overlapping, .init(x: 20, y: 0, width: 5, height: 30))

        let tiny = try XCTUnwrap(TimelineLayout.rawSegmentFrame(
            segmentStartOffset: 99.9,
            segmentEndOffset: 99.95,
            groupStartOffset: 0,
            groupDuration: 100,
            boundsWidth: 100
        ))
        XCTAssertEqual(tiny.width, 1)
    }

    func testVisualPaddingDoesNotChangeClickInterpolationContract() throws {
        let start = Date(timeIntervalSince1970: 500)
        let end = start.addingTimeInterval(40)
        let raw = TimelineRect(x: 10, y: 0, width: 20, height: 30)
        let visual = TimelineLayout.visualSegmentFrame(
            rawFrame: raw,
            segmentPadding: 4
        )
        XCTAssertEqual(visual, .init(x: 12, y: 10, width: 16, height: 10))

        XCTAssertEqual(
            TimelineLayout.interpolatedClickedDate(
                clickX: 15,
                segmentStart: start,
                segmentEnd: end,
                rawFrame: raw
            ),
            start.addingTimeInterval(10)
        )
    }

    func testRecoveredDrawingStyleGeometry() {
        XCTAssertEqual(TimelineDrawingStyle.segmentPadding, 2)
        XCTAssertEqual(TimelineDrawingStyle.barHeight, 10)
        XCTAssertEqual(TimelineDrawingStyle.cornerRadius, 5)
        XCTAssertEqual(TimelineDrawingStyle.gradientWhiteAlpha, 0.20)
        XCTAssertEqual(TimelineDrawingStyle.gradientBlackAlpha, 0.20)
        XCTAssertEqual(TimelineDrawingStyle.normalOutlineBlackAlpha, 0.17)
        XCTAssertEqual(TimelineDrawingStyle.interiorHighlightWhiteAlpha, 0.28)
        XCTAssertEqual(TimelineDrawingStyle.hoveredOutlineWhiteAlpha, 0.40)
        XCTAssertEqual(TimelineDrawingStyle.selectedOutlineWhiteAlpha, 0.80)
        XCTAssertEqual(TimelineDrawingStyle.largeIconSide, 26)
        XCTAssertEqual(TimelineDrawingStyle.iconPresentationThreshold, 22)
        XCTAssertEqual(TimelineDrawingStyle.compactIconSide, 18)
        XCTAssertEqual(
            TimelineDrawingStyle.normalOutlineWidth(backingScale: 2),
            1
        )

        let bar = TimelineRect(x: 20, y: 10, width: 50, height: 10)
        XCTAssertEqual(
            TimelineDrawingStyle.highlightedFrame(for: bar),
            .init(x: 18, y: 8, width: 54, height: 14)
        )
        XCTAssertEqual(
            TimelineDrawingStyle.iconFrame(
                in: .init(x: 10, y: 20, width: 40, height: 30),
                iconSide: 26
            ),
            .init(x: 17, y: 22, width: 26, height: 26)
        )
        XCTAssertNil(
            TimelineDrawingStyle.iconFrame(
                in: .init(x: 10, y: 20, width: 39, height: 30),
                iconSide: 26
            )
        )
        XCTAssertEqual(
            TimelineDrawingStyle.centeredSquareFrame(
                in: .init(x: 10, y: 20, width: 40, height: 30),
                side: 22
            ),
            .init(x: 19, y: 24, width: 22, height: 22)
        )
    }

    func testCanonicalTwoPointPaddingKeepsRapidSwitchBarsContinuous() throws {
        var previous: TimelineRect?
        let frames = try (0..<8).map { index -> TimelineRect in
            let raw = try XCTUnwrap(TimelineLayout.rawSegmentFrame(
                segmentStartOffset: Double(index) * 2,
                segmentEndOffset: Double(index + 1) * 2,
                groupStartOffset: 0,
                groupDuration: 16,
                boundsWidth: 80,
                priorFrame: previous
            ))
            previous = raw
            return TimelineLayout.visualSegmentFrame(
                rawFrame: raw,
                segmentPadding: TimelineDrawingStyle.segmentPadding
            )
        }

        XCTAssertEqual(frames.map(\.width), Array(repeating: 8, count: 8))
        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(pair.1.x - pair.0.maxX, 2)
        }
    }

    func testCompressedOffsetsDoNotRecreateLargeWallClockHoles() throws {
        // Real local failure shape: five two-second Chrome segments occupied a
        // 10-second contiguous group while their wall dates spanned 104 s.
        // The canonical projector consumes these contiguous offsets, yielding
        // a filled lane with only the two-point visual gutters.
        var previous: TimelineRect?
        let frames = try (0..<5).map { index -> TimelineRect in
            let raw = try XCTUnwrap(TimelineLayout.rawSegmentFrame(
                segmentStartOffset: Double(index) * 2,
                segmentEndOffset: Double(index + 1) * 2,
                groupStartOffset: 0,
                groupDuration: 10,
                boundsWidth: 100,
                priorFrame: previous
            ))
            previous = raw
            return TimelineLayout.visualSegmentFrame(
                rawFrame: raw,
                segmentPadding: TimelineDrawingStyle.segmentPadding
            )
        }
        XCTAssertEqual(frames.first?.x, 1)
        XCTAssertEqual(frames.last?.maxX, 99)
        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(pair.1.x - pair.0.maxX, 2)
        }
    }

    func testRecoveredStarMarkerConstructionAndPlacement() {
        XCTAssertEqual(TimelineStarDrawingStyle.systemSymbolName, "star.fill")
        XCTAssertEqual(TimelineStarDrawingStyle.layerSide, 16)
        XCTAssertEqual(TimelineStarDrawingStyle.inset, 1)
        XCTAssertEqual(TimelineStarDrawingStyle.innerSide, 14)
        XCTAssertEqual(TimelineStarDrawingStyle.orangeSRGB.red, 1)
        XCTAssertEqual(TimelineStarDrawingStyle.orangeSRGB.green, 0.588)
        XCTAssertEqual(TimelineStarDrawingStyle.orangeSRGB.blue, 0.196)
        XCTAssertEqual(TimelineStarDrawingStyle.yellowDisplayP3.green, 0.902)
        XCTAssertEqual(
            TimelineStarDrawingStyle.destinationRect(
                bounds: .init(x: 10, y: 20, width: 17, height: 16),
                dirtyRect: .init(x: 10, y: 21, width: 17, height: 14)
            ),
            .init(x: 11, y: 19, width: 16, height: 16)
        )
    }

    func testRecoveredZoomTransformIsFloatDomainAndAnchorsAtZoom100() {
        XCTAssertEqual(
            TimelineLayout.logZoomRange(
                zoomLevel: 100,
                rangeLower: 30,
                rangeUpper: 300
            ),
            30
        )
        let expected: Float = 30 + (300 - 30)
            * ((powf(1.11, 50) * 0.003 - 0.003) / 100)
        XCTAssertEqual(
            TimelineLayout.logZoomRange(
                zoomLevel: 50,
                rangeLower: 30,
                rangeUpper: 300
            ),
            expected
        )
    }

    func testRecoveredZoomDefaultAndDynamicVisibleDurationBounds() {
        XCTAssertEqual(TimelineLayout.defaultZoomLevel, 60)
        XCTAssertEqual(TimelineLayout.zoomLevelRange, 0...100)
        XCTAssertNil(TimelineLayout.zoomRange(validSeekDuration: nil))
        XCTAssertEqual(TimelineLayout.zoomRange(validSeekDuration: 30), 60...60)
        XCTAssertEqual(TimelineLayout.zoomRange(validSeekDuration: 600), 60...600)
        XCTAssertEqual(
            TimelineLayout.zoomRange(validSeekDuration: 20_000),
            60...10_800
        )
    }

    func testDefaultZoomLevelFeedsControllerTransformWithoutSubstitution() throws {
        let range = try XCTUnwrap(
            TimelineLayout.zoomRange(validSeekDuration: 600)
        )
        let expected = range.lowerBound + (range.upperBound - range.lowerBound)
            * ((powf(1.11, 100 - 60) * 0.003 - 0.003) / 100)

        XCTAssertEqual(
            TimelineLayout.logZoomRange(
                zoomLevel: TimelineLayout.defaultZoomLevel,
                rangeLower: range.lowerBound,
                rangeUpper: range.upperBound
            ),
            expected
        )
    }

    func testInteractiveFetchWindowUsesZoomBasisNotPriorActualWindow() throws {
        let visible = TimelineLayout.logZoomRange(
            zoomLevel: 60,
            rangeLower: 60,
            rangeUpper: 10_800
        )
        XCTAssertEqual(
            TimelineLayout.interactiveFetchWindowDuration(
                zoomLevel: 60,
                validSeekDuration: 20_000
            ),
            TimeInterval(visible * 10)
        )
        // A page-oriented fetch may return 4,900 or 8,300 seconds, but neither
        // value is an operand of the next interactive calculation.
        XCTAssertNotEqual(TimeInterval(visible * 10), 4_900)
        XCTAssertNotEqual(TimeInterval(visible * 10), 8_300)
    }

    func testInteractiveFetchWindowFastScrollFreshnessAndManualFactors() {
        let now = Date(timeIntervalSince1970: 10_000)
        let base = TimelineLayout.interactiveFetchWindowDuration(
            zoomLevel: 60,
            validSeekDuration: 20_000,
            now: now
        )
        XCTAssertEqual(
            TimelineLayout.interactiveFetchWindowDuration(
                zoomLevel: 60,
                validSeekDuration: 20_000,
                lastFastScroll: .init(
                    date: now.addingTimeInterval(-9.999),
                    isManual: true
                ),
                now: now
            ),
            base * 4
        )
        XCTAssertEqual(
            TimelineLayout.interactiveFetchWindowDuration(
                zoomLevel: 60,
                validSeekDuration: 20_000,
                lastFastScroll: .init(date: now, isManual: false),
                now: now
            ),
            base * 8
        )
        XCTAssertEqual(
            TimelineLayout.interactiveFetchWindowDuration(
                zoomLevel: 60,
                validSeekDuration: 20_000,
                lastFastScroll: .init(
                    date: now.addingTimeInterval(-10),
                    isManual: false
                ),
                now: now
            ),
            base
        )
    }
}
