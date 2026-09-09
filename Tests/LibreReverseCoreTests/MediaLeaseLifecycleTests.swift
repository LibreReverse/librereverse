#if os(macOS)
import CSQLCipher
import Foundation
import Darwin
import XCTest
@testable import LibreReverseCore

final class MediaLeaseLifecycleTests: XCTestCase {
    func testOnlyPresentMediaCanAcquireAndFailedInitCannotReleaseAnotherLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
        for state in ["absent", "eviction_staged", "downloading", "installing", "corrupt"] {
            try execute("UPDATE media_residency SET localState='\(state)'", fixture.library)
            XCTAssertThrowsError(try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library))
            XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        }
        lease.release()
        lease.release()
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
    }

    func testRestorationRunsWithoutLeaseAndReturnsProtectedFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.mediaURL)
        try execute("UPDATE media_residency SET localState='absent'", fixture.library)
        let media = try await LibreReverseResolvedMedia.acquire(
            videoID: fixture.videoID, canonicalURL: fixture.mediaURL, library: fixture.library
        ) { videoID, url in
            // beginRehydration requires activeLeases=0 and fails under the
            // former lease-before-restore runner ordering.
            try LibreReverseArchiveStore.beginRehydration(videoID: videoID, configuration: fixture.library)
            try Data([1]).write(to: url)
            try LibreReverseArchiveStore.markRehydrationInstalling(videoID: videoID, configuration: fixture.library)
            try LibreReverseArchiveStore.markRehydrated(videoID: videoID, configuration: fixture.library)
            return url
        }
        XCTAssertEqual(media.url, fixture.mediaURL)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        media.lease.release()
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
    }

    func testResolverCannotUndoStagedEvictionOrReturnUnprotectedURL() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute("UPDATE media_residency SET localState='eviction_staged'", fixture.library)
        XCTAssertThrowsError(try LibreReverseArchiveStore.markRehydrated(
            videoID: fixture.videoID, configuration: fixture.library
        ))
        do {
            _ = try await LibreReverseResolvedMedia.acquire(
                videoID: fixture.videoID, canonicalURL: fixture.mediaURL, library: fixture.library,
                resolver: { _, url in url }
            )
            XCTFail("A resolver URL does not confer residency ownership")
        } catch {
            XCTAssertEqual(error as? LibreReverseArchiveStoreError, .mediaLeaseUnavailable(fixture.videoID))
        }
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
    }

    func testEvictionAndLeaseAcquisitionHaveExactlyOneWinner() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "test", remoteRoot: "test", configuration: fixture.library
        )
        _ = try LibreReverseArchiveStore.reconcileEligibleVideos(
            destinationID: destination, configuration: fixture.library
        )
        try execute("UPDATE media_residency SET desiredLocal=0", fixture.library)
        try execute("UPDATE archive_object SET remoteState='verified',localSHA256='abc',remoteSHA256='abc',remoteIdentifier='test'", fixture.library)
        let candidate = try XCTUnwrap(LibreReverseArchiveStore.evictionCandidates(
            destinationID: destination, configuration: fixture.library
        ).first)
        // An eviction candidate may have been read before the reader acquired
        // its lease. Staging must recheck ownership, not trust that snapshot.
        let lease = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
        XCTAssertFalse(try LibreReverseArchiveStore.stageEviction(
            candidate: candidate, stagingPath: "staged", destinationID: destination,
            configuration: fixture.library
        ))
        lease.release()
        XCTAssertTrue(try LibreReverseArchiveStore.stageEviction(
            candidate: candidate, stagingPath: "staged", destinationID: destination,
            configuration: fixture.library
        ))
        // The file still exists during this interleaving; that alone must
        // never allow a late reader to acquire ownership.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path))
        XCTAssertThrowsError(try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library))
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
    }

    func testRepeatedPlaybackLeasesReuseConnectionAndReleaseExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = LibreReverseLibraryWriteSession(configuration: fixture.library)
        defer { session.close() }
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let coldStart = cpuTime()
        for _ in 0..<12 {
            let lease = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
            lease.release()
        }
        let coldCPU = cpuTime() - coldStart
        let sharedStart = cpuTime()
        for _ in 0..<12 {
            let lease = try LibreReverseMediaLease(videoID: fixture.videoID,
                library: fixture.library, databaseSession: session)
            lease.release()
            lease.release()
        }
        let sharedCPU = cpuTime() - sharedStart
        XCTAssertEqual(session.connectionOpenCount, 1)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
        print("Lease CPU benchmark (12 acquire/release pairs): fresh=\(coldCPU)s shared=\(sharedCPU)s")
    }

    func testSharedLeaseSessionObservesExternalEvictionAndFailedInitKeepsOwnership() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = LibreReverseLibraryWriteSession(configuration: fixture.library)
        defer { session.close() }
        let lease = try LibreReverseMediaLease(videoID: fixture.videoID,
            library: fixture.library, databaseSession: session)
        try execute("UPDATE media_residency SET localState='eviction_staged'", fixture.library)
        XCTAssertThrowsError(try LibreReverseMediaLease(videoID: fixture.videoID,
            library: fixture.library, databaseSession: session))
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        lease.release()
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
        session.close()
        try execute("UPDATE media_residency SET localState='present'", fixture.library)
        let reopened = try LibreReverseMediaLease(videoID: fixture.videoID,
            library: fixture.library, databaseSession: session)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        reopened.release()
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
    }

    private struct Fixture: Sendable {
        let root: URL
        let library: LibreReverseLibraryConfiguration
        let videoID: Int64
        let mediaURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"),
            mediaRoot: root.appendingPathComponent("Media")
        )
        try LibreReverseLibraryStore.initialize(library)
        let date = Date()
        let frame = try LibreReverseLibraryStore.admitFrame(createdAt: date, imageFileName: "test.png", context: nil, configuration: library)
        let path = VideoStorage.relativePath(xid: "lease-test", date: date)
        let url = library.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(relativeMediaPath: path, xid: "lease-test", width: 8, height: 8,
                  frames: [.init(frameID: frame.id, videoFrameIndex: 0)]), configuration: library
        )
        return .init(root: root, library: library, videoID: videoID, mediaURL: url)
    }

    private func withDatabase<T>(_ library: LibreReverseLibraryConfiguration, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: library.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(database, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        return try body(database)
    }

    private func execute(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws {
        try withDatabase(library) { database in
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func scalar(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws -> Int64 {
        try withDatabase(library) { database in
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &raw, nil), SQLITE_OK)
            let statement = try XCTUnwrap(raw)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
    }
}
#endif
