#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class ArchiveDestinationSwitchTests: XCTestCase {
    func testProviderSwitchPreservesIndependentProgressAndActualResidency() throws {
        let (root, c) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = try activate(.googleDrive, "drive", c)
        try seed(drive, c)
        let uuid = try LibreReverseArchiveStore.libraryUUID(configuration: c)
        let s3 = try activate(.s3Compatible, "s3", c)
        XCTAssertNotEqual(drive, s3)
        XCTAssertEqual(try LibreReverseArchiveStore.activeDestination(configuration: c)?.id, s3)
        XCTAssertFalse(try XCTUnwrap(LibreReverseArchiveStore.destination(kind: .googleDrive, configuration: c)).enabled)
        XCTAssertNil(try LibreReverseArchiveStore.googleDriveDestination(configuration: c))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_destination WHERE enabled=1", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(s3)", c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency WHERE localState='absent' AND desiredLocal=1 AND isCache=0", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM library_shard WHERE state='remote_only' AND remoteIdentifier IS NULL AND verifiedAt IS NULL", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer WHERE sessionIdentifier='drive-session'", c), 1)
        try execute("""
            INSERT INTO archive_object(id,destinationId,videoId,relativePath,objectKey,byteCount,remoteState)
              VALUES(2,\(s3),1,'video','s3-object',1,'uploading');
            INSERT INTO archive_transfer(archiveObjectId,direction,state,sessionIdentifier,totalBytes,createdAt,updatedAt)
              VALUES(2,'upload','active','s3-session',1,'2026-09-01','2026-09-01');
            """, c)
        XCTAssertEqual(try activate(.googleDrive, "drive", c), drive)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM library_shard WHERE remoteIdentifier='drive-shard' AND state='remote_only'", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(drive) AND remoteState='verified'", c), 1)
        XCTAssertEqual(try activate(.s3Compatible, "s3", c), s3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object a JOIN archive_transfer t ON t.archiveObjectId=a.id WHERE a.destinationId=\(s3) AND t.sessionIdentifier='s3-session'", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object a JOIN archive_transfer t ON t.archiveObjectId=a.id WHERE a.destinationId=\(drive) AND t.sessionIdentifier='drive-session'", c), 1)
        XCTAssertEqual(try LibreReverseArchiveStore.libraryUUID(configuration: c), uuid)
        try LibreReverseArchiveStore.disableGoogleDriveDestination(configuration: c)
        XCTAssertEqual(try LibreReverseArchiveStore.activeDestination(configuration: c)?.id, s3)
        try LibreReverseArchiveStore.disableDestinations(configuration: c)
        XCTAssertNil(try LibreReverseArchiveStore.activeDestination(configuration: c))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_destination", c), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer", c), 2)
    }

    func testRootReplacementClearsOnlyThatProvidersRemoteStateAndKeepsPolicy() throws {
        let (root, c) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = try activate(.googleDrive, "drive", c)
        try seed(drive, c)
        let s3 = try activate(.s3Compatible, "s3", c)
        try execute("""
            UPDATE media_residency SET localState='present';
            UPDATE library_shard SET state='sealed_local';
            INSERT INTO archive_object(destinationId,videoId,relativePath,objectKey,byteCount,remoteState)
              VALUES(\(s3),1,'video','s3-object',1,'verified');
            UPDATE archive_policy SET requiredLocalSeconds=NULL WHERE destinationId=\(drive);
            """, c)
        XCTAssertEqual(try activate(.googleDrive, "new-drive-root", c), drive)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(drive)", c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(s3) AND remoteState='verified'", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer", c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_archive_object", c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_archive_retired_object", c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM library_shard WHERE remoteIdentifier IS NULL AND state='sealed_local'", c), 1)
        XCTAssertNil(try LibreReverseArchiveStore.policy(destinationID: drive, configuration: c)?.requiredLocalSeconds)
    }

    func testReplacingRootWithNonlocalContentRollsBackWithoutLosingResumeState() throws {
        let (root, c) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = try activate(.googleDrive, "drive", c)
        try seed(drive, c)
        let s3 = try activate(.s3Compatible, "s3", c)
        XCTAssertThrowsError(try activate(.googleDrive, "new-drive-root", c))
        XCTAssertEqual(try LibreReverseArchiveStore.activeDestination(configuration: c)?.id, s3)
        XCTAssertEqual(try LibreReverseArchiveStore.destination(kind: .googleDrive, configuration: c)?.remoteRoot, "drive")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer WHERE sessionIdentifier='drive-session'", c), 1)
        try execute("UPDATE media_residency SET localState='present'", c)
        XCTAssertThrowsError(try activate(.googleDrive, "new-drive-root", c), "Remote-only shard also protects root replacement")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_archive_object", c), 1)
    }

    func testCredentialsAndRootResetCommitAtomicallyAndS3DefaultsToKeepingLocalHistory() throws {
        let (root, c) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let s3 = try activate(.s3Compatible, "old-s3", c)
        let policy = try XCTUnwrap(LibreReverseArchiveStore.policy(destinationID: s3, configuration: c))
        XCTAssertNil(policy.requiredLocalSeconds)
        try seed(s3, c)
        let original = Data("synthetic-original".utf8)
        try LibreReverseArchiveStore.setCredentialData(original, account: "test-configuration", configuration: c)
        try execute("""
            UPDATE media_residency SET localState='present';
            UPDATE library_shard SET state='sealed_local';
            CREATE TRIGGER fail_credential BEFORE INSERT ON archive_credential
              BEGIN SELECT RAISE(ABORT, 'synthetic persistence failure'); END;
            """, c)
        let replacement = Data("synthetic-replacement".utf8)
        XCTAssertThrowsError(try LibreReverseArchiveStore.upsertDestination(
            kind: .s3Compatible, displayName: "new", remoteRoot: "new-s3",
            credentials: ["test-configuration": replacement], configuration: c))
        XCTAssertEqual(try LibreReverseArchiveStore.activeDestination(configuration: c)?.remoteRoot, "old-s3")
        XCTAssertEqual(try LibreReverseArchiveStore.credentialData(account: "test-configuration", configuration: c), original)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer WHERE sessionIdentifier='drive-session'", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE remoteState='verified'", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_archive_object", c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_archive_retired_object", c), 1)
        try execute("DROP TRIGGER fail_credential", c)
        XCTAssertEqual(try LibreReverseArchiveStore.upsertDestination(
            kind: .s3Compatible, displayName: "new", remoteRoot: "new-s3",
            credentials: ["test-configuration": replacement], configuration: c), s3)
        XCTAssertEqual(try LibreReverseArchiveStore.activeDestination(configuration: c)?.remoteRoot, "new-s3")
        XCTAssertEqual(try LibreReverseArchiveStore.credentialData(account: "test-configuration", configuration: c), replacement)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_transfer", c), 0)
    }

    func testNewProviderReconcilesOnlyLocalMediaAndLeavesPreviousProgressUntouched() throws {
        let (root, c) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = try activate(.googleDrive, "drive", c)
        try seed(drive, c)
        let s3 = try activate(.s3Compatible, "s3", c)
        XCTAssertEqual(try LibreReverseArchiveStore.reconcileEligibleVideos(destinationID: s3, configuration: c), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(drive) AND remoteState='verified'", c), 1)
        try execute("UPDATE media_residency SET localState='present'", c)
        XCTAssertEqual(try LibreReverseArchiveStore.reconcileEligibleVideos(destinationID: s3, configuration: c), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_object WHERE destinationId=\(s3) AND remoteState='queued'", c), 1)
        XCTAssertEqual(try LibreReverseArchiveStore.reconcileEligibleVideos(destinationID: s3, configuration: c), 0)
    }

    private func activate(_ kind: ArchiveBackendKind, _ root: String, _ c: LibreReverseLibraryConfiguration) throws -> Int64 {
        try LibreReverseArchiveStore.upsertDestination(kind: kind, displayName: root, remoteRoot: root, configuration: c)
    }

    private func seed(_ destination: Int64, _ c: LibreReverseLibraryConfiguration) throws {
        try execute("""
            INSERT INTO video(id,height,width,path,fileSize,frameRate,xid) VALUES(1,10,10,'video',1,1,'video-xid');
            INSERT INTO media_residency(videoId,localState,desiredLocal,isCache) VALUES(1,'absent',0,1);
            INSERT INTO archive_object(id,destinationId,videoId,relativePath,objectKey,byteCount,remoteState,remoteIdentifier,verifiedAt)
              VALUES(1,\(destination),1,'video','drive-object',1,'verified','drive-video','2026-09-01');
            INSERT INTO archive_transfer(archiveObjectId,direction,state,sessionIdentifier,totalBytes,createdAt,updatedAt)
              VALUES(1,'upload','active','drive-session',1,'2026-09-01','2026-09-01');
            INSERT INTO library_shard(id,ordinal,state,schemaVersion,keyVersion,remoteIdentifier,verifiedAt)
              VALUES(1,1,'remote_only',1,1,'drive-shard','2026-09-01');
            INSERT INTO shard_archive_object(shardId,destinationId,objectKey,remoteState,remoteIdentifier,verifiedAt,sessionIdentifier,updatedAt)
              VALUES(1,\(destination),'shard-object','verified','drive-shard','2026-09-01','shard-session','2026-09-01');
            INSERT INTO shard_archive_retired_object(shardId,destinationId,objectKey,remoteIdentifier,byteCount,retiredAt)
              VALUES(1,\(destination),'old-shard','old-drive-shard',1,'2026-09-01');
            """, c)
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-archive-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    private func scalar(
        _ sql: String,
        _ configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(configuration.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        let value = try XCTUnwrap(database)
        defer { sqlite3_close(value) }
        XCTAssertEqual(
            key.withUnsafeBytes { sqlite3_key(value, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(value, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return sqlite3_column_int64(query, 0)
    }

    private func execute(
        _ sql: String,
        _ configuration: LibreReverseLibraryConfiguration
    ) throws {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(configuration.databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK)
        let value = try XCTUnwrap(database)
        defer { sqlite3_close(value) }
        XCTAssertEqual(
            key.withUnsafeBytes { sqlite3_key(value, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(value, sql, nil, nil, nil), SQLITE_OK)
    }
}
#endif
