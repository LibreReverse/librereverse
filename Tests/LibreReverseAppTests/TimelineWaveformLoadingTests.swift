import Foundation
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineWaveformLoadingTests: XCTestCase {
    func testMissingOldRecordingDoesNotResolveAgainOnEveryScrub() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(60),
            bundleID: nil, rawID: 1, rawType: .audio)
        var resolutions = 0
        let model = LibreReverseTimelineWaveforms { _ in resolutions += 1; return nil }
        for _ in 0..<12 {
            model.update(visible: [segment], rawSegments: [segment], force: true)
            await model.waitForPreparationForTesting()
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertNil(model.envelope(for: segment))
        model.suspend()
        model.update(visible: [segment], rawSegments: [segment])
        await model.waitForPreparationForTesting()
        XCTAssertEqual(resolutions, 2, "Reopening can discover backfilled or restored metadata")
        model.suspend()
    }

    func testPartialMergedMeetingDoesNotPretendMissingChildrenAreSilent() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let merged = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(120),
            bundleID: nil, mergedSegmentIDs: [1, 2], rawID: 1, rawType: .audio)
        let first = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(60),
            bundleID: nil, rawID: 1, rawType: .audio)
        var resolutions = 0
        let model = LibreReverseTimelineWaveforms { _ in resolutions += 1; return nil }
        model.update(visible: [merged], rawSegments: [first])
        await model.waitForPreparationForTesting()
        XCTAssertEqual(resolutions, 0)
        XCTAssertNil(model.envelope(for: merged))
        model.suspend()
    }
}
