#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibraryWriteSessionTests: XCTestCase {
    private func library() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("media"))
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    func testArchiveStatusBatchReusesConnectionAndObservesExternalUpdates() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LibreReverseArchiveStore.initialize(configuration)
        let id = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Test", remoteRoot: "root", configuration: configuration)
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        XCTAssertEqual(try LibreReverseArchiveStore.googleDriveDestination(
            configuration: configuration, session: session)?.id, id)
        XCTAssertEqual(try LibreReverseArchiveStore.status(destinationID: id,
            configuration: configuration, session: session),
            try LibreReverseArchiveStore.status(destinationID: id, configuration: configuration))
        XCTAssertEqual(try LibreReverseArchiveStore.residencyForecast(destinationID: id,
            configuration: configuration, session: session),
            try LibreReverseArchiveStore.residencyForecast(destinationID: id, configuration: configuration))
        XCTAssertEqual(try LibreReverseShardArchiveStore.status(destinationID: id,
            configuration: configuration, session: session),
            try LibreReverseShardArchiveStore.status(destinationID: id, configuration: configuration))
        XCTAssertNil(try LibreReverseArchiveStore.nextRetryDate(destinationID: id,
            configuration: configuration, session: session))
        XCTAssertEqual(try LibreReverseArchiveStore.evictionBytesRequired(destinationID: id,
            configuration: configuration, session: session), 0)
        XCTAssertEqual(try LibreReverseArchiveStore.videosNeedingRehydration(destinationID: id,
            configuration: configuration, session: session), [])
        XCTAssertEqual(session.connectionOpenCount, 1)
        try LibreReverseArchiveStore.disableGoogleDriveDestination(configuration: configuration)
        XCTAssertNil(try LibreReverseArchiveStore.googleDriveDestination(
            configuration: configuration, session: session))
        XCTAssertEqual(session.connectionOpenCount, 1)
    }

    func testIdleSummaryPollingReusesOneConnection() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        for _ in 0..<5 {
            XCTAssertTrue(try LibreReverseLibraryStore.pendingMeetingSummaries(
                configuration: configuration, session: session).isEmpty)
        }
        XCTAssertEqual(session.connectionOpenCount, 1)
    }

    func testCaptureAndOCRReuseKeyedConnectionsAndCloseReopens() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        let frame = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(), imageFileName: "frame.png",
            context: .init(bundleID: "com.example.Editor", windowName: "Draft"),
            configuration: configuration, session: session)
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: frame.id, status: .pending, configuration: configuration, session: session)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id,
            document: OCRDocument(text: "words", otherText: "", nodes: []),
            configuration: configuration, session: session)
        XCTAssertTrue(try LibreReverseLibraryStore.pendingOCRFrames(
            configuration: configuration, session: session).isEmpty)
        XCTAssertFalse(try LibreReverseLibraryStore.canRemoveSourceImage(
            frameID: frame.id, configuration: configuration, session: session))
        XCTAssertEqual(session.connectionOpenCount, 1)
        session.close()
        XCTAssertEqual(try LibreReverseLibraryStore.loadRecoverableFrames(
            configuration: configuration, session: session).map(\.id), [frame.id])
        XCTAssertEqual(session.connectionOpenCount, 2)
    }

    func testFailedOperationDiscardsConnectionAndRollsBack() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        enum Failure: Error { case injected }
        XCTAssertThrowsError(try session.withDatabase(configuration: configuration) { db in
            XCTAssertEqual(sqlite3_exec(db, "BEGIN; CREATE TABLE rollback_probe(value INTEGER)", nil, nil, nil), SQLITE_OK)
            throw Failure.injected
        })
        try session.withDatabase(configuration: configuration) { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db,
                "SELECT count(*) FROM sqlite_master WHERE name='rollback_probe'", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        }
        XCTAssertEqual(session.connectionOpenCount, 2)
    }

    func testIdleCloseAllowsDatabaseReplacementAndSeesNewPrimary() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        _ = try LibreReverseLibraryStore.admitFrame(createdAt: Date(), imageFileName: "old.png", context: nil,
            configuration: configuration, session: session)
        session.close() // Same barrier used by recorder.finish and OCR.waitUntilIdle.
        try FileManager.default.moveItem(at: configuration.databaseURL,
                                        to: root.appendingPathComponent("retired.sqlite3"))
        try LibreReverseLibraryStore.initialize(configuration)
        XCTAssertTrue(try LibreReverseLibraryStore.loadRecoverableFrames(
            configuration: configuration, session: session).isEmpty)
        XCTAssertEqual(session.connectionOpenCount, 2)
    }

    func testSessionRejectsAnotherLibrary() throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        let other = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("other.sqlite3"),
            keyFileURL: configuration.keyFileURL, mediaRoot: configuration.mediaRoot)
        XCTAssertThrowsError(try LibreReverseLibraryStore.loadRecoverableFrames(configuration: other, session: session))
        XCTAssertEqual(session.connectionOpenCount, 0)
    }
}
#endif
