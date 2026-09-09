#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseCaptureContextPersistenceTests: XCTestCase {
    func testAdmissionCreatesCanonicalDeferredFrameAndRoundTripsFullContext() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = LibreReverseCaptureContext(
            bundleID: "com.google.Chrome",
            windowName: "Project notes",
            browserURL: "https://example.test/article",
            browserProfile: "Profile 2"
        )
        let admitted = try admit(date, "deferred.png", context, configuration)

        XCTAssertNotNil(admitted.segmentID)
        XCTAssertEqual(admitted.segment?.startDate, date)
        XCTAssertEqual(
            admitted.segment?.endDate,
            date.addingTimeInterval(CaptureContract.productionCaptureIntervalSeconds)
        )
        XCTAssertEqual(admitted.encodingStatus, CloneFrameEncodingStatus.deferred.rawValue)
        XCTAssertEqual(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ), [admitted])
        let segments = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: historical(configuration)
        ).segments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].bundleID, context.bundleID)
        XCTAssertEqual(segments[0].windowName, context.windowName)
        XCTAssertEqual(segments[0].browserURL, context.browserURL)
        XCTAssertEqual(segments[0].browserProfile, context.browserProfile)
        XCTAssertEqual(segments[0].startDate, date)
        XCTAssertEqual(
            segments[0].endDate,
            date.addingTimeInterval(CaptureContract.productionCaptureIntervalSeconds)
        )
        let moment = try XCTUnwrap(LibraryDatabase.nearestMoment(
            to: date,
            configuration: historical(configuration)
        ))
        XCTAssertEqual(moment.segmentID, admitted.segmentID)
        XCTAssertTrue(moment.isPendingImage)
        XCTAssertNil(moment.chunkURL)
        XCTAssertEqual(moment.frameImageURL.lastPathComponent, "deferred.png")
    }

    func testSegmentReuseBoundaryContextAndOutOfOrderRules() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = LibreReverseCaptureContext(bundleID: "com.example.Editor", windowName: "Draft")

        let first = try admit(start, "0.png", draft, configuration)
        let reused = try admit(start.addingTimeInterval(4), "1.png", draft, configuration)
        XCTAssertEqual(reused.segmentID, first.segmentID)
        XCTAssertEqual(reused.segment?.startDate, start)
        XCTAssertEqual(reused.segment?.endDate, start.addingTimeInterval(4))
        var segments = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: historical(configuration)
        ).segments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].endDate, start.addingTimeInterval(4))

        let boundary = try admit(start.addingTimeInterval(244), "2.png", draft, configuration)
        XCTAssertNotEqual(boundary.segmentID, first.segmentID, "reuse is strict at end + 240s")
        let changed = try admit(
            start.addingTimeInterval(246),
            "3.png",
            .init(bundleID: "com.example.Editor", windowName: "Review"),
            configuration
        )
        XCTAssertNotEqual(changed.segmentID, boundary.segmentID)

        let outOfOrderDate = start.addingTimeInterval(-10)
        let outOfOrder = try admit(outOfOrderDate, "old.png", draft, configuration)
        XCTAssertNil(outOfOrder.segmentID)
        XCTAssertNil(outOfOrder.segment)
        let oldMoment = try XCTUnwrap(LibraryDatabase.nearestMoment(
            to: outOfOrderDate,
            configuration: historical(configuration)
        ))
        XCTAssertNil(oldMoment.segmentID)
        segments = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: historical(configuration)
        ).segments
        XCTAssertEqual(segments.count, 3)
    }

    func testFinalizationUpdatesExistingFramesWithoutChangingSegments() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let context = LibreReverseCaptureContext(bundleID: "com.example.Editor", windowName: "Draft")
        let first = try admit(start, "0.png", context, configuration)
        let second = try admit(start.addingTimeInterval(2), "1.png", context, configuration)
        let segmentsBefore = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: historical(configuration)
        ).segments
        let xid = "d4o98eor8kk07r7hn090"
        let mediaPath = VideoStorage.relativePath(xid: xid, date: start)
        try FileManager.default.createDirectory(
            at: configuration.mediaRoot.appendingPathComponent(mediaPath)
                .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(
            to: configuration.mediaRoot.appendingPathComponent(mediaPath)
        )

        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            LibreReverseRecordedChunk(
                relativeMediaPath: mediaPath,
                xid: xid,
                width: 100,
                height: 80,
                frames: [
                    .init(frameID: first.id, videoFrameIndex: 0),
                    .init(frameID: second.id, videoFrameIndex: 1),
                ]
            ),
            configuration: configuration
        )

        XCTAssertTrue(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ).isEmpty)
        XCTAssertEqual(
            try LibraryDatabase.loadRecentTimelineWindow(
                configuration: historical(configuration)
            ).segments,
            segmentsBefore
        )
        let chunks = try LibraryDatabase.loadChunks(
            configuration: historical(configuration)
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].databaseVideoID, videoID)
        XCTAssertEqual(chunks[0].sampleCount, 2)
        let moment = try XCTUnwrap(LibraryDatabase.nearestMoment(
            to: second.createdAt,
            configuration: historical(configuration)
        ))
        XCTAssertFalse(moment.isPendingImage)
        XCTAssertEqual(moment.videoFrameIndex, 1)
        XCTAssertEqual(moment.chunkURL?.lastPathComponent, xid)
    }

    func testCanonicalEncodingStatusTransitionsAreDurable() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let admitted = try admit(
            Date(timeIntervalSince1970: 1_700_000_000),
            "writer-state.png",
            nil,
            configuration
        )
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: admitted.id,
            status: .pending,
            configuration: configuration
        )
        XCTAssertTrue(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ).isEmpty)
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: admitted.id,
            status: .deferred,
            configuration: configuration
        )
        XCTAssertEqual(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ).map(\.id), [admitted.id])
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: admitted.id,
            status: .failed,
            configuration: configuration
        )
        XCTAssertTrue(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ).isEmpty)
        XCTAssertThrowsError(try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: -1,
            status: .pending,
            configuration: configuration
        ))
    }

    func testFinalizationFailureRollsBackVideoAndEarlierFrameUpdates() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let admitted = try admit(
            Date(timeIntervalSince1970: 1_700_000_000),
            "rollback.png",
            nil,
            configuration
        )
        let xid = "d4o98eor8kk07r7hn091"
        let mediaPath = VideoStorage.relativePath(
            xid: xid, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try FileManager.default.createDirectory(
            at: configuration.mediaRoot.appendingPathComponent(mediaPath)
                .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(
            to: configuration.mediaRoot.appendingPathComponent(mediaPath)
        )

        XCTAssertThrowsError(try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: mediaPath,
                xid: xid,
                width: 100,
                height: 80,
                frames: [
                    .init(frameID: admitted.id, videoFrameIndex: 0),
                    .init(frameID: -1, videoFrameIndex: 1),
                ]
            ),
            configuration: configuration
        ))
        XCTAssertTrue(try LibraryDatabase.loadChunks(
            configuration: historical(configuration)
        ).isEmpty)
        XCTAssertEqual(try LibreReverseLibraryStore.loadDeferredFrames(
            configuration: configuration
        ).map(\.id), [admitted.id])
    }

    private func admit(
        _ date: Date,
        _ imageFileName: String,
        _ context: LibreReverseCaptureContext?,
        _ configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseAdmittedFrame {
        try LibreReverseLibraryStore.admitFrame(
            createdAt: date,
            imageFileName: imageFileName,
            context: context,
            configuration: configuration
        )
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-context-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    private func historical(
        _ configuration: LibreReverseLibraryConfiguration
    ) -> LibraryDatabaseConfiguration {
        LibraryDatabaseConfiguration(
            databaseURL: configuration.databaseURL,
            keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot,
            frameImagesRoot: configuration.frameImagesRoot
        )
    }
}
#endif
