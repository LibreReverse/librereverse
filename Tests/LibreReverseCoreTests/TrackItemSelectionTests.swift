import Foundation
import XCTest
@testable import LibreReverseCore

final class TrackItemSelectionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testExactBoundaryHandsOffOnlyWhenFollowingSegmentAlsoContainsDate() {
        let first = segment(1, start: 10, end: 20)
        let sharesEndpoint = segment(2, start: 20, end: 30)
        let beginsLater = segment(3, start: 40, end: 50)

        XCTAssertEqual(
            TrackItemSelection.segment(
                at: epoch.addingTimeInterval(20),
                type: .capturedScreen,
                in: [first, sharesEndpoint]
            )?.rawID,
            2
        )
        XCTAssertEqual(
            TrackItemSelection.segment(
                at: epoch.addingTimeInterval(30),
                type: .capturedScreen,
                in: [sharesEndpoint, beginsLater]
            )?.rawID,
            2
        )
    }

    func testOuterGapsAndTypeFeedsAreIndependent() {
        let screenshot = segment(10, start: 10, end: 20)
        let audio = segment(20, start: 0, end: 30, type: .audio)
        let rows = [audio, screenshot]

        XCTAssertNil(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(9), type: .capturedScreen, in: rows
        ))
        XCTAssertEqual(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(15), type: .capturedScreen, in: rows
        )?.rawID, 10)
        XCTAssertEqual(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(15), type: .audio, in: rows
        )?.rawID, 20)
        XCTAssertNil(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(31), type: .audio, in: rows
        ))
    }

    func testNegativeDurationIsNormalizedToItsStartInstant() {
        let malformed = segment(7, start: 20, end: 10)
        XCTAssertEqual(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(20), type: .capturedScreen, in: [malformed]
        )?.rawID, 7)
        XCTAssertNil(TrackItemSelection.segment(
            at: epoch.addingTimeInterval(19), type: .capturedScreen, in: [malformed]
        ))
    }

    func testFrameImagesRootLivesUnderMediaRoot() {
        let storage = URL(fileURLWithPath: "/media-storage", isDirectory: true)
        let configuration = LibraryDatabaseConfiguration(
            databaseURL: storage.appendingPathComponent("library.sqlite3"),
            keyFileURL: storage.appendingPathComponent("db-key"),
            mediaRoot: storage.appendingPathComponent("Media", isDirectory: true)
        )
        XCTAssertEqual(
            configuration.frameImagesRoot,
            storage.appendingPathComponent("Media/temp/images", isDirectory: true)
        )
    }

    private func segment(
        _ id: Int64,
        start: TimeInterval,
        end: TimeInterval,
        type: SegmentType = .capturedScreen
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: epoch.addingTimeInterval(start),
            endDate: epoch.addingTimeInterval(end),
            bundleID: nil,
            rawID: id,
            rawType: type
        )
    }
}
