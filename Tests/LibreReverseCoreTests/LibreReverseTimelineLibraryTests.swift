#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseTimelineLibraryTests: XCTestCase {
    func testNearestMomentPrefersLaterFrameOnEqualDistance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-nearest-tie-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(library)
        try seedCanonicalLibrary(library)
        let configuration = LibraryDatabaseConfiguration(
            databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot,
            frameImagesRoot: library.frameImagesRoot
        )

        let equidistant = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:00:00.750"))
        let moment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(to: equidistant, configuration: configuration)
        )
        XCTAssertEqual(moment.wallDate, Self.formatter.date(from: "2026-08-22T12:00:01.000"))
        XCTAssertEqual(moment.videoFrameIndex, 30)
    }

    func testStarMutationRetainsLegacyPrimaryRepresentation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-primary-star-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(library)
        try seedCanonicalLibrary(library)
        let date = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:00:01.000"))

        let starred = try LibreReverseLibraryStore.setFrameStarred(
            frameID: 3,
            wallDate: date,
            isStarred: true,
            configuration: library
        )
        XCTAssertEqual(starred.owner, .primary)
        let configuration = LibraryDatabaseConfiguration(
            databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot,
            frameImagesRoot: library.frameImagesRoot
        )
        XCTAssertTrue(
            try XCTUnwrap(
                LibreReverseTimelineLibrary.nearestMoment(to: date, configuration: configuration)
            ).isStarred
        )

        let unstarred = try LibreReverseLibraryStore.setFrameStarred(
            frameID: 3,
            wallDate: date,
            isStarred: false,
            configuration: library
        )
        XCTAssertEqual(unstarred.owner, .primary)
        XCTAssertFalse(
            try XCTUnwrap(
                LibreReverseTimelineLibrary.nearestMoment(to: date, configuration: configuration)
            ).isStarred
        )
    }

    func testLibreReverseReaderProcessesScreenshotTrackAndResolvesConfiguredMoment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-timeline-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(library)
        try seedCanonicalLibrary(library)
        let configuration = LibraryDatabaseConfiguration(
            databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot,
            frameImagesRoot: library.frameImagesRoot
        )

        let snapshot = try LibreReverseTimelineLibrary.loadSnapshot(configuration: configuration)
        XCTAssertEqual(snapshot.processedScreenshotSegments.map(\.rawID), [1, 2, 3])
        // The meeting lasts five seconds, including one second after the
        // screenshot track ends. That covered second must remain on the axis.
        XCTAssertEqual(snapshot.processedScreenshotSegments.map(\.contiguousStartOffset), [0, 2, 5])
        XCTAssertEqual(snapshot.processedScreenshotSegments.map(\.contiguousEndOffset), [2, 4, 7])
        XCTAssertEqual(snapshot.appGroups.map { $0.segments.map(\.rawID) }, [[1, 2], [3]])
        XCTAssertEqual(snapshot.contiguousDuration, 7)

        let requested = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:00:00.750"))
        let moment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(to: requested, configuration: configuration)
        )
        XCTAssertEqual(moment.wallDate, Self.formatter.date(from: "2026-08-22T12:00:01.000"))
        XCTAssertEqual(moment.videoFrameIndex, 30)
        XCTAssertEqual(try XCTUnwrap(moment.mediaTime), 1, accuracy: 1e-12)
        XCTAssertEqual(moment.segmentID, 1)
        XCTAssertEqual(moment.bundleID, "com.example.Editor")

        let beforeFirst = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T11:59:59.999"))
        let beforeFirstMoment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(
                to: beforeFirst,
                configuration: configuration
            )
        )
        XCTAssertEqual(beforeFirstMoment.wallDate, Self.formatter.date(from: "2026-08-22T12:00:00.000"))
        XCTAssertEqual(beforeFirstMoment.videoFrameIndex, 0)

        let tied = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:00:01.500"))
        let tiedMoment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(to: tied, configuration: configuration)
        )
        XCTAssertEqual(tiedMoment.wallDate, tied)
        XCTAssertTrue([45, 46].contains(try XCTUnwrap(tiedMoment.videoFrameIndex)))

        let afterLast = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:20:00.000"))
        let afterLastMoment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(to: afterLast, configuration: configuration)
        )
        XCTAssertEqual(afterLastMoment.wallDate, Self.formatter.date(from: "2026-08-22T12:00:01.750"))

        let pendingDate = try XCTUnwrap(Self.formatter.date(from: "2026-08-22T12:00:01.800"))
        let pendingMoment = try XCTUnwrap(
            LibreReverseTimelineLibrary.nearestMoment(
                to: pendingDate,
                configuration: configuration
            )
        )
        XCTAssertEqual(
            pendingMoment.wallDate,
            Self.formatter.date(from: "2026-08-22T12:00:01.750")
        )
        XCTAssertTrue(pendingMoment.isPendingImage)
        XCTAssertNil(pendingMoment.chunkURL)
        XCTAssertNil(pendingMoment.videoFrameIndex)
        XCTAssertNil(pendingMoment.videoFrameRate)
        XCTAssertEqual(pendingMoment.bundleID, "com.example.Editor")
        XCTAssertEqual(pendingMoment.windowName, "Doc")
        XCTAssertEqual(
            pendingMoment.frameImageURL,
            library.frameImagesRoot.appendingPathComponent("pending.png")
        )

        try withKeyedDatabase(configuration) { database in
            try execute(database, "DELETE FROM frame")
        }
        XCTAssertNil(
            try LibreReverseTimelineLibrary.nearestMoment(to: requested, configuration: configuration)
        )
    }

    func testGapCompressedWallDateMappingUsesFollowingSegmentAtBoundary() throws {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = LibreReverseTimelineSnapshot(rawSegments: [
            segment(id: 1, start: epoch, end: epoch.addingTimeInterval(2)),
            segment(id: 2, start: epoch.addingTimeInterval(100), end: epoch.addingTimeInterval(104)),
        ])

        XCTAssertEqual(snapshot.wallDate(atContiguousOffset: 0), epoch)
        XCTAssertEqual(snapshot.wallDate(atContiguousOffset: 1), epoch.addingTimeInterval(1))
        XCTAssertEqual(snapshot.wallDate(atContiguousOffset: 2), epoch.addingTimeInterval(100))
        XCTAssertEqual(snapshot.wallDate(atContiguousOffset: 6), epoch.addingTimeInterval(104))
        XCTAssertEqual(
            snapshot.contiguousOffset(atWallDate: epoch.addingTimeInterval(50)),
            2
        )
    }

    private func segment(id: Int64, start: Date, end: Date) -> TimelineSegment {
        TimelineSegment(
            startDate: start,
            endDate: end,
            bundleID: "com.example.Editor",
            rawID: id,
            rawType: .capturedScreen
        )
    }

    private func seedCanonicalLibrary(_ configuration: LibreReverseLibraryConfiguration) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        try execute(database, """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES
          (3,'com.example.Browser','2026-08-22T12:10:00.000','2026-08-22T12:10:02.000','Web','https://other.test',NULL,0),
          (1,'com.example.Editor','2026-08-22T12:00:00.000','2026-08-22T12:00:02.000','Doc',NULL,NULL,0),
          (4,'ai.rewind.audiorecorder','2026-08-22T12:00:00.000','2026-08-22T12:00:05.000',NULL,NULL,NULL,1),
          (2,'com.example.Editor','2026-08-22T12:00:02.000','2026-08-22T12:00:04.000','Doc',NULL,NULL,0);
        INSERT INTO video(id,height,width,path,fileSize,frameRate,local,xid,processingState)
        VALUES(1,1080,1920,'2026/08/chunk',100,30.0,1,'fixture-video',2);
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus)
        VALUES
          (1,'2026-08-22T12:00:00.000','f0',1,1,0,0,'success'),
          (2,'2026-08-22T12:00:00.500','f15',1,1,15,1,'success'),
          (3,'2026-08-22T12:00:01.000','f30',1,1,30,0,'success'),
          (4,'2026-08-22T12:00:01.500','f45',1,1,45,0,'success'),
          (5,'2026-08-22T12:00:01.500','f46',2,1,46,0,'success'),
          (6,'2026-08-22T12:00:01.750','pending.png',2,NULL,NULL,0,'deferred');
        """)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
            throw NSError(domain: "LibreReverseTimelineLibraryTests", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func withKeyedDatabase(
        _ configuration: LibraryDatabaseConfiguration,
        operation: (OpaquePointer) throws -> Void
    ) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        try operation(database)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }
}
#endif
