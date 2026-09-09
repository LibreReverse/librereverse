#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

/// Pins `contiguousOffset(atWallDate:)` to its original linear definition.
///
/// The implementation was changed from a linear scan to a binary search because
/// it runs on every scrub event. This cross-checks the two definitions over a
/// deterministic corpus containing gaps, exact boundaries, and interior points,
/// so the optimisation cannot silently change timeline coordinates.
final class LibreReverseTimelineSnapshotOffsetTests: XCTestCase {
    func testOverlappingMeetingAndScreensShareOneInvertibleAxis() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func segment(_ from: Double, _ to: Double, _ id: Int64,
            _ type: SegmentType) -> TimelineSegment {
            .init(startDate: start.addingTimeInterval(from), endDate: start.addingTimeInterval(to),
                bundleID: type == .audio ? "meeting" : "screen", rawID: id, rawType: type)
        }
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [
            segment(0, 60, 1, .audio), segment(10, 12, 2, .capturedScreen),
            segment(40, 42, 3, .capturedScreen), segment(90, 100, 4, .capturedScreen)
        ])
        XCTAssertEqual(snapshot.contiguousDuration, 70)
        for second in stride(from: 0.0, to: 60, by: 0.5) {
            let date = start.addingTimeInterval(second)
            let offset = try XCTUnwrap(snapshot.contiguousOffset(atWallDate: date))
            XCTAssertEqual(offset, second, accuracy: 0.001)
            XCTAssertEqual(snapshot.wallDate(atContiguousOffset: offset), date)
            XCTAssertGreaterThan(try XCTUnwrap(snapshot.wallDate(atContiguousOffset: offset + 0.25)), date)
        }
        XCTAssertEqual(snapshot.wallDate(atContiguousOffset: 60), start.addingTimeInterval(90))
    }

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// The definition this optimisation must reproduce exactly.
    private func linearOffset(
        _ segments: [TimelineSegment],
        _ contiguousDuration: TimeInterval,
        _ date: Date
    ) -> TimeInterval? {
        guard let first = segments.first, let last = segments.last else { return nil }
        if date <= first.startDate { return 0 }
        if date >= last.endDate { return contiguousDuration }
        if let segment = segments.first(where: {
            $0.startDate <= date && date <= $0.endDate
        }) {
            return (segment.contiguousStartOffset ?? 0)
                + date.timeIntervalSince(segment.startDate)
        }
        return segments.last(where: { $0.endDate < date })?.contiguousEndOffset
    }

    private func segment(
        _ start: TimeInterval,
        _ end: TimeInterval,
        id: Int64,
        type: SegmentType = .capturedScreen
    )
        -> TimelineSegment
    {
        TimelineSegment(
            startDate: origin.addingTimeInterval(start),
            endDate: origin.addingTimeInterval(end),
            bundleID: "com.example.App",
            windowName: nil,
            browserURL: nil,
            browserProfile: nil,
            rawID: id,
            rawType: type
        )
    }

    /// Contiguous runs separated by gaps, which is what a real day looks like.
    private var corpus: [TimelineSegment] {
        var segments: [TimelineSegment] = []
        var id: Int64 = 1
        var cursor: TimeInterval = 0
        for run in 0..<12 {
            for _ in 0..<7 {
                segments.append(segment(cursor, cursor + 2, id: id))
                id += 1
                cursor += 2
            }
            // Gaps of varying size, including a very large one.
            cursor += [37.0, 5.0, 900.0, 61.0][run % 4]
        }
        return segments
    }

    func testBinarySearchMatchesLinearDefinition() {
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: corpus)
        let processed = snapshot.processedScreenshotSegments
        XCTAssertFalse(processed.isEmpty)

        var probes: [Date] = []
        // Every boundary and interior point, plus points inside every gap.
        for segment in processed {
            for delta in [-0.5, -0.001, 0, 0.001, 1.0, 1.999, 2.0, 2.001, 0.5] {
                probes.append(segment.startDate.addingTimeInterval(delta))
                probes.append(segment.endDate.addingTimeInterval(delta))
            }
        }
        // Far outside both ends.
        probes.append(origin.addingTimeInterval(-10_000))
        probes.append(origin.addingTimeInterval(1_000_000))

        for probe in probes {
            let expected = linearOffset(processed, snapshot.contiguousDuration, probe)
            let actual = snapshot.contiguousOffset(atWallDate: probe)
            switch (expected, actual) {
            case (let expected?, let actual?):
                XCTAssertEqual(
                    actual, expected, accuracy: 1e-9,
                    "at \(probe.timeIntervalSince(origin))"
                )
            case (nil, nil):
                break
            default:
                XCTFail(
                    "nil mismatch at \(probe.timeIntervalSince(origin)): "
                        + "expected \(String(describing: expected)), got \(String(describing: actual))"
                )
            }
        }
    }

    func testRoundTripsThroughWallDate() {
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: corpus)
        var offset: TimeInterval = 0
        while offset <= snapshot.contiguousDuration {
            let date = try? XCTUnwrap(snapshot.wallDate(atContiguousOffset: offset))
            if let date = date ?? nil,
                let back = snapshot.contiguousOffset(atWallDate: date)
            {
                XCTAssertEqual(back, offset, accuracy: 1e-9, "offset \(offset)")
            }
            offset += 0.25
        }
    }

    func testEmptySnapshotHasNoOffset() {
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [])
        XCTAssertNil(snapshot.contiguousOffset(atWallDate: origin))
    }

    func testMeetingOnlySnapshotRemainsSeekableAndExposesAudioFeed() throws {
        let meeting = segment(10, 70, id: 99, type: .audio)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [meeting])
        XCTAssertEqual(snapshot.processedAudioSegments.map(\.rawID), [99])
        XCTAssertTrue(snapshot.processedScreenshotSegments.isEmpty)
        XCTAssertEqual(snapshot.contiguousDuration, 60)
        XCTAssertEqual(
            snapshot.validSeekInterval,
            DateInterval(
                start: origin.addingTimeInterval(10),
                end: origin.addingTimeInterval(70)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.contiguousOffset(
                    atWallDate: origin.addingTimeInterval(25)
                )),
            15,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.wallDate(atContiguousOffset: 45))
                .timeIntervalSince(origin),
            55,
            accuracy: 1e-9
        )
    }

    func testMeetingAndScreenshotShareOneGapCompressedClock() throws {
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [
            segment(0, 2, id: 1),
            segment(100, 160, id: 2, type: .audio),
            segment(300, 302, id: 3),
        ])
        XCTAssertEqual(snapshot.processedSegments.map(\.rawID), [1, 2, 3])
        XCTAssertEqual(snapshot.contiguousDuration, 64)
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.contiguousOffset(
                    atWallDate: origin.addingTimeInterval(130)
                )),
            32,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.contiguousOffset(
                    atWallDate: origin.addingTimeInterval(200)
                )),
            62,
            accuracy: 1e-9
        )
    }

    func testMergedMeetingBarRoutesToItsActualChildAndClampsVisualGaps() throws {
        let first = segment(0, 10, id: 10, type: .audio)
        let second = segment(10.5, 20, id: 11, type: .audio)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [first, second])

        XCTAssertEqual(snapshot.processedAudioSegments.count, 1)
        XCTAssertEqual(snapshot.processedAudioSegments[0].rawID, 10)
        XCTAssertEqual(snapshot.processedAudioSegments[0].mergedSegmentIDs, [11])
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(15),
                anchoredBy: 10
            ),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(15))
        )
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(10.5),
                anchoredBy: 10
            ),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(10.5))
        )
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(10.2),
                anchoredBy: 10
            ),
            .init(segmentID: 10, seekDate: origin.addingTimeInterval(10))
        )
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(10.3),
                anchoredBy: 10
            ),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(10.5))
        )
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(5),
                anchoredBy: 11
            ),
            .init(segmentID: 10, seekDate: origin.addingTimeInterval(5))
        )
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(20),
                anchoredBy: 11
            ),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(20))
        )
        XCTAssertEqual(
            snapshot.followingMeetingSelection(after: 10, anchoredBy: 10),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(10.5))
        )
        XCTAssertEqual(
            snapshot.followingMeetingSelection(after: 10, anchoredBy: 11),
            .init(segmentID: 11, seekDate: origin.addingTimeInterval(10.5))
        )
        XCTAssertNil(snapshot.followingMeetingSelection(after: 11, anchoredBy: 10))
        XCTAssertNil(snapshot.followingMeetingSelection(after: 999, anchoredBy: 10))
        XCTAssertNil(snapshot.followingMeetingSelection(after: 10, anchoredBy: 999))
        XCTAssertNil(snapshot.meetingSelection(at: origin, anchoredBy: 999))
        XCTAssertEqual(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(-1),
                anchoredBy: 10
            ),
            .init(segmentID: 10, seekDate: origin)
        )
        XCTAssertNil(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(-1),
                anchoredBy: 10,
                clampOuterBounds: false
            ))
        XCTAssertNil(
            snapshot.meetingSelection(
                at: origin.addingTimeInterval(20),
                anchoredBy: 11,
                clampOuterBounds: false
            ))
    }

    func testStarMappingPreservesFeedOrderFiltersIntervalAndCompressesGaps() {
        let feed = [
            origin.addingTimeInterval(101),
            origin.addingTimeInterval(-1),
            origin.addingTimeInterval(50),
            origin.addingTimeInterval(1),
            origin.addingTimeInterval(105),
        ]
        let snapshot = LibreReverseTimelineSnapshot(
            rawSegments: [segment(0, 2, id: 1), segment(100, 104, id: 2)],
            starredDates: feed
        )

        XCTAssertEqual(snapshot.starredFrames.map(\.date), [feed[0], feed[2], feed[3]])
        XCTAssertEqual(snapshot.starredFrames.map(\.contiguousOffset), [3, 2, 1])
    }
}
#endif
