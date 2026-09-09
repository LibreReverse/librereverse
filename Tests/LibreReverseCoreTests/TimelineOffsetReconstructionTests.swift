import Foundation
import XCTest
@testable import LibreReverseCore

final class TimelineOffsetReconstructionTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 10_000)

    func testAudioPreprocessingMergesExactIdentityAndStrictGap() {
        let first = segment(
            0, 10, id: 1, type: .audio,
            bundleID: "meeting", browserURL: "https://www.example.com/a",
            mergedIDs: [90]
        )
        let absorbed = segment(
            12, 8, id: 2, type: .audio,
            bundleID: "meeting", browserURL: "https://www.example.com/b"
        )
        let strictBoundary = segment(
            248, 250, id: 3, type: .audio,
            bundleID: "meeting", browserURL: "https://www.example.com/c"
        )
        let result = TimelineOffsetReconstruction.mergeAudioSegments([
            first, absorbed, strictBoundary,
        ])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].rawID, 1)
        XCTAssertEqual(result[0].startDate, first.startDate)
        XCTAssertEqual(result[0].endDate, absorbed.endDate,
                       "the new end is assigned verbatim, even when it moves backward")
        XCTAssertEqual(result[0].mergedSegmentIDs, [90, 2])
        XCTAssertEqual(result[1].rawID, 3,
                       "start == prior end + 240 does not merge")
    }

    func testFullReconstructionUsesStableAudioThenScreenshotTie() {
        let audio = segment(0, 10, id: 1, type: .audio)
        let tiedScreen = segment(0, 4, id: 2, type: .capturedScreen)
        let forwardScreen = segment(12, 14, id: 3, type: .capturedScreen)
        let backward = segment(-5, -4, id: 4, type: .capturedScreen)

        let result = TimelineOffsetReconstruction.reconstructFull(
            audioSegments: [audio],
            screenshotSegments: [tiedScreen, forwardScreen, backward]
        )

        XCTAssertEqual(result.processedSegments.map(\.rawID), [4, 1, 2, 3])
        XCTAssertEqual(result.processedSegments.map(\.contiguousStartOffset), [0, 1, 1, 5])
        XCTAssertEqual(result.processedSegments.map(\.contiguousEndOffset), [1, 11, 5, 7])
        XCTAssertEqual(result.audioSegments.map(\.rawID), [1])
        XCTAssertEqual(result.screenshotSegments.map(\.rawID), [4, 2, 3])
    }

    private func segment(
        _ start: TimeInterval,
        _ end: TimeInterval,
        id: Int64,
        type: SegmentType,
        offsets: (TimeInterval, TimeInterval)? = nil,
        bundleID: String? = "test",
        browserURL: String? = nil,
        mergedIDs: [Int64]? = nil
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: origin.addingTimeInterval(start),
            endDate: origin.addingTimeInterval(end),
            bundleID: bundleID,
            contiguousStartOffset: offsets?.0,
            contiguousEndOffset: offsets?.1,
            browserURL: browserURL,
            mergedSegmentIDs: mergedIDs,
            rawID: id,
            rawType: type
        )
    }
}
